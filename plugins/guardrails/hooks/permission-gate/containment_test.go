package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

// gitInit creates a real git repo at dir.
func gitInit(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	for _, args := range [][]string{
		{"init", "-q"},
		{"config", "user.email", "test@test"},
		{"config", "user.name", "test"},
		{"commit", "--allow-empty", "-q", "-m", "init"},
	} {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v in %s: %v\n%s", args, dir, err, out)
		}
	}
}

// setupWorktree builds a primary clone with a linked worktree under it and
// returns (primaryRoot, worktreeRoot). The worktree mirrors the harness layout
// (<primary>/.claude/worktrees/agent-<hash>).
func setupWorktree(t *testing.T) (string, string) {
	t.Helper()
	base := t.TempDir()
	primary := filepath.Join(base, "primary")
	gitInit(t, primary)

	wtParent := filepath.Join(primary, ".claude", "worktrees")
	if err := os.MkdirAll(wtParent, 0o755); err != nil {
		t.Fatalf("mkdir worktrees: %v", err)
	}
	wt := filepath.Join(wtParent, "agent-deadbeef")
	cmd := exec.Command("git", "-C", primary, "worktree", "add", "-q", "--detach", wt)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git worktree add: %v\n%s", err, out)
	}
	// Canonicalize for comparison (macOS /var -> /private/var symlink).
	return canonicalize(primary), canonicalize(wt)
}

// §10: a subagent Write whose target resolves to the primary clone is blocked
// (#127); the same write to the correct in-worktree path is allowed.
func TestContainmentWorktreeEscape_127(t *testing.T) {
	primary, wt := setupWorktree(t)

	// Write into the primary clone from a worktree cwd → DENY.
	ev := &Event{
		ToolName:  "Write",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + filepath.Join(primary, "agents", "pr-reviewer.md") + `"}`),
	}
	d := classifyFileTool(ev)
	wantBucket(t, d, BucketDeny, "#127 write into primary clone")
	if !containsSubstr(d.Reason, "worktree") {
		t.Errorf("#127 deny reason should mention the worktree; got %q", d.Reason)
	}

	// The same logical write to the in-worktree path → not denied (defer).
	ev2 := &Event{
		ToolName:  "Write",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + filepath.Join(wt, "agents", "pr-reviewer.md") + `"}`),
	}
	d2 := classifyFileTool(ev2)
	if d2.Bucket == BucketDeny {
		t.Errorf("in-worktree write must not DENY; got %q (%s)", d2.Bucket, d2.Reason)
	}
}

// #130: reading a tracked, non-.git/ file in the primary clone / shared git
// dir from a linked worktree is a legitimate, safe read (the worktree shares
// tracked content with the primary clone) and must no longer ASK. The
// write-side #127 deny and the .git/-tree deny (both reads and writes) must
// survive unchanged, and #148 cross-repo reads must still deny.
func TestPrimaryCloneReadRelaxed_130(t *testing.T) {
	primary, wt := setupWorktree(t)

	pluginJSON := filepath.Join(primary, "plugins", "guardrails", ".claude-plugin", "plugin.json")
	if err := os.MkdirAll(filepath.Dir(pluginJSON), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pluginJSON, []byte(`{"version":"0.9.2"}`), 0o644); err != nil {
		t.Fatal(err)
	}

	// bash-read (cat) of a primary-clone tracked file from a worktree →
	// contained/defer, NOT ask (regression for #125's stated intent).
	bev := &Event{ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	bd := classifyBash("cat "+pluginJSON, bev)
	if bd.Bucket == BucketAsk || bd.Bucket == BucketDeny {
		t.Errorf("#130: bash-read of primary-clone tracked file must not ask/deny; got %q (%s)", bd.Bucket, bd.Reason)
	}

	// Read tool on a primary-clone tracked file → allow/defer.
	rev := &Event{
		ToolName:  "Read",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + pluginJSON + `"}`),
	}
	rd := classifyFileTool(rev)
	if rd.Bucket == BucketAsk || rd.Bucket == BucketDeny {
		t.Errorf("#130: Read tool on primary-clone tracked file must not ask/deny; got %q (%s)", rd.Bucket, rd.Reason)
	}

	// Write / Edit on a primary-clone path still DENY (cross-worktree-write,
	// #127) — the read relaxation must not touch the write side.
	for _, tool := range []string{"Write", "Edit"} {
		wev := &Event{
			ToolName:  tool,
			CWD:       wt,
			AgentType: "issue-developer",
			ToolInput: []byte(`{"file_path":"` + pluginJSON + `"}`),
		}
		wd := classifyFileTool(wev)
		wantBucket(t, wd, BucketDeny, tool+" to primary-clone path must still deny (#127)")
	}

	// cat <primary-clone>/.git/config still gated (.git/ deny survives the
	// read relaxation).
	gitCfg := filepath.Join(primary, ".git", "config")
	gcBev := &Event{ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	gcBd := classifyBash("cat "+gitCfg, gcBev)
	wantBucket(t, gcBd, BucketDeny, "cat primary-clone .git/config must still be gated")

	gcRev := &Event{
		ToolName:  "Read",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + gitCfg + `"}`),
	}
	gcRd := classifyFileTool(gcRev)
	wantBucket(t, gcRd, BucketDeny, "Read of primary-clone .git/config must still be gated")

	// cat <sibling-repo>/node_modules/x still cross-repo deny (#148) —
	// unaffected by the primary-clone relaxation.
	base := t.TempDir()
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	nm := filepath.Join(sibling, "node_modules", "x")
	if err := os.MkdirAll(filepath.Dir(nm), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(nm, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	siblingBev := &Event{ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	siblingBd := classifyBash("cat "+nm, siblingBev)
	wantBucket(t, siblingBd, BucketDeny, "cat sibling-repo node_modules must still cross-repo deny (#148)")
}

// §10: a Read/bash-read targeting a sibling repo is blocked (#148).
func TestContainmentCrossRepo_148(t *testing.T) {
	base := t.TempDir()
	repoA := filepath.Join(base, "repoA")
	repoB := filepath.Join(base, "repoB")
	gitInit(t, repoA)
	gitInit(t, repoB)
	// Create a node_modules file in the sibling repo.
	nm := filepath.Join(repoB, "node_modules", "pkg")
	if err := os.MkdirAll(nm, 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(nm, "index.js")
	if err := os.WriteFile(target, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Read tool targeting the sibling repo, from repoA's cwd → DENY.
	ev := &Event{
		ToolName:  "Read",
		CWD:       canonicalize(repoA),
		ToolInput: []byte(`{"file_path":"` + target + `"}`),
	}
	d := classifyFileTool(ev)
	wantBucket(t, d, BucketDeny, "#148 read sibling repo node_modules")

	// bash-read (cat) of the sibling file → DENY.
	bev := &Event{ToolName: "Bash", CWD: canonicalize(repoA), AgentType: "main"}
	bd := classifyBash("cat "+target, bev)
	wantBucket(t, bd, BucketDeny, "#148 bash cat sibling repo")

	// Reading a file inside the current repo → not denied.
	own := filepath.Join(repoA, "README.md")
	_ = os.WriteFile(own, []byte("x"), 0o644)
	ev2 := &Event{ToolName: "Read", CWD: canonicalize(repoA), ToolInput: []byte(`{"file_path":"` + own + `"}`)}
	if classifyFileTool(ev2).Bucket == BucketDeny {
		t.Errorf("in-repo read must not DENY")
	}
}

// #247 (HIGH): a subagent Read of the agent's own ~/.claude global config tree
// from inside a repo must DEFER (so the settings.json allow-list governs it),
// NOT be hard-denied as a #148 cross-repo escape — while a genuine sibling-repo
// node_modules read is still denied (#148 must not regress).
func TestClaudeConfigCarveOut_247(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		t.Skip("no home directory; carve-out not testable")
	}
	// Use a real file under ~/.claude so canonicalization resolves it; fall back
	// to a path under ~/.claude that may not exist (canonicalize handles the
	// non-existent tail through any symlinked ancestor).
	claudeFile := filepath.Join(home, ".claude", "rules", "foo.md")

	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)

	// Read of ~/.claude/rules/foo.md from inside a repo → DEFER (allow-list
	// governs it), NOT deny.
	ev := &Event{
		ToolName:  "Read",
		CWD:       canonicalize(repo),
		AgentType: "pr-reviewer",
		ToolInput: []byte(`{"file_path":"` + claudeFile + `"}`),
	}
	d := classifyFileTool(ev)
	if d.Bucket == BucketDeny {
		t.Errorf("#247: Read of ~/.claude config must not DENY (allow-list governs it); got %q (%s)", d.Bucket, d.Reason)
	}
	if d.Bucket != BucketDefer {
		t.Errorf("#247: Read of ~/.claude config should DEFER to the normal pipeline; got %q", d.Bucket)
	}

	// #148 must not regress: a sibling repo's node_modules read is still denied.
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	nm := filepath.Join(sibling, "node_modules", "pkg")
	if err := os.MkdirAll(nm, 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(nm, "index.js")
	if err := os.WriteFile(target, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev2 := &Event{
		ToolName:  "Read",
		CWD:       canonicalize(repo),
		AgentType: "pr-reviewer",
		ToolInput: []byte(`{"file_path":"` + target + `"}`),
	}
	wantBucket(t, classifyFileTool(ev2), BucketDeny, "#148 sibling node_modules still denied")
}

// sessionUUID is a syntactically valid session directory name (the loose
// 8-4-4-4-12 hex shape the harness emits). The v4 version nibble is
// deliberately not pinned by harnessSessionShape, so any hex works.
const sessionUUID = "d7e3bba4-9f23-4713-913d-e0fa80c68cf6"

// sessionSlug is a project-slug-shaped directory name: the session cwd with
// every separator rewritten to "-", so it LEADS with "-".
const sessionSlug = "-Users-someone-Workspaces-permission-gate-fixture"

// scratchTarget spells a path under the REAL <system-tmp>/claude-<uid> root.
// Nothing is created there: the gate only stats paths, and canonicalize
// re-attaches a non-existent tail to its longest existing ancestor, so these
// tests never touch the developer's live scratchpad.
func scratchTarget(uid int, rel ...string) string {
	return filepath.Join(append([]string{fmt.Sprintf("/tmp/claude-%d", uid)}, rel...)...)
}

// withScratchRoot points harnessScratchRootResolver at a fixture root for the
// duration of the test. Used for the cases that need real symlinks (or a
// deliberately broken root) inside the carve-out region, which must never be
// created under the developer's live /tmp/claude-<uid>.
func withScratchRoot(t *testing.T, st harnessScratchRootState) {
	t.Helper()
	prev := harnessScratchRootResolver
	harnessScratchRootResolver = func() harnessScratchRootState { return st }
	t.Cleanup(func() { harnessScratchRootResolver = prev })
}

// fileToolBucket classifies a single-path file-tool call against repoRoot.
func fileToolBucket(t *testing.T, tool, repoRoot, target string) Decision {
	t.Helper()
	return classifyFileTool(&Event{
		ToolName:  tool,
		CWD:       repoRoot,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + target + `"}`),
	})
}

// #193 row 1 (ALLOW): a file-tool or bash read/write whose canonical target
// lands in a session-shaped harness scratchpad directory —
// <system-tmp>/claude-<uid>/<project-slug>/<uuid>/{scratchpad,tasks}/… — is
// allowed OUTRIGHT, not deferred. A defer would leave the feature dead until
// every /tmp entry is removed from settings.json, since a hook allow outranks
// that list and a defer does not.
//
// Both /tmp and /private/tmp spellings are exercised: on macOS /tmp is a
// symlink, so the canonical root is the /private/tmp form while the literal
// spelling stays /tmp, and canonicalizing BOTH sides is what makes them agree.
// On Linux the two coincide, which is a harmless duplicate pass.
func TestHarnessScratchSessionAllowed_193(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	uid := os.Getuid()

	canonRoot := harnessScratchRootResolver().root
	for _, leaf := range []string{"scratchpad", "tasks"} {
		rel := filepath.Join(sessionSlug, sessionUUID, leaf, "handoff.md")
		spellings := map[string]string{
			"literal /tmp":  scratchTarget(uid, rel),
			"canonicalized": filepath.Join(canonRoot, rel),
		}
		for label, target := range spellings {
			label = label + " " + leaf
			for _, tool := range []string{"Read", "Write", "Edit"} {
				d := fileToolBucket(t, tool, root, target)
				wantBucket(t, d, BucketAllow, label+": "+tool+" of a session scratchpad file")
			}

			bev := bashEvIn(t, root, "issue-developer")
			// Both bash read tracks: the read-only-utility one (cat) and
			// classifyPathReader (less), whose contained terminal is a DEFER —
			// a session-scratchpad operand promotes it to ALLOW.
			for _, cmd := range []string{"cat " + target, "less " + target} {
				wantBucket(t, classifyBash(cmd, bev), BucketAllow, label+": "+cmd)
			}
			// Bash writes into a session directory ride the in-repo-write ALLOW.
			for _, cmd := range []string{
				"tee " + target,
				"touch " + target,
				"mkdir " + filepath.Join(filepath.Dir(target), "sub"),
				"cp " + filepath.Join(root, "a.txt") + " " + target,
			} {
				wantBucket(t, classifyBash(cmd, bev), BucketAllow, label+": "+cmd)
			}
		}
	}
}

// #193 row 2 (DEFER): a target under the <system-tmp>/claude-<uid> prefix whose
// remainder does NOT match the session shape is handed back to the normal
// pipeline — neither blessed nor denied. A shape miss costs a DEFER, not a
// denial, which is what makes the tight shape affordable.
func TestHarnessScratchShapeMissDefers_193(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	uid := os.Getuid()

	misses := map[string]string{
		"bare file at the prefix root":     scratchTarget(uid, "loose.md"),
		"no session subdirectory":          scratchTarget(uid, sessionSlug, sessionUUID, "notes.md"),
		"unrecognized leaf":                scratchTarget(uid, sessionSlug, sessionUUID, "secrets", "x.md"),
		"session id is not a uuid":         scratchTarget(uid, sessionSlug, "session-id", "scratchpad", "x.md"),
		"project slug has no leading dash": scratchTarget(uid, "projslug", sessionUUID, "scratchpad", "x.md"),
		"leaf name only a prefix of scratchpad": scratchTarget(uid, sessionSlug, sessionUUID,
			"scratchpad-evil", "x.md"),
		"the prefix root itself": scratchTarget(uid),
	}
	for label, target := range misses {
		for _, tool := range []string{"Read", "Write", "Edit"} {
			d := fileToolBucket(t, tool, root, target)
			wantBucket(t, d, BucketDefer, label+": "+tool)
		}
		bev := bashEvIn(t, root, "issue-developer")
		for _, cmd := range []string{"cat " + target, "less " + target, "tee " + target, "touch " + target} {
			if d := classifyBash(cmd, bev); d.Bucket == BucketDeny || d.Bucket == BucketAsk {
				t.Errorf("%s: %q is inside the scratchpad prefix and must not deny/ask; got %q (%s)",
					label, cmd, d.Bucket, d.Reason)
			}
		}
	}
}

// #193 row 3 (ASK): when the claude-<uid> root is not a plain directory owned by
// this uid, the gate cannot prove where a path under it actually lands, so it
// escalates — with a reason that NAMES the defect, so the failure is not
// mistaken for the #193 containment bug reappearing.
func TestHarnessScratchDefectiveRootAsks_193(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)

	fake := canonicalize(t.TempDir())
	for _, tc := range []struct{ defect, wantIn string }{
		{"a symlink", "symlink"},
		{"not a directory", "not a directory"},
		{"owned by uid 0 rather than this process's uid 501", "owned by uid 0"},
	} {
		withScratchRoot(t, harnessScratchRootState{root: fake, defect: tc.defect})
		target := filepath.Join(fake, sessionSlug, sessionUUID, "scratchpad", "x.md")

		for _, tool := range []string{"Read", "Write", "Edit"} {
			d := fileToolBucket(t, tool, root, target)
			wantBucket(t, d, BucketAsk, tc.defect+": "+tool+" through a defective scratchpad root")
			if !containsSubstr(d.Reason, tc.wantIn) {
				t.Errorf("%s: the ask reason must name the defect (%q); got %q", tc.defect, tc.wantIn, d.Reason)
			}
			if !containsSubstr(d.Reason, harnessScratchDisplay()) {
				t.Errorf("%s: the ask reason must name the scratchpad root; got %q", tc.defect, d.Reason)
			}
			if !containsSubstr(d.Reason, "NOT a containment escape") {
				t.Errorf("%s: the ask reason must distinguish itself from a containment escape; got %q",
					tc.defect, d.Reason)
			}
		}

		bev := bashEvIn(t, root, "issue-developer")
		for _, cmd := range []string{"cat " + target, "less " + target, "tee " + target, "touch " + target} {
			d := classifyBash(cmd, bev)
			wantBucket(t, d, BucketAsk, tc.defect+": "+cmd)
			if !containsSubstr(d.Reason, tc.wantIn) {
				t.Errorf("%s: %q ask reason must name the defect; got %q", tc.defect, cmd, d.Reason)
			}
		}
	}

	// A genuine escape in the same command still outranks the root ASK: the
	// scratchpad-root finding is recorded, not returned inline.
	withScratchRoot(t, harnessScratchRootState{root: fake, defect: "a symlink"})
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	src := filepath.Join(fake, sessionSlug, sessionUUID, "scratchpad", "x.md")
	cpBev := bashEvIn(t, root, "issue-developer")
	wantBucket(t, classifyBash("cp "+src+" "+filepath.Join(canonicalize(sibling), "stolen.md"), cpBev),
		BucketDeny, "a cross-repo destination outranks the defective-root ask")
}

// #193 row 4 (DENY): everything else under /tmp still denies exactly as before —
// a loose /tmp file, and another uid's claude-<other-uid> prefix. The carve-out
// is per-uid, derived from os.Getuid() at runtime, never a claude-* glob: real
// machines host claude-501 and claude-503 side by side.
func TestHarnessScratchOutsidePrefixStillDenies_193(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	uid := os.Getuid()

	denials := map[string]string{
		"loose /tmp file":       "/tmp/loose-scratch-file.md",
		"another uid's prefix":  fmt.Sprintf("/tmp/claude-%d/%s/%s/scratchpad/x.md", uid+1, sessionSlug, sessionUUID),
		"sibling of the prefix": fmt.Sprintf("/tmp/claude-%d-backup/x.md", uid),
	}
	for label, target := range denials {
		for _, tool := range []string{"Read", "Write"} {
			wantBucket(t, fileToolBucket(t, tool, root, target), BucketDeny, label+": "+tool)
		}
		bev := bashEvIn(t, root, "issue-developer")
		wantBucket(t, classifyBash("cat "+target, bev), BucketDeny, label+": bash read")
		wantBucket(t, classifyBash("touch "+target, bev), BucketDeny, label+": bash write")
	}

	// The /tmp escape deny prescribes BOTH destinations plus the .git/
	// prohibition, and names the RESOLVED repo root rather than a placeholder.
	outD := fileToolBucket(t, "Write", root, "/tmp/loose-scratch-file.md")
	wantBucket(t, outD, BucketDeny, "Write to a /tmp path outside the scratchpad prefix")
	for _, want := range []string{root + "/.claude/tmp/", harnessScratchDisplay(), ".git/"} {
		if !containsSubstr(outD.Reason, want) {
			t.Errorf("#193: the /tmp escape deny must name %q; got %q", want, outD.Reason)
		}
	}

	// The carve-out must not MASK an escape elsewhere in the same command: a
	// copy out of a session scratchpad into a sibling repo still earns the
	// cross-repo deny for its destination.
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	src := scratchTarget(uid, sessionSlug, sessionUUID, "scratchpad", "handoff.md")
	cpBev := bashEvIn(t, root, "issue-developer")
	wantBucket(t, classifyBash("cp "+src+" "+filepath.Join(canonicalize(sibling), "stolen.md"), cpBev),
		BucketDeny, "cp out of the scratchpad into a sibling repo")
}

// #193: NOTHING below the carve-out root needs its own symlink check —
// canonicalization already resolves every intermediate component before the
// comparison, and produces a BETTER verdict than an Lstat refusal would (a
// symlinked scratchpad -> ~/.ssh resolves out of the region and earns the
// ordinary cross-repo deny).
//
// These cases are pinned explicitly, per the issue, precisely BECAUSE they
// are guarded by canonicalize()'s behavior rather than by an explicit check: a
// future refactor of canonicalize that stopped resolving intermediate symlinks
// would silently open the region, and only a test that walks a real symlink can
// catch it.
func TestHarnessScratchSymlinkBelowRootDenies_193(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)

	// The fixture root stands in for /tmp/claude-<uid> so the symlinks below
	// are never created in the developer's live scratchpad.
	fake := canonicalize(t.TempDir())
	withScratchRoot(t, harnessScratchRootState{root: fake})

	// A directory outside both the repo and the carve-out region — where the
	// symlinks point.
	outside := filepath.Join(canonicalize(base), "outside")
	if err := os.MkdirAll(filepath.Join(outside, "scratchpad"), 0o755); err != nil {
		t.Fatal(err)
	}

	// Case 1: a symlinked INTERMEDIATE directory — the <uuid> session directory
	// itself points out of the region.
	interProject := filepath.Join(fake, sessionSlug)
	if err := os.MkdirAll(interProject, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(interProject, sessionUUID)); err != nil {
		t.Fatal(err)
	}
	viaInter := filepath.Join(interProject, sessionUUID, "scratchpad", "x.md")

	// Case 2: a symlinked LEAF — the scratchpad/ (and tasks/) directory of an
	// otherwise well-formed session directory points out of the region.
	const otherUUID = "11111111-2222-3333-4444-555555555555"
	leafSession := filepath.Join(fake, sessionSlug+"-two", otherUUID)
	if err := os.MkdirAll(leafSession, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(leafSession, "scratchpad")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(leafSession, "tasks")); err != nil {
		t.Fatal(err)
	}

	escapes := map[string]string{
		"symlinked intermediate session directory": viaInter,
		"symlinked scratchpad leaf":                filepath.Join(leafSession, "scratchpad", "x.md"),
		"symlinked tasks leaf":                     filepath.Join(leafSession, "tasks", "x.md"),
	}
	for label, target := range escapes {
		for _, tool := range []string{"Read", "Write", "Edit"} {
			d := fileToolBucket(t, tool, root, target)
			wantBucket(t, d, BucketDeny, label+": "+tool+" must resolve out of the region and deny")
		}
		bev := bashEvIn(t, root, "issue-developer")
		wantBucket(t, classifyBash("cat "+target, bev), BucketDeny, label+": bash read")
		wantBucket(t, classifyBash("touch "+target, bev), BucketDeny, label+": bash write")
	}

	// A symlink pointing WITHIN the region is cross-session handoff working as
	// intended, not a hole: it resolves to an in-region, shape-valid remainder
	// and is allowed.
	const handoffUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	writerTasks := filepath.Join(fake, sessionSlug, handoffUUID, "tasks")
	if err := os.MkdirAll(writerTasks, 0o755); err != nil {
		t.Fatal(err)
	}
	readerSession := filepath.Join(fake, sessionSlug+"-reader", otherUUID)
	if err := os.MkdirAll(readerSession, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(writerTasks, filepath.Join(readerSession, "scratchpad")); err != nil {
		t.Fatal(err)
	}
	inRegion := filepath.Join(readerSession, "scratchpad", "handoff.md")
	for _, tool := range []string{"Read", "Write"} {
		wantBucket(t, fileToolBucket(t, tool, root, inRegion), BucketAllow,
			"a symlink pointing WITHIN the region is cross-session handoff, not a hole: "+tool)
	}
}

// #193: the root check itself. Only the FINAL claude-<uid> component is
// Lstat-ed; the parent is symlink-resolved first. Lstat-ing the whole path — or
// rejecting a symlink anywhere in it — would break macOS outright, where /tmp is
// itself a symlink to /private/tmp, so that case is pinned here directly rather
// than left to the end-to-end tests to notice.
func TestScratchRootCheck_193(t *testing.T) {
	base := canonicalize(t.TempDir())
	realTmp := filepath.Join(base, "private", "tmp")
	if err := os.MkdirAll(realTmp, 0o755); err != nil {
		t.Fatal(err)
	}
	// A /tmp -> /private/tmp stand-in, so the root's PARENT is a symlink.
	tmpLink := filepath.Join(base, "tmp")
	if err := os.Symlink(realTmp, tmpLink); err != nil {
		t.Fatal(err)
	}

	// A real directory reached through the symlinked parent: no defect, and the
	// root resolves to the parent's real spelling so a canonicalized target
	// compares equal. This is exactly the macOS layout.
	okRoot := filepath.Join(realTmp, "claude-ok")
	if err := os.MkdirAll(okRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if st := resolveScratchRootAt(filepath.Join(tmpLink, "claude-ok")); st.defect != "" || st.root != okRoot {
		t.Errorf("a real dir under a SYMLINKED parent must be defect-free and resolve to %q; got %+v", okRoot, st)
	}

	// A root that does not exist yet is not a defect — the ordinary state on a
	// fresh machine — and still resolves through the symlinked parent.
	missing := filepath.Join(realTmp, "claude-missing")
	if st := resolveScratchRootAt(filepath.Join(tmpLink, "claude-missing")); st.defect != "" || st.root != missing {
		t.Errorf("a not-yet-created root must be defect-free and resolve to %q; got %+v", missing, st)
	}

	// The final component IS a symlink → defect, and the comparison root
	// becomes the destination so the ASK can fire at all (a fully-canonicalized
	// target lands there, not on the un-followed root).
	elsewhere := filepath.Join(base, "elsewhere")
	if err := os.MkdirAll(elsewhere, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(realTmp, "claude-link")); err != nil {
		t.Fatal(err)
	}
	st := resolveScratchRootAt(filepath.Join(tmpLink, "claude-link"))
	if !containsSubstr(st.defect, "symlink") {
		t.Errorf("a symlinked claude-<uid> component must report a symlink defect; got %+v", st)
	}
	if st.root != elsewhere {
		t.Errorf("a symlinked root must compare against its destination %q; got %q", elsewhere, st.root)
	}

	// The final component is a regular file → defect.
	notDir := filepath.Join(realTmp, "claude-file")
	if err := os.WriteFile(notDir, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if st := resolveScratchRootAt(filepath.Join(tmpLink, "claude-file")); st.defect != "not a directory" {
		t.Errorf("a non-directory root must report a defect; got %+v", st)
	}

	// The REAL root this process would use must not be reported as a symlink
	// defect merely because /tmp is one. Skipped when the machine genuinely has
	// a symlinked (or otherwise odd) claude-<uid>, which is the case the defect
	// exists to report.
	display := harnessScratchDisplay()
	if fi, err := os.Lstat(display); err != nil || fi.IsDir() {
		if got := resolveHarnessScratchRoot(); got.defect != "" {
			t.Errorf("the real scratchpad root %q must be defect-free when it is a plain dir (or absent); got %+v",
				display, got)
		}
	}
	if runtime.GOOS == "darwin" {
		// Sanity: the macOS case this check exists for is actually present.
		if fi, err := os.Lstat("/tmp"); err != nil || fi.Mode()&os.ModeSymlink == 0 {
			t.Skip("/tmp is not a symlink on this machine; the macOS parent-symlink case is not exercised")
		}
	}
}

// #193: the session-shape pattern is matched against the REMAINDER after the
// canonical root is stripped, never the full path, so it is platform-
// independent by construction — it contains neither "/tmp" nor "/private/tmp".
func TestHarnessSessionShape_193(t *testing.T) {
	matches := []string{
		sessionSlug + "/" + sessionUUID + "/scratchpad",
		sessionSlug + "/" + sessionUUID + "/scratchpad/",
		sessionSlug + "/" + sessionUUID + "/scratchpad/deep/nested/file.md",
		sessionSlug + "/" + sessionUUID + "/tasks/x.json",
		// Upper-case hex and a non-v4 version nibble both match: the version
		// nibble is deliberately not pinned, so a generator change cannot break
		// the carve-out.
		"-p/AAAAAAAA-BBBB-1111-2222-CCCCCCCCCCCC/tasks",
	}
	for _, m := range matches {
		if !harnessSessionShape.MatchString(m) {
			t.Errorf("remainder %q should match the session shape", m)
		}
	}

	nonMatches := []string{
		"",
		"loose.md",
		sessionSlug + "/" + sessionUUID,
		sessionSlug + "/" + sessionUUID + "/scratchpadding/x",
		sessionSlug + "/" + sessionUUID + "/secrets/x",
		sessionSlug + "/not-a-uuid/scratchpad/x",
		"noleadingdash/" + sessionUUID + "/scratchpad/x",
		// Not anchored to the start: a well-formed suffix must not match when
		// something precedes it.
		"other/" + sessionSlug + "/" + sessionUUID + "/scratchpad/x",
		// The pattern must never carry a platform-specific prefix.
		"/tmp/claude-501/" + sessionSlug + "/" + sessionUUID + "/scratchpad/x",
	}
	for _, m := range nonMatches {
		if harnessSessionShape.MatchString(m) {
			t.Errorf("remainder %q should NOT match the session shape", m)
		}
	}
	for _, forbidden := range []string{"/tmp", "private", "claude-"} {
		if containsSubstr(harnessSessionShape.String(), forbidden) {
			t.Errorf("the session shape must not contain %q — it matches the remainder, not the full path; got %q",
				forbidden, harnessSessionShape.String())
		}
	}
}

// §10 + #125 (write half), broadened by #35 Fix 3: a direct file-tool
// Write/Edit whose target resolves to ANYWHERE under .git/ is denied (the
// Engine B half of the #125 write criterion, generalized to the whole .git/
// tree). Reads of .git/ files are not mutations and stay allowed/deferred.
func TestGitTreeWriteDenied_125_35(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cfg := filepath.Join(repo, ".git", "config") // exists after gitInit

	for _, tool := range []string{"Write", "Edit", "MultiEdit"} {
		ev := &Event{
			ToolName:  tool,
			CWD:       canonicalize(repo),
			AgentType: "issue-developer",
			ToolInput: []byte(`{"file_path":"` + cfg + `"}`),
		}
		d := classifyFileTool(ev)
		wantBucket(t, d, BucketDeny, tool+" to .git/config")
		if !containsSubstr(d.Operation, "write:.git tree") {
			t.Errorf("%s .git/config deny should be the .git-tree rule; got op %q (%s)", tool, d.Operation, d.Reason)
		}
		// The agent-facing reason must remain actionable on its own — name the
		// risk and the alternative — and must NOT carry a bare issue-tracker ref.
		if !containsSubstr(d.Reason, ".claude/tmp/") {
			t.Errorf("%s .git/config deny reason should steer scratch to .claude/tmp/; got %q", tool, d.Reason)
		}
	}

	// #35 Fix 3: writes to other paths under .git/ are now denied too.
	for _, rel := range []string{
		filepath.Join(".git", "hooks", "pre-commit"),
		filepath.Join(".git", "info", "exclude"),
	} {
		target := filepath.Join(repo, rel)
		ev := &Event{
			ToolName:  "Write",
			CWD:       canonicalize(repo),
			AgentType: "issue-developer",
			ToolInput: []byte(`{"file_path":"` + target + `"}`),
		}
		wantBucket(t, classifyFileTool(ev), BucketDeny, "Write to "+rel)
	}

	// #35 Fix 3: an Edit of a submodule-style nested .git/config is denied via
	// the ".git" path-segment check (a literal "*/.git/..." path the
	// containment layer would otherwise wave through).
	sub := filepath.Join(repo, "vendor", "mod", ".git", "config")
	if err := os.MkdirAll(filepath.Dir(sub), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sub, []byte("[core]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	subEv := &Event{
		ToolName:  "Edit",
		CWD:       canonicalize(repo),
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + sub + `"}`),
	}
	wantBucket(t, classifyFileTool(subEv), BucketDeny, "Edit submodule .git/config")

	// A READ of .git/config is not an identity write → must not be denied by
	// the #125 rule (it is in-repo, so it defers).
	rev := &Event{
		ToolName:  "Read",
		CWD:       canonicalize(repo),
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + cfg + `"}`),
	}
	if rd := classifyFileTool(rev); rd.Bucket == BucketDeny {
		t.Errorf("Read of .git/config must not DENY as a #125 write; got %q (%s)", rd.Bucket, rd.Reason)
	}

	// A normal in-worktree Write (no .git/ segment) is unaffected → defers.
	own := filepath.Join(repo, "rules", "foo.md")
	if err := os.MkdirAll(filepath.Dir(own), 0o755); err != nil {
		t.Fatal(err)
	}
	ownEv := &Event{
		ToolName:  "Write",
		CWD:       canonicalize(repo),
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + own + `"}`),
	}
	if od := classifyFileTool(ownEv); od.Bucket == BucketDeny {
		t.Errorf("in-worktree Write must not DENY; got %q (%s)", od.Bucket, od.Reason)
	}
}

// #30: the under-specified containment-escape denies must be prescriptive —
// they must name <repo-root>/.claude/tmp/ as the scratch destination for
// mutating tools and explicitly warn against .git/ as a workaround target.
// A guardrail that only forbids invites a workaround (writing under .git/
// because it is gitignored and in-repo); one that prescribes prevents it.
func TestContainmentDeniesArePrescriptive_30(t *testing.T) {
	// #148 cross-repo Write deny (the file-tool path) names .claude/tmp/ and
	// warns against .git/.
	base := t.TempDir()
	repoA := filepath.Join(base, "repoA")
	repoB := filepath.Join(base, "repoB")
	gitInit(t, repoA)
	gitInit(t, repoB)
	target := filepath.Join(repoB, "node_modules", "pkg", "index.js")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeEv := &Event{
		ToolName:  "Write",
		CWD:       canonicalize(repoA),
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + target + `"}`),
	}
	wd := classifyFileTool(writeEv)
	wantBucket(t, wd, BucketDeny, "#148 cross-repo Write")
	if !containsSubstr(wd.Reason, ".claude/tmp/") {
		t.Errorf("#30: #148 Write deny must name .claude/tmp/; got %q", wd.Reason)
	}
	if !containsSubstr(wd.Reason, ".git/") {
		t.Errorf("#30: #148 Write deny must warn against .git/; got %q", wd.Reason)
	}
	// #193: prescribing ONLY the in-repo destination left a genuine cross-repo /
	// cross-session handoff file with no legal landing spot, so the write denies
	// now name the harness scratchpad as the second destination.
	if !containsSubstr(wd.Reason, harnessScratchDisplay()) {
		t.Errorf("#193: #148 Write deny must also name the harness scratchpad; got %q", wd.Reason)
	}

	// #148 cross-repo Read deny (a non-mutating tool) still forbids .git/ but
	// does not prescribe .claude/tmp/ (the scratch hint is write-only).
	readEv := &Event{
		ToolName:  "Read",
		CWD:       canonicalize(repoA),
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + target + `"}`),
	}
	rd := classifyFileTool(readEv)
	wantBucket(t, rd, BucketDeny, "#148 cross-repo Read")
	if !containsSubstr(rd.Reason, ".git/") {
		t.Errorf("#30: #148 Read deny must forbid .git/ as a workaround; got %q", rd.Reason)
	}
	// #193: a read deny still prescribes no scratch destination (that hint is
	// write-only), but it must point at the handoff location — the blocked read
	// is often a session reaching for a file another session wrote.
	if !containsSubstr(rd.Reason, harnessScratchDisplay()) {
		t.Errorf("#193: #148 Read deny must name the harness scratchpad handoff location; got %q", rd.Reason)
	}

	// #127 worktree-escape Write deny steers scratch writes to the worktree's
	// .claude/tmp/ and warns against .git/.
	primary, wt := setupWorktree(t)
	wtEv := &Event{
		ToolName:  "Write",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + filepath.Join(primary, "agents", "x.md") + `"}`),
	}
	wtd := classifyFileTool(wtEv)
	wantBucket(t, wtd, BucketDeny, "#127 worktree escape Write")
	if !containsSubstr(wtd.Reason, ".claude/tmp/") {
		t.Errorf("#30: #127 Write deny must steer scratch to .claude/tmp/; got %q", wtd.Reason)
	}
	if !containsSubstr(wtd.Reason, ".git/") {
		t.Errorf("#30: #127 Write deny must warn against .git/; got %q", wtd.Reason)
	}

	// #148 bash-read cross-repo deny explicitly forbids the .git/ workaround.
	bev := &Event{ToolName: "Bash", CWD: canonicalize(repoA), AgentType: "main"}
	bd := classifyBash("cat "+target, bev)
	wantBucket(t, bd, BucketDeny, "#148 bash-read cross-repo")
	if !containsSubstr(bd.Reason, ".git/") {
		t.Errorf("#30: #148 bash-read deny must forbid .git/ as a workaround; got %q", bd.Reason)
	}

	// #130: a bash-read of a non-.git/ file in the primary clone is now
	// contained/defer, not an ask — the #127 worktree-escape ask no longer
	// applies to reads. The .git/-tree deny is what still forbids the .git/
	// workaround for bash-reads of the primary clone.
	gitCfg := filepath.Join(primary, ".git", "config")
	bwev := &Event{ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	bwd := classifyBash("cat "+gitCfg, bwev)
	wantBucket(t, bwd, BucketDeny, "#125 bash-read of .git/ under primary clone")
	if !containsSubstr(bwd.Reason, ".git/") {
		t.Errorf("#30: .git/-tree bash-read deny must forbid .git/ as a workaround; got %q", bwd.Reason)
	}
}

// §10: a symlinked target that points outside the worktree is blocked (#12 —
// both sides canonicalized). Uses a mutating tool (Write): #130 relaxed the
// primary-clone-read case to contained/defer, but a WRITE resolving through a
// symlink into the primary clone must still be caught and denied.
func TestContainmentSymlinkEscape_12(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink semantics differ on windows")
	}
	primary, wt := setupWorktree(t)

	// Create a symlink INSIDE the worktree that points OUTSIDE it (into the
	// primary clone). A naive prefix check on the un-canonicalized path would
	// see it under the worktree and allow; canonicalization must catch it.
	outsideTarget := filepath.Join(primary, "secret.txt")
	_ = os.WriteFile(outsideTarget, []byte("secret"), 0o644)
	link := filepath.Join(wt, "link-to-outside")
	if err := os.Symlink(outsideTarget, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	ev := &Event{
		ToolName:  "Write",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + link + `"}`),
	}
	d := classifyFileTool(ev)
	// The link resolves into the primary clone → worktree escape (DENY).
	wantBucket(t, d, BucketDeny, "#12 symlink escaping worktree")
}

// #130: a Read through a symlink that resolves into the primary clone (a
// non-.git/ path) is now contained/defer, not denied — the relaxation must
// apply after symlink canonicalization too, not just to literal paths.
func TestContainmentSymlinkPrimaryCloneRead_130(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink semantics differ on windows")
	}
	primary, wt := setupWorktree(t)

	outsideTarget := filepath.Join(primary, "plugin.json")
	_ = os.WriteFile(outsideTarget, []byte("{}"), 0o644)
	link := filepath.Join(wt, "link-to-plugin-json")
	if err := os.Symlink(outsideTarget, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	ev := &Event{
		ToolName:  "Read",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + link + `"}`),
	}
	d := classifyFileTool(ev)
	if d.Bucket == BucketDeny || d.Bucket == BucketAsk {
		t.Errorf("#130: Read through a symlink into the primary clone (non-.git/) must not deny/ask; got %q (%s)", d.Bucket, d.Reason)
	}
}

// §10: fail-closed when git rev-parse cannot resolve the context.
func TestContainmentFailClosed_NoRepo(t *testing.T) {
	// A cwd that is not a git repo → resolveRepoContext errors → ASK, never allow.
	nonRepo := t.TempDir()
	ev := &Event{
		ToolName:  "Write",
		CWD:       nonRepo,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + filepath.Join(nonRepo, "x") + `"}`),
	}
	d := classifyFileTool(ev)
	if d.Bucket == BucketAllow || d.Bucket == BucketDefer {
		t.Errorf("no-repo containment must fail closed (ask/deny); got %q", d.Bucket)
	}
}

// §10: fail-closed when the event has no cwd.
func TestContainmentFailClosed_NoCWD(t *testing.T) {
	ev := &Event{ToolName: "Write", CWD: "", ToolInput: []byte(`{"file_path":"/etc/passwd"}`)}
	d := classifyFileTool(ev)
	if d.Bucket == BucketAllow || d.Bucket == BucketDefer {
		t.Errorf("empty cwd must fail closed; got %q", d.Bucket)
	}
}

// TestCanonicalizeFromExpandsTilde pins the containment-level fix (PR #139
// follow-up review) directly at canonicalizeFrom, independent of any Bash
// classification path. Before this fix, `~/.ssh/id_rsa` was not
// filepath.IsAbs, so it silently fell through to the relative-join branch
// and resolved as `<base>/~/.ssh/id_rsa` — a literal, in-repo-looking child
// path that masked an escape to the real home directory as `contained`.
func TestCanonicalizeFromExpandsTilde(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		t.Skip("no resolvable home directory in this environment")
	}
	wantHomeFile := canonicalize(filepath.Join(home, ".ssh", "id_rsa"))

	base := t.TempDir()

	got := canonicalizeFrom("~/.ssh/id_rsa", base)
	if got != wantHomeFile {
		t.Errorf("canonicalizeFrom(%q, base) = %q, want %q (must resolve against the real home directory, not <base>/~/...)",
			"~/.ssh/id_rsa", got, wantHomeFile)
	}
	if pathUnder(got, canonicalize(base)) {
		t.Errorf("canonicalizeFrom(%q, base) = %q must NOT resolve under base %q", "~/.ssh/id_rsa", got, base)
	}

	wantHome := canonicalize(home)
	if gotBare := canonicalizeFrom("~", base); gotBare != wantHome {
		t.Errorf("canonicalizeFrom(\"~\", base) = %q, want %q", gotBare, wantHome)
	}
}

// TestContainmentTildeEscapeDenied covers the same fix one layer up, through
// testContainmentFrom: a tilde-prefixed target must earn the escape verdict
// its real (home-directory) location deserves, not `contained`.
func TestContainmentTildeEscapeDenied(t *testing.T) {
	if _, err := os.UserHomeDir(); err != nil {
		t.Skip("no resolvable home directory in this environment")
	}
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	rc := &repoContext{insideWorkTree: true, topLevel: canonicalize(repo)}

	result, _ := testContainmentFrom("~/.ssh/id_rsa", canonicalize(repo), rc)
	if result == contained {
		t.Errorf("tilde-prefixed target must not resolve as contained; got %v", result)
	}
}

// failingHomeDir is a homeDir resolver that deterministically fails, for
// pinning canonicalizeFromResolver's no-home branch without depending on
// (or skipping under) the ambient test environment's actual home-directory
// resolvability.
func failingHomeDir() (string, error) {
	return "", fmt.Errorf("injected: home directory unresolvable")
}

// TestCanonicalizeFromResolverNoHomeUnresolvedTilde pins canonicalizeFrom
// Resolver's no-home branch directly: PR #139 round-3 review found that the
// previous fix (TestCanonicalizeFromExpandsTilde /
// TestContainmentTildeEscapeDenied above) only covered the home-resolvable
// path — both of those tests t.Skip when there is no home, so the no-home
// branch shipped completely unpinned, and it fell through to the ordinary
// relative-join and resolved as `<base>/~/.ssh/id_rsa`, an in-repo-looking
// path (fail-OPEN), despite a code comment and the README both claiming it
// matched applyCd's fail-closed ("invalidate rather than guess") posture.
//
// This test injects a homeDir resolver that always fails, so it runs
// deterministically in every environment (real $HOME set or not) — it does
// NOT skip, which is the whole point: the no-home branch must always be
// exercised, never silently skipped again.
func TestCanonicalizeFromResolverNoHomeUnresolvedTilde(t *testing.T) {
	base := t.TempDir()

	for _, p := range []string{"~", "~/.ssh/id_rsa"} {
		_, unresolvedTilde := canonicalizeFromResolver(p, base, failingHomeDir)
		if !unresolvedTilde {
			t.Errorf("canonicalizeFromResolver(%q, base, failingHomeDir) unresolvedTilde = false, want true", p)
		}
		// Note: the returned `real` string is only a best-effort display
		// value here (still `<base>/~/...`-shaped — the same string the old,
		// buggy code would have treated as `contained`). unresolvedTilde is
		// the ONLY signal a caller may rely on to fail closed; see
		// testContainmentFrom, which checks unresolvedTilde BEFORE running
		// any pathUnder comparison against real.
	}

	// Non-tilde and resolvable-tilde-adjacent paths are unaffected: no
	// leading `~` means the homeDir resolver is never consulted.
	if real, unresolvedTilde := canonicalizeFromResolver("a.md", base, failingHomeDir); unresolvedTilde {
		t.Errorf("canonicalizeFromResolver(%q, ...) unresolvedTilde = true, want false; real = %q", "a.md", real)
	}
	if real, unresolvedTilde := canonicalizeFromResolver("foo~bar", base, failingHomeDir); unresolvedTilde {
		t.Errorf("canonicalizeFromResolver(%q, ...) unresolvedTilde = true, want false (non-leading ~ is a literal); real = %q",
			"foo~bar", real)
	}
}

// TestContainmentNoHomeTildeFailsClosed pins the fix one layer up, through
// testContainmentFrom, using t.Setenv("HOME", "") to deterministically force
// os.UserHomeDir to fail on Unix (UserHomeDir reads $HOME directly) rather
// than relying on — or skipping under — whatever the ambient test
// environment's real home-directory resolvability happens to be. This is
// the exact "HOME unset" scenario from the PR #139 round-3 review (cron
// jobs, minimal containers, stripped environments): a leading-tilde operand
// must earn a non-contained (escapeRepo) verdict, never `contained`, so
// every caller (classifyFileTool, containPathOperands, containWriteOperands)
// denies rather than allows.
func TestContainmentNoHomeTildeFailsClosed(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("os.UserHomeDir reads the USERPROFILE env var on windows, not HOME")
	}
	t.Setenv("HOME", "")

	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	rc := &repoContext{insideWorkTree: true, topLevel: canonicalize(repo)}

	for _, p := range []string{"~", "~/.ssh/id_rsa"} {
		result, _ := testContainmentFrom(p, canonicalize(repo), rc)
		if result != escapeRepo {
			t.Errorf("testContainmentFrom(%q, repo, rc) with HOME unset = %v, want escapeRepo (fail closed); "+
				"a %v verdict here is the exact fail-open this test pins against", p, result, result)
		}
	}
}
