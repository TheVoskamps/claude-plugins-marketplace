package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
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
// every non-alphanumeric character rewritten to "-", so it LEADS with "-".
const sessionSlug = "-Users-someone-Workspaces-permission-gate-fixture"

// doubleDashSlug is a project slug for a cwd containing a HIDDEN directory.
// The harness rewrites every non-alphanumeric character, so "/." becomes "--"
// and runs of consecutive dashes are ordinary, not exotic: /Users/<u>/.claude
// slugs to -Users-<u>--claude, which is a real session directory on the
// author's machine with the standard scratchpad/ + tasks/ layout.
//
// An earlier revision of the #193 spec prescribed a single-dash-only pattern,
// which this gate faithfully implemented and which silently excluded every
// such session — reintroducing the very symptom #193 exists to fix. Every
// assertion below that names this slug exists to keep that from regressing.
const doubleDashSlug = "-Users-someone--claude"

// tripleDashSlug covers a longer run (a hidden directory nested directly under
// another separator-adjacent non-alphanumeric character), so the pattern is
// pinned as "one or more dashes", not "one or two".
const tripleDashSlug = "-Users-someone---hidden-config"

// The bundled-skills tree the harness installs under the SAME per-uid prefix
// as the session directories: bundled-skills/<version>/<32-lowercase-hex>/
// <skill-name>/… . Values are the live ones observed on the author's machine.
const (
	bundledVersion = "2.1.220"
	bundledHash    = "a8223552af6ad64b91742a43b735f04c"
)

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
	// Both session subdirectories, for a single-dash slug AND for slugs with
	// RUNS of consecutive dashes. The doubled-dash case is the one that
	// regressed once (an earlier spec revision pinned a single-dash-only
	// pattern), so it is pinned end-to-end here, not only at the regexp level:
	// every hidden-directory cwd on a real machine produces one.
	slugs := map[string]string{
		"single-dash slug": sessionSlug,
		"doubled-dash slug (hidden directory in the cwd)": doubleDashSlug,
		"tripled-dash slug": tripleDashSlug,
	}
	for slugLabel, slug := range slugs {
		for _, leaf := range []string{"scratchpad", "tasks"} {
			rel := filepath.Join(slug, sessionUUID, leaf, "handoff.md")
			spellings := map[string]string{
				"literal /tmp":  scratchTarget(uid, rel),
				"canonicalized": filepath.Join(canonRoot, rel),
			}
			for label, target := range spellings {
				label = slugLabel + " / " + label + " " + leaf
				for _, tool := range []string{"Read", "Write", "Edit", "NotebookEdit"} {
					d := fileToolBucket(t, tool, root, target)
					wantBucket(t, d, BucketAllow, label+": "+tool+" of a session scratchpad file")
				}

				bev := bashEvIn(t, root, "issue-developer")
				// Both bash read tracks: the read-only-utility one (cat) and
				// classifyPathReader (less), whose contained terminal is a
				// DEFER — a session-scratchpad operand promotes it to ALLOW.
				for _, cmd := range []string{"cat " + target, "less " + target} {
					wantBucket(t, classifyBash(cmd, bev), BucketAllow, label+": "+cmd)
				}
				// Bash writes into a session directory ride the in-repo-write
				// ALLOW.
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
		// RUNS of consecutive dashes in the project slug — produced by any
		// hidden directory in the session cwd, and therefore ordinary. Both
		// session subdirectories are pinned for each run length.
		doubleDashSlug + "/" + sessionUUID + "/scratchpad/x.md",
		doubleDashSlug + "/" + sessionUUID + "/tasks/x.json",
		tripleDashSlug + "/" + sessionUUID + "/scratchpad/x.md",
		tripleDashSlug + "/" + sessionUUID + "/tasks/x.json",
		// A run at the very start (the cwd's leading "/" plus a leading dot).
		"--claude/" + sessionUUID + "/scratchpad/x.md",
		// A run in the MIDDLE of an otherwise ordinary slug.
		"-Users-someone-Workspaces--config-macos-setup/" + sessionUUID + "/tasks",
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
		// The `-+` widening must NOT have widened the CHARACTER CLASS. The
		// harness's slug alphabet is exactly [A-Za-z0-9-]; anything the harness
		// would itself have rewritten to a dash must still miss the shape.
		"-Users-someone.claude/" + sessionUUID + "/scratchpad/x",
		"-Users_someone/" + sessionUUID + "/scratchpad/x",
		"-Users-some one/" + sessionUUID + "/scratchpad/x",
		// A slug that is only dashes, or that ends in one: every dash run must
		// be followed by at least one alphanumeric character.
		"-/" + sessionUUID + "/scratchpad/x",
		"---/" + sessionUUID + "/scratchpad/x",
		"-Users-someone-/" + sessionUUID + "/scratchpad/x",
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

	// Negative control for the regression this widening fixes. The superseded
	// single-dash-only pattern is spelled out here and asserted to MISS the
	// doubled-dash slug, so the test above cannot be satisfied by re-narrowing
	// the shape: if someone reintroduces `(-[A-Za-z0-9]+)+`, the matches list
	// fails AND this control documents exactly which pattern was wrong and why.
	superseded := regexp.MustCompile(
		`^(?:-[A-Za-z0-9]+)+/` +
			`[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/` +
			`(?:scratchpad|tasks)(?:/|$)`)
	for _, leaf := range []string{"scratchpad", "tasks"} {
		rem := doubleDashSlug + "/" + sessionUUID + "/" + leaf + "/x.md"
		if superseded.MatchString(rem) {
			t.Fatalf("the superseded single-dash pattern was expected to MISS %q — this control is no longer "+
				"testing anything; re-derive it from the pattern actually shipped", rem)
		}
		if !harnessSessionShape.MatchString(rem) {
			t.Errorf("the shipped session shape must match the doubled-dash remainder %q that the superseded "+
				"pattern missed", rem)
		}
	}
}

// #193: both shapes must match the LIVE harness layout on the machine running
// the tests, not only the fixtures above.
//
// This exists because the first implementation round encoded an "observed
// layout across 17 projects on two machines" claim from the issue and shipped a
// pattern that missed every hidden-directory project slug — a claim that one
// `ls` of the real prefix falsified. Fixtures can only ever restate the author's
// belief about the layout; this walks the actual directories the harness
// created. It SKIPS cleanly when the prefix is absent or empty (a fresh machine,
// a Linux CI box), so it costs nothing where there is no ground truth to check.
//
// A failure here means the harness's real layout has drifted away from a shape
// the gate blesses — which silently downgrades those paths from ALLOW to DEFER,
// i.e. reintroduces #193 wherever settings.json still denies /tmp.
func TestHarnessShapesMatchLiveLayout_193(t *testing.T) {
	st := resolveHarnessScratchRoot()
	if st.root == "" || st.defect != "" {
		t.Skipf("no usable harness scratchpad root on this machine (%+v)", st)
	}
	entries, err := os.ReadDir(st.root)
	if err != nil {
		t.Skipf("harness scratchpad root %q is not readable: %v", st.root, err)
	}

	checkedSessions, checkedBundles := 0, 0
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if e.Name() == "bundled-skills" {
			// bundled-skills/<version>/<32-hex>: assert every version/hash pair
			// that actually exists matches the shape.
			versions, verr := os.ReadDir(filepath.Join(st.root, e.Name()))
			if verr != nil {
				continue
			}
			for _, v := range versions {
				hashes, herr := os.ReadDir(filepath.Join(st.root, e.Name(), v.Name()))
				if herr != nil {
					continue
				}
				for _, h := range hashes {
					if !h.IsDir() {
						continue
					}
					rem := e.Name() + "/" + v.Name() + "/" + h.Name()
					if !harnessBundledSkillsShape.MatchString(rem) {
						t.Errorf("#193: the LIVE bundled-skills directory %q does not match the shipped "+
							"bundled-skills shape %q — reads of it degrade from ALLOW to DEFER",
							rem, harnessBundledSkillsShape.String())
					}
					checkedBundles++
				}
			}
			continue
		}
		// <project-slug>/<session-uuid>/{scratchpad,tasks}: assert every session
		// subdirectory that actually exists matches the shape. Directories that
		// do not carry a scratchpad/ or tasks/ child are not session
		// directories and are skipped rather than asserted on.
		sessions, serr := os.ReadDir(filepath.Join(st.root, e.Name()))
		if serr != nil {
			continue
		}
		for _, s := range sessions {
			if !s.IsDir() {
				continue
			}
			for _, leaf := range []string{"scratchpad", "tasks"} {
				fi, ferr := os.Stat(filepath.Join(st.root, e.Name(), s.Name(), leaf))
				if ferr != nil || !fi.IsDir() {
					continue
				}
				rem := e.Name() + "/" + s.Name() + "/" + leaf
				if !harnessSessionShape.MatchString(rem) {
					t.Errorf("#193: the LIVE session directory %q does not match the shipped session shape "+
						"%q — writes to it degrade from ALLOW to DEFER, which is this issue's original "+
						"symptom wherever settings.json still denies /tmp",
						rem, harnessSessionShape.String())
				}
				checkedSessions++
			}
		}
	}
	if checkedSessions == 0 && checkedBundles == 0 {
		t.Skipf("harness scratchpad root %q holds no session or bundled-skills directories yet", st.root)
	}
	t.Logf("#193: checked %d live session subdirectories and %d live bundled-skills directories under %q",
		checkedSessions, checkedBundles, st.root)
}

// #193: the bundled-skills shape — the OTHER remainder shape under the same
// per-uid prefix, `bundled-skills/<version>/<32-lowercase-hex>/…`. Like the
// session shape it is matched against the remainder only, so it stays platform-
// independent by construction.
func TestHarnessBundledSkillsShape_193(t *testing.T) {
	base := "bundled-skills/" + bundledVersion + "/" + bundledHash
	matches := []string{
		// The hash directory ITSELF matches — the shape ends at (/|$) right
		// after the 32-hex segment, so an `ls` of it is covered, not just files
		// beneath it.
		base,
		base + "/",
		base + "/claude-api",
		base + "/claude-api/python/claude-api/SKILL.md",
		// Any semver-shaped version, including multi-digit components.
		"bundled-skills/10.20.30/" + bundledHash + "/x/SKILL.md",
		"bundled-skills/0.0.1/" + bundledHash,
	}
	for _, m := range matches {
		if !harnessBundledSkillsShape.MatchString(m) {
			t.Errorf("remainder %q should match the bundled-skills shape", m)
		}
	}

	nonMatches := []string{
		"",
		"bundled-skills",
		"bundled-skills/",
		// No version segment at all.
		"bundled-skills/" + bundledHash + "/x",
		// A non-semver version segment.
		"bundled-skills/latest/" + bundledHash + "/x",
		"bundled-skills/2.1/" + bundledHash + "/x",
		"bundled-skills/v2.1.220/" + bundledHash + "/x",
		// A channel-tagged version. Documented as a KNOWN miss: the evidence
		// base is one version directory on one machine, and a miss costs a
		// DEFER, never a denial.
		"bundled-skills/2.1.220-beta.1/" + bundledHash + "/x",
		// A version directory with no 32-hex child.
		"bundled-skills/" + bundledVersion,
		"bundled-skills/" + bundledVersion + "/",
		"bundled-skills/" + bundledVersion + "/claude-api/SKILL.md",
		// Hash of the wrong length, or upper-case (the harness emits lower).
		"bundled-skills/" + bundledVersion + "/a8223552af6ad64b91742a43b735f04/x",
		"bundled-skills/" + bundledVersion + "/a8223552af6ad64b91742a43b735f04cd/x",
		"bundled-skills/" + bundledVersion + "/A8223552AF6AD64B91742A43B735F04C/x",
		// Segment-boundary respected: a sibling directory whose name merely
		// starts with "bundled-skills" must not match.
		"bundled-skills-evil/" + bundledVersion + "/" + bundledHash + "/x",
		// Not anchored to the start.
		"other/" + base + "/x",
		// A session-shaped remainder must not match this shape.
		sessionSlug + "/" + sessionUUID + "/scratchpad/x.md",
	}
	for _, m := range nonMatches {
		if harnessBundledSkillsShape.MatchString(m) {
			t.Errorf("remainder %q should NOT match the bundled-skills shape", m)
		}
	}

	// Same platform-independence invariant as the session shape, and the same
	// prohibition on pinning the running Claude Code version: the pattern must
	// carry no literal version.
	for _, forbidden := range []string{"/tmp", "private", "claude-", bundledVersion} {
		if containsSubstr(harnessBundledSkillsShape.String(), forbidden) {
			t.Errorf("the bundled-skills shape must not contain %q; got %q",
				forbidden, harnessBundledSkillsShape.String())
		}
	}
}

// #193 verdict-table rows 2 and 3: the bundled-skills tree is READ/WRITE-GRADED.
// A read matching the shape is ALLOWed outright (the model legitimately reads
// bundled skills, and a DEFER would still lose to a /tmp deny in settings.json);
// a WRITE matching it DEFERS — the content is harness-installed, so the gate has
// no positive grounds to bless a rewrite, but neither is it an escape to deny.
//
// The write case is asserted as EXACTLY BucketDefer — neither allow nor deny —
// so a later refactor cannot quietly collapse it into the read row (an
// allow-or-deny-agnostic assertion would pass under that collapse).
func TestHarnessBundledSkillsReadAllowedWriteDefers_193(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	uid := os.Getuid()

	canonRoot := harnessScratchRootResolver().root
	rel := filepath.Join("bundled-skills", bundledVersion, bundledHash,
		"claude-api", "python", "claude-api", "SKILL.md")
	// The hash directory itself, which an `ls` targets.
	hashDirRel := filepath.Join("bundled-skills", bundledVersion, bundledHash)

	for label, mk := range map[string]func(string) string{
		"literal /tmp":  func(r string) string { return scratchTarget(uid, r) },
		"canonicalized": func(r string) string { return filepath.Join(canonRoot, r) },
	} {
		for _, target := range []string{mk(rel), mk(hashDirRel)} {
			// Read class, file-tool track.
			wantBucket(t, fileToolBucket(t, "Read", root, target), BucketAllow,
				label+": Read of a bundled skill")

			// Read class, both bash read tracks.
			bev := bashEvIn(t, root, "issue-developer")
			for _, cmd := range []string{"cat " + target, "less " + target, "head " + target} {
				wantBucket(t, classifyBash(cmd, bev), BucketAllow, label+": "+cmd)
			}

			// Write class, file-tool track → DEFER, explicitly.
			for _, tool := range []string{"Write", "Edit", "MultiEdit", "NotebookEdit"} {
				wantBucket(t, fileToolBucket(t, tool, root, target), BucketDefer,
					label+": "+tool+" of a bundled skill must DEFER — neither allowed nor denied")
			}

			// Write class, bash track → DEFER, explicitly.
			for _, cmd := range []string{
				"tee " + target,
				"touch " + target,
				"cp " + filepath.Join(root, "a.txt") + " " + target,
			} {
				wantBucket(t, classifyBash(cmd, bev), BucketDefer,
					label+": "+cmd+" must DEFER — neither allowed nor denied")
			}
		}
	}

	// Structural pin on the grading predicate itself. The end-to-end write
	// assertions above land on DEFER, which is also the fallback bucket, so on
	// their own they would survive a refactor that collapsed the write row into
	// the read row somewhere else in the pipeline. This asserts the asymmetry at
	// its single source, where a collapse cannot hide: bundled-skills is
	// read-eligible and NOT write-eligible, while the session shape is eligible
	// for both.
	if !scratchAllowEligible(harnessScratchBundled, true) {
		t.Error("#193: a READ of the bundled-skills tree must be allow-eligible")
	}
	if scratchAllowEligible(harnessScratchBundled, false) {
		t.Error("#193: a WRITE to the bundled-skills tree must NOT be allow-eligible — it defers")
	}
	for _, readClass := range []bool{true, false} {
		if !scratchAllowEligible(harnessScratchSession, readClass) {
			t.Errorf("#193: the session scratchpad must be allow-eligible for both classes (readClass=%v)", readClass)
		}
		for _, res := range []containmentResult{contained, escapeRepo, escapeWorktree, claudeConfig,
			harnessScratch, harnessScratchBadRoot} {
			if scratchAllowEligible(res, readClass) {
				t.Errorf("#193: containmentResult %d must not be allow-eligible (readClass=%v)", res, readClass)
			}
		}
	}

	// A mixed call cannot launder the read allow onto a write: a cp whose
	// SOURCE is a bundled skill and whose destination is a sibling repo still
	// earns the cross-repo deny.
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	cpBev := bashEvIn(t, root, "issue-developer")
	wantBucket(t, classifyBash("cp "+scratchTarget(uid, rel)+" "+
		filepath.Join(canonicalize(sibling), "stolen.md"), cpBev),
		BucketDeny, "cp a bundled skill into a sibling repo")
}

// #193: a path under bundled-skills/ that does NOT match the shape defers for
// BOTH read and write — it is inside the carved-out prefix, so it is never
// denied, but it is not provably the bundled-skills tree either, so it is never
// allowed. Pinned separately from the shape unit test because the read track's
// terminal ALLOW is what a shape miss must fall short of.
func TestHarnessBundledSkillsShapeMissDefers_193(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	uid := os.Getuid()

	misses := map[string]string{
		"non-semver version segment": scratchTarget(uid, "bundled-skills", "latest",
			bundledHash, "claude-api", "SKILL.md"),
		"channel-tagged version": scratchTarget(uid, "bundled-skills", "2.1.220-beta.1",
			bundledHash, "claude-api", "SKILL.md"),
		"version directory with no 32-hex child": scratchTarget(uid, "bundled-skills",
			bundledVersion, "claude-api", "SKILL.md"),
		"the bundled-skills root itself": scratchTarget(uid, "bundled-skills"),
		"hash of the wrong length": scratchTarget(uid, "bundled-skills", bundledVersion,
			"a8223552af6ad64b91742a43b735f04", "SKILL.md"),
	}
	for label, target := range misses {
		for _, tool := range []string{"Read", "Write", "Edit", "NotebookEdit"} {
			wantBucket(t, fileToolBucket(t, tool, root, target), BucketDefer, label+": "+tool)
		}
		bev := bashEvIn(t, root, "issue-developer")
		// classifyPathReader's terminal is a DEFER, and the write track's
		// carve-out arm is a DEFER, so both are asserted exactly.
		for _, cmd := range []string{"less " + target, "tee " + target, "touch " + target} {
			wantBucket(t, classifyBash(cmd, bev), BucketDefer, label+": "+cmd)
		}
		// `cat`/`head` run the read-only-UTILITY classifier, whose terminal for
		// any contained-or-carved-out operand is an ALLOW — pre-existing #32
		// behavior shared with the ~/.claude carve-out and with the rest of the
		// scratchpad prefix, not something the bundled-skills shape decides. So
		// the only claim the shape miss makes here is the one the verdict table
		// makes: it is inside the prefix, therefore never denied and never
		// escalated.
		for _, cmd := range []string{"cat " + target, "head " + target} {
			if d := classifyBash(cmd, bev); d.Bucket == BucketDeny || d.Bucket == BucketAsk {
				t.Errorf("%s: %q is inside the scratchpad prefix and must not deny/ask; got %q (%s)",
					label, cmd, d.Bucket, d.Reason)
			}
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
