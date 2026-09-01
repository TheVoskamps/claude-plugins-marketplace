package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
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

// §10: a subagent Write whose target resolves to the primary clone is blocked;
// the same write to the correct in-worktree path is allowed.
func TestContainmentWorktreeEscape(t *testing.T) {
	primary, wt := setupWorktree(t)

	// Write into the primary clone from a worktree cwd → DENY.
	ev := &Event{
		ToolName:  "Write",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + filepath.Join(primary, "agents", "pr-reviewer.md") + `"}`),
	}
	d := classifyFileTool(ev)
	wantBucket(t, d, BucketDeny, "write into primary clone")
	if !containsSubstr(d.Reason, "worktree") {
		t.Errorf("deny reason should mention the worktree; got %q", d.Reason)
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

// Reading a non-.git/ working file in the primary clone / shared git dir
// from a linked worktree DENIES: the primary clone's copy can differ from
// this worktree's, so the read returns plausible content from the wrong tree
// with no error. The write-side worktree-escape deny and the .git/-tree deny
// (both reads and writes) must survive unchanged, and cross-repo reads must
// still deny.
func TestPrimaryCloneReadDenied(t *testing.T) {
	primary, wt := setupWorktree(t)

	relJSON := filepath.Join("plugins", "guardrails", ".claude-plugin", "plugin.json")
	pluginJSON := filepath.Join(primary, relJSON)
	if err := os.MkdirAll(filepath.Dir(pluginJSON), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pluginJSON, []byte(`{"version":"0.9.2"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	// The worktree carries its own copy of the same tracked path, which is what
	// makes the prefix substitution name a file the reader can open. Without
	// this the deny would take the ref-extraction branch instead.
	wtJSON := filepath.Join(wt, relJSON)
	if err := os.MkdirAll(filepath.Dir(wtJSON), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(wtJSON, []byte(`{"version":"0.9.3"}`), 0o644); err != nil {
		t.Fatal(err)
	}

	// bash-read (cat) of a primary-clone working file from a worktree → DENY,
	// prescribing the worktree-anchored path the reader should have used.
	bev := &Event{ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	bd := classifyBash("cat "+pluginJSON, bev)
	wantBucket(t, bd, BucketDeny, "bash-read of a primary-clone working file")
	if bd.Operation != "bash-read:worktree-escape" {
		t.Errorf("bash-read deny must carry the worktree-escape operation; got %q", bd.Operation)
	}
	if !strings.Contains(bd.Reason, "Read '"+wtJSON+"' instead") {
		t.Errorf("bash-read deny must prescribe the corrected worktree path; got %q", bd.Reason)
	}

	// Read tool on a primary-clone working file → DENY, same shape.
	rev := &Event{
		ToolName:  "Read",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + pluginJSON + `"}`),
	}
	rd := classifyFileTool(rev)
	wantBucket(t, rd, BucketDeny, "Read of a primary-clone working file")
	if rd.Operation != "read:worktree-escape" {
		t.Errorf("Read deny must carry the worktree-escape operation; got %q", rd.Operation)
	}
	if !strings.Contains(rd.Reason, "Read '"+wtJSON+"' instead") {
		t.Errorf("Read deny must prescribe the corrected worktree path; got %q", rd.Reason)
	}

	// Write / Edit on a primary-clone path DENY on the write side's own
	// grounds, under the write reason string.
	for _, tool := range []string{"Write", "Edit"} {
		wev := &Event{
			ToolName:  tool,
			CWD:       wt,
			AgentType: "issue-developer",
			ToolInput: []byte(`{"file_path":"` + pluginJSON + `"}`),
		}
		wd := classifyFileTool(wev)
		wantBucket(t, wd, BucketDeny, tool+" to primary-clone path must still deny")
	}

	// cat <primary-clone>/.git/config is gated by the .git/-tree rule, which
	// is checked ahead of the working-file deny and carries its own reason.
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

	// cat <sibling-repo>/node_modules/x still cross-repo deny — the
	// worktree-escape deny must not swallow the cross-repo one.
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
	wantBucket(t, siblingBd, BucketDeny, "cat sibling-repo node_modules must still cross-repo deny")
}

// A read of a file inside ANOTHER agent's worktree denies like any other
// primary-clone escape, but its remediation must not be the prefix
// substitution: <primary>/.claude/worktrees/agent-other/x rewrites to
// <this-worktree>/.claude/worktrees/agent-other/x, a path this worktree never
// checks out. The deny prescribes a ref extraction instead, and says so.
func TestForeignWorktreeReadDenyPrescribesRefExtraction(t *testing.T) {
	primary, wt := setupWorktree(t)

	other := filepath.Join(primary, ".claude", "worktrees", "agent-cafebabe")
	target := filepath.Join(other, "plugins", "guardrails", "notes.md")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("other agent's notes"), 0o644); err != nil {
		t.Fatal(err)
	}

	bogus := filepath.Join(wt, ".claude", "worktrees", "agent-cafebabe", "plugins", "guardrails", "notes.md")

	for _, c := range []struct {
		name string
		got  Decision
	}{
		{"bash-read", classifyBash("cat "+target,
			&Event{ToolName: "Bash", CWD: wt, AgentType: "issue-developer"})},
		{"Read tool", classifyFileTool(&Event{
			ToolName: "Read", CWD: wt, AgentType: "issue-developer",
			ToolInput: []byte(`{"file_path":"` + target + `"}`),
		})},
	} {
		wantBucket(t, c.got, BucketDeny, c.name+" of another worktree's file")
		if strings.Contains(c.got.Reason, "Read '"+bogus+"' instead") {
			t.Errorf("%s deny must not prescribe the unreachable substituted path; got %q", c.name, c.got.Reason)
		}
		if !strings.Contains(c.got.Reason, "git show HEAD:<path-relative-to-repo-root>") {
			t.Errorf("%s deny must prescribe the ref extraction; got %q", c.name, c.got.Reason)
		}
	}
}

// Every bash read path routes through containPathOperands, so the working-file
// deny reaches the read-only-utility track and the pager/dumper track alike.
// The controls that bound it: the same read from the primary clone's OWN cwd
// stays allowed (there is no worktree to be stale against), and an in-worktree
// read from the worktree cwd stays allowed.
func TestPrimaryCloneReadDeniedAcrossBashReadTracks(t *testing.T) {
	primary, wt := setupWorktree(t)

	readme := filepath.Join(primary, "README.md")
	if err := os.WriteFile(readme, []byte("primary\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	wtReadme := filepath.Join(wt, "README.md")
	if err := os.WriteFile(wtReadme, []byte("worktree\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	for _, prog := range []string{"cat", "grep -n x", "head -n 5", "less"} {
		fromWorktree := &Event{ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
		wantReason(t, classifyBash(prog+" "+readme, fromWorktree), BucketDeny,
			"not this worktree", "read of a primary-clone working file: "+prog)

		// Control: the primary clone's own cwd is not a linked worktree, so the
		// identical read is not an escape at all.
		fromPrimary := &Event{ToolName: "Bash", CWD: primary, AgentType: "issue-developer"}
		if d := classifyBash(prog+" "+readme, fromPrimary); d.Bucket == BucketDeny {
			t.Errorf("%s of an in-repo file from the primary clone's cwd must not deny; got %q", prog, d.Reason)
		}

		// Control: an in-worktree read from the worktree cwd is contained.
		if d := classifyBash(prog+" "+wtReadme, fromWorktree); d.Bucket == BucketDeny {
			t.Errorf("%s of an in-worktree file must not deny; got %q", prog, d.Reason)
		}
	}

	// Control: the Read tool from the primary clone's own cwd is likewise not
	// an escape.
	fromPrimary := &Event{
		ToolName:  "Read",
		CWD:       primary,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + readme + `"}`),
	}
	if d := classifyFileTool(fromPrimary); d.Bucket == BucketDeny {
		t.Errorf("Read of an in-repo file from the primary clone's cwd must not deny; got %q", d.Reason)
	}
}

// §10: a Read/bash-read targeting a sibling repo is blocked.
func TestContainmentCrossRepo(t *testing.T) {
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
	wantBucket(t, d, BucketDeny, "read sibling repo node_modules")

	// bash-read (cat) of the sibling file → DENY.
	bev := &Event{ToolName: "Bash", CWD: canonicalize(repoA), AgentType: "main"}
	bd := classifyBash("cat "+target, bev)
	wantBucket(t, bd, BucketDeny, "bash cat sibling repo")

	// Reading a file inside the current repo → not denied.
	own := filepath.Join(repoA, "README.md")
	_ = os.WriteFile(own, []byte("x"), 0o644)
	ev2 := &Event{ToolName: "Read", CWD: canonicalize(repoA), ToolInput: []byte(`{"file_path":"` + own + `"}`)}
	if classifyFileTool(ev2).Bucket == BucketDeny {
		t.Errorf("in-repo read must not DENY")
	}
}

// A subagent Read of the agent's own ~/.claude global config tree
// from inside a repo must DEFER (so the settings.json allow-list governs it),
// NOT be hard-denied as a cross-repo escape — while a genuine sibling-repo
// node_modules read is still denied (that deny must not regress).
func TestClaudeConfigCarveOut(t *testing.T) {
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
		t.Errorf("Read of ~/.claude config must not DENY (allow-list governs it); got %q (%s)", d.Bucket, d.Reason)
	}
	if d.Bucket != BucketDefer {
		t.Errorf("Read of ~/.claude config should DEFER to the normal pipeline; got %q", d.Bucket)
	}

	// The cross-repo deny must not regress: a sibling repo's node_modules read
	// is still denied.
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
	wantBucket(t, classifyFileTool(ev2), BucketDeny, "sibling node_modules still denied")
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
// An earlier revision of the carve-out spec prescribed a single-dash-only pattern,
// which this gate faithfully implemented and which silently excluded every
// such session — reintroducing the very symptom the carve-out exists to fix. Every
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

// Session row (ALLOW): a file-tool or bash read/write whose canonical target
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
func TestHarnessScratchSessionAllowed(t *testing.T) {
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

// A `.git/` segment inside the scratchpad prefix denies for read and write
// alike, so no carve-out hands out a git internals tree — the sibling of
// TestXDGConfigCarveOutDoesNotOpenGitTree, with the same two halves: the write
// on the top-of-walk rule, the read inside the arm that grades scratchpad
// eligibility, which is the only place such a read could otherwise reach an
// ALLOW (a target under the harness prefix is outside the worktree, so without
// the carve-out it is an escape). Every allow-eligible region is covered, and
// the sibling non-`.git/` read is the negative control that the deny is the
// `.git/` rule rather than a shape miss.
func TestHarnessScratchDoesNotOpenGitTree(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	uid := os.Getuid()

	regions := map[string]string{
		"session scratchpad": filepath.Join(sessionSlug, sessionUUID, "scratchpad"),
		"session tasks":      filepath.Join(sessionSlug, sessionUUID, "tasks"),
		"bundled-skills":     filepath.Join("bundled-skills", bundledVersion, bundledHash, "skill"),
	}
	for what, rel := range regions {
		target := scratchTarget(uid, rel, ".git", "config")
		for _, tc := range []struct{ tool, op string }{
			{"Read", "read:.git tree"},
			{"Write", "write:.git tree"},
		} {
			d := fileToolBucket(t, tc.tool, root, target)
			wantBucket(t, d, BucketDeny, tc.tool+" under .git/ in the "+what+" region")
			if !containsSubstr(d.Operation, tc.op) {
				t.Errorf("%s under .git/ in the %s region should deny as %q; got op %q (%s)",
					tc.tool, what, tc.op, d.Operation, d.Reason)
			}
		}

		d := fileToolBucket(t, "Read", root, scratchTarget(uid, rel, "notes.md"))
		wantBucket(t, d, BucketAllow, "read of a "+what+" path with no .git/ segment")
	}
}

// "Reaching the carve-out from bash", gate 1: a carve-out the bash track
// cannot reach is not a carve-out. `ls` is the command whose whole job is naming
// what is in a directory, and it was in NEITHER bash read track — not
// readOnlyUtilities, not the classifyPathReader dispatch — so it deferred for
// every path, carve-out or not, while `find` and `grep` (both strictly more
// capable) allowed. That gap made the spec's own worked example — an `ls` of the
// bundled-skills hash directory, which the shape's trailing `(/|$)` exists to
// cover — false.
//
// Both regions are asserted, because they are graded differently everywhere else
// (bundled-skills is read-eligible only) and `ls` is a read.
func TestHarnessScratchLsAllowed(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	uid := os.Getuid()

	canonRoot := harnessScratchRootResolver().root
	hashDirRel := filepath.Join("bundled-skills", bundledVersion, bundledHash)

	for label, mk := range map[string]func(string) string{
		"literal /tmp":  func(r string) string { return scratchTarget(uid, r) },
		"canonicalized": func(r string) string { return filepath.Join(canonRoot, r) },
	} {
		targets := map[string]string{
			"session scratchpad":     mk(filepath.Join(sessionSlug, sessionUUID, "scratchpad")),
			"session tasks":          mk(filepath.Join(sessionSlug, sessionUUID, "tasks")),
			"doubled-dash slug":      mk(filepath.Join(doubleDashSlug, sessionUUID, "scratchpad")),
			"bundled-skills hashdir": mk(hashDirRel),
		}
		for what, target := range targets {
			bev := bashEvIn(t, root, "issue-developer")
			for _, cmd := range []string{"ls " + target, "ls -la " + target} {
				wantBucket(t, classifyBash(cmd, bev), BucketAllow, label+" / "+what+": "+cmd)
			}
			// The table's fail-safe convention survives the addition: an `ls`
			// carrying a flag lsDefers does not model defers even though the
			// operand is squarely inside the carve-out.
			wantBucket(t, classifyBash("ls --frobnicate "+target, bev), BucketDefer,
				label+" / "+what+": an unrecognized ls flag defers")
		}
	}

	// Structural pin: `ls` is on the read-only-utility ALLOW track (path-bearing,
	// with a fail-safe predicate), not on the DEFER-terminal pager dispatch. The
	// end-to-end assertions above would also pass if some future refactor moved
	// `ls` somewhere else that happened to allow; this names the requirement.
	spec, ok := readOnlyUtilities["ls"]
	if !ok {
		t.Fatal("`ls` must be in readOnlyUtilities, or the bundled-skills `ls` example is false again")
	}
	if !spec.pathBearing {
		t.Error("`ls` must be pathBearing — its operands are paths Engine B has to contain")
	}
	if spec.defersForm == nil {
		t.Error("`ls` must carry a defersForm so an unrecognized flag fails safe")
	}
}

// "Reaching the carve-out from bash", gate 2: the redirect form of a write
// must reach the same ALLOW its argv-spelled equivalents do. allowEligible()
// vetoes the allow track whenever hasRedirectToFile is set, so
// `echo x > <scratchpad>/f` could never be allowed however well-contained it
// was — while `tee <scratchpad>/f` and `cp <src> <scratchpad>/f` write the same
// bytes to the same region under an ALLOW. The veto now grades its destination
// (redirectVetoesAllow) and lifts for the session shape ONLY.
func TestHarnessScratchRedirectAllowed(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	uid := os.Getuid()
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	canonRoot := harnessScratchRootResolver().root
	for label, mk := range map[string]func(string) string{
		"literal /tmp":  func(r string) string { return scratchTarget(uid, r) },
		"canonicalized": func(r string) string { return filepath.Join(canonRoot, r) },
	} {
		for _, leaf := range []string{"scratchpad", "tasks"} {
			dst := mk(filepath.Join(sessionSlug, sessionUUID, leaf, "f"))
			bev := bashEvIn(t, root, "issue-developer")
			// The acceptance criterion: the redirect and the two argv spellings
			// of the same write all land on the same verdict.
			for _, cmd := range []string{
				"echo x > " + dst,
				"echo x >> " + dst,
				"echo x 2> " + dst,
				"cat a.txt > " + dst,
				"tee " + dst,
				"cp a.txt " + dst,
			} {
				wantBucket(t, classifyBash(cmd, bev), BucketAllow, label+" "+leaf+": "+cmd)
			}
			// Every destination must qualify — a second redirect that escapes
			// the carve-out re-imposes the veto.
			wantBucket(t, classifyBash("echo x > "+dst+" 2> "+mk("loose.md"), bev), BucketDefer,
				label+" "+leaf+": a mixed redirect keeps the veto")
			// A destination the gate cannot pin statically keeps the veto.
			if d := classifyBash("echo x > $DEST", bev); d.Bucket == BucketAllow {
				t.Errorf("%s: a dynamic redirect destination must not ALLOW; got %q", label, d.Bucket)
			}
		}
	}

	// The veto is intact for every destination the carve-out does not cover: an
	// in-repo file (unchanged by the carve-out), the unshaped remainder of the
	// prefix, the read-only-by-policy bundled-skills tree, and /tmp at large.
	bev := bashEvIn(t, root, "issue-developer")
	for label, dst := range map[string]string{
		"an in-repo file":      "out.log",
		"the prefix remainder": scratchTarget(uid, "loose.md"),
		"the bundled-skills tree": scratchTarget(uid, "bundled-skills", bundledVersion,
			bundledHash, "SKILL.md"),
		"a /tmp path outside the prefix": "/tmp/loose-redirect-target.md",
	} {
		wantBucket(t, classifyBash("echo x > "+dst, bev), BucketDefer,
			"the redirect veto stays intact for "+label)
	}

	// Structural pin on the graded veto itself, so a refactor cannot widen it by
	// accident: the lift is keyed to scratchAllowEligible's WRITE grading, which
	// admits the session shape and nothing else.
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: root, AgentType: "issue-developer"}
	sessionDst := scratchTarget(uid, sessionSlug, sessionUUID, "scratchpad", "f")
	if redirectVetoesAllow(simpleCommand{cwd: root}, ev) {
		t.Error("a command with no redirect at all must not be vetoed")
	}
	if redirectVetoesAllow(simpleCommand{
		hasRedirectToFile: true, redirectTargets: []string{sessionDst}, cwd: root,
	}, ev) {
		t.Error("a redirect whose only destination is a session scratchpad must not be vetoed")
	}
	for label, sc := range map[string]simpleCommand{
		"an unresolvable expansion anywhere in the command": {
			hasRedirectToFile: true, hasUnknownExpansion: true,
			redirectTargets: []string{sessionDst}, cwd: root,
		},
		"an unresolvable running cwd": {
			hasRedirectToFile: true, cwdInvalid: true,
			redirectTargets: []string{sessionDst}, cwd: root,
		},
		"a destination that was not recorded": {
			hasRedirectToFile: true, cwd: root,
		},
		"a second destination outside the carve-out": {
			hasRedirectToFile: true, cwd: root,
			redirectTargets: []string{sessionDst, scratchTarget(uid, "loose.md")},
		},
	} {
		if !redirectVetoesAllow(sc, ev) {
			t.Errorf("the redirect veto must hold for %s", label)
		}
	}
}

// "Input redirects must be contained": an input redirect reads a file
// WITHOUT that file ever becoming an argv operand, so before this the read
// containment never saw it — `cat < /etc/passwd` reached the read-only-utility
// classifier with ZERO operands and was allowed outright. The sources are now
// merged into the same containment walk that grades operands, so the two
// spellings of one read cannot carry two verdicts.
//
// The equivalence assertions are the load-bearing ones: each redirect form is
// compared against its own operand form rather than against a hardcoded bucket,
// so the two can never drift apart, whatever either verdict later becomes.
func TestInputRedirectContained(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	uid := os.Getuid()
	bev := bashEvIn(t, root, "issue-developer")

	// The headline acceptance row: an out-of-repo source DENIES, with the same
	// message the operand form emits.
	outOfRepo := filepath.Join(canonicalize(sibling), ".env")
	dRedirect := classifyBash("cat < "+outOfRepo, bev)
	dOperand := classifyBash("cat "+outOfRepo, bev)
	wantBucket(t, dRedirect, BucketDeny, "`cat < <out-of-repo>` must deny")
	if dRedirect.Reason != dOperand.Reason || dRedirect.Operation != dOperand.Operation {
		t.Errorf("the redirect form must emit the operand form's message;\n got %q / %q\nwant %q / %q",
			dRedirect.Operation, dRedirect.Reason, dOperand.Operation, dOperand.Reason)
	}

	// Every other source: the redirect form must land on exactly the operand
	// form's verdict. `~/.claude` and the unresolved expansion are listed for the
	// same reason as the rest — whatever the operand form does, the redirect form
	// does. (Measured today: the curated read-utility track ALLOWs a ~/.claude
	// operand, and an unresolvable path DEFERs, because a path-bearing utility
	// fails closed on a dynamic path.)
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	for label, src := range map[string]string{
		"an in-repo file":                "a.txt",
		"an absolute in-repo file":       filepath.Join(root, "a.txt"),
		"a session scratchpad file":      scratchTarget(uid, sessionSlug, sessionUUID, "scratchpad", "f"),
		"a tasks file":                   scratchTarget(uid, sessionSlug, sessionUUID, "tasks", "f"),
		"a bundled skill":                scratchTarget(uid, "bundled-skills", bundledVersion, bundledHash, "SKILL.md"),
		"the unshaped prefix remainder":  scratchTarget(uid, "loose.md"),
		"the ~/.claude carve-out":        filepath.Join(home, ".claude", "CLAUDE.md"),
		"an unresolvable expansion":      "$UNRESOLVED_SOURCE",
		"a /tmp path outside the prefix": "/tmp/loose-input-source.md",
	} {
		for _, prog := range []string{"cat", "less"} {
			red := classifyBash(prog+" < "+src, bev)
			op := classifyBash(prog+" "+src, bev)
			if red.Bucket != op.Bucket {
				t.Errorf("%s: %q must match its operand form %q; got %q vs %q",
					label, prog+" < "+src, prog+" "+src, red.Bucket, op.Bucket)
			}
		}
	}

	// The session scratchpad row of the verdict table, asserted directly rather
	// than only by equivalence: a redirected read of the carve-out ALLOWs.
	sess := scratchTarget(uid, sessionSlug, sessionUUID, "scratchpad", "f")
	for _, cmd := range []string{"cat < " + sess, "less < " + sess, "wc -l < " + sess} {
		wantBucket(t, classifyBash(cmd, bev), BucketAllow, "a session-scratchpad source allows: "+cmd)
	}

	// A utility whose own operands are NOT paths still has its source contained:
	// `tee /dev/null` copies stdin to stdout, so an ungraded source would
	// disclose the file under an ALLOW.
	wantBucket(t, classifyBash("tee /dev/null < "+outOfRepo, bev), BucketDeny,
		"a non-path-bearing utility's input source is contained too")

	// The WRITE track: every operand `tee`/`cp` parses is in-repo, and the file
	// being copied in comes from outside the repo entirely.
	for _, cmd := range []string{"tee f.md < " + outOfRepo, "cp a.txt b.txt < " + outOfRepo} {
		wantBucket(t, classifyBash(cmd, bev), BucketDeny,
			"the write track contains its input source: "+cmd)
	}
	// …but a read source can only LOSE that track's allow, never earn one: the
	// bundled-skills tree is read-eligible, so it does not disturb an in-repo
	// write, and it does not authorize a write into the tree either.
	wantBucket(t, classifyBash("tee f.md < "+scratchTarget(uid, "bundled-skills", bundledVersion,
		bundledHash, "SKILL.md"), bev), BucketAllow,
		"a read-eligible source leaves an in-repo write allowed")
	wantBucket(t, classifyBash("tee "+scratchTarget(uid, "bundled-skills", bundledVersion,
		bundledHash, "SKILL.md")+" < a.txt", bev), BucketDefer,
		"a read-eligible region is still not write-eligible")

	// An input and an output redirect are graded independently.
	wantBucket(t, classifyBash("cat < "+outOfRepo+" > "+sess, bev), BucketDeny,
		"the input source is graded even when the destination is carved out")
	wantBucket(t, classifyBash("cat < a.txt > "+sess, bev), BucketAllow,
		"an in-repo source with a carved-out destination allows")
	wantBucket(t, classifyBash("cat < a.txt > /tmp/nope/f", bev), BucketDefer,
		"the destination still faces the redirect veto")

	// The running cwd governs a relative source, exactly as it governs a relative
	// operand.
	if err := os.MkdirAll(filepath.Join(root, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	wantBucket(t, classifyBash("cd sub && cat < ../../sibling/.env", bev), BucketDeny,
		"a relative input source resolves against the running cwd")

	// Heredocs and herestrings are inline text, not file reads: unaffected.
	for _, cmd := range []string{"cat <<EOF\nhi\nEOF", "cat <<-EOF\nhi\nEOF", "cat <<< hello"} {
		wantBucket(t, classifyBash(cmd, bev), BucketAllow, "heredoc/herestring unaffected: "+cmd)
	}
	// /dev/null discloses nothing and must not be graded as an out-of-repo path.
	wantBucket(t, classifyBash("cat < /dev/null", bev), BucketAllow,
		"a /dev/null source is not a containment escape")
	// `<>` opens the file for reading too, so its read half is graded the same.
	wantBucket(t, classifyBash("cat <> "+outOfRepo, bev), BucketDeny,
		"the read half of `<>` is contained like `<`")
}

// TestInputRedirectRecording is the structural half of the fix: the sources
// must be recorded in a field DISTINCT from redirectTargets (a read is not a
// write) and must not set hasRedirectToFile, or a redirected read would face the
// write veto and a read-eligible region would authorize a write. It also pins
// which ops are swept in, since the defect was an op falling through a switch.
func TestInputRedirectRecording(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)

	reduce := func(cmd string) simpleCommand {
		t.Helper()
		cmds, err := extractSimpleCommands(mustParse(t, cmd), cwd, defaultVarResolver(), nil)
		if err != nil || len(cmds) != 1 {
			t.Fatalf("reduce %q: %d commands, err %v", cmd, len(cmds), err)
		}
		return cmds[0]
	}

	sc := reduce("cat < /etc/passwd")
	if len(sc.inputRedirectTargets) != 1 || sc.inputRedirectTargets[0] != "/etc/passwd" {
		t.Errorf("`<` must record its source; got %v", sc.inputRedirectTargets)
	}
	if sc.hasRedirectToFile || len(sc.redirectTargets) != 0 {
		t.Errorf("an input redirect must not be recorded as a write destination; got %v / %v",
			sc.hasRedirectToFile, sc.redirectTargets)
	}
	// Negative control on the superseded shape: before the fix the source was
	// recorded nowhere, so the read tracks had nothing to contain. readTargets is
	// what merges it into the operand walk — pathOperands alone still does not
	// see it, which is precisely why the source had to be recorded separately.
	if got := pathOperands(sc.args[1:]); len(got) != 0 {
		t.Errorf("the source is not an argv operand; pathOperands returned %v", got)
	}
	if got := readTargets(sc.args[1:], sc); len(got) != 1 || got[0] != "/etc/passwd" {
		t.Errorf("readTargets must merge the input source into the read walk; got %v", got)
	}

	// The output ops keep their existing recording, unchanged.
	out := reduce("echo x > out.log")
	if !out.hasRedirectToFile || len(out.redirectTargets) != 1 {
		t.Errorf("an output redirect must still set the write flag; got %v / %v",
			out.hasRedirectToFile, out.redirectTargets)
	}
	if len(out.inputRedirectTargets) != 0 {
		t.Errorf("an output redirect must not be recorded as a read source; got %v",
			out.inputRedirectTargets)
	}

	// Heredocs, herestrings, descriptor duplications and /dev/null are not file
	// reads and must not be swept in.
	for _, cmd := range []string{
		"cat <<EOF\nhi\nEOF",
		"cat <<-EOF\nhi\nEOF",
		"cat <<< hello",
		"cat <&3",
		"cat < /dev/null",
	} {
		if got := reduce(cmd).inputRedirectTargets; len(got) != 0 {
			t.Errorf("%q must record no input source; got %v", cmd, got)
		}
	}

	// `<>` opens for reading as well, so its target IS graded as a read — but it
	// must not set hasRedirectToFile, which is checked BEFORE containment and
	// would replace the read's deny with the veto's defer.
	rw := reduce("cat <> /etc/passwd")
	if len(rw.inputRedirectTargets) != 1 {
		t.Errorf("`<>` must record its read half; got %v", rw.inputRedirectTargets)
	}
	if rw.hasRedirectToFile {
		t.Error("`<>` must not set the write veto, which would mask its read deny")
	}
}

// compoundSpellings wraps one simple command in every compound construct whose
// walk arm forwards the enclosing statement's redirects, with `redirect` (e.g.
// "< src") attached to the COMPOUND rather than to the inner command. A redirect
// written there applies, in bash, to every command inside — so each spelling must
// earn the verdict the bare command earns with the same redirect.
//
// The scaffolding commands (`true`, `false`) are on the curated read-only track,
// so they inherit the redirect and are graded by it too, exactly as bash grades
// them; they never change the verdict away from the inner command's.
//
// The redirect is threaded through this helper rather than concatenated by the
// caller because it does not always land last: on a backgrounded statement it
// must precede the `&`, and `{ …; } & < f` would parse as two statements.
func compoundSpellings(inner, redirect string) map[string]string {
	return map[string]string{
		"a block":              "{ " + inner + "; } " + redirect,
		"a subshell":           "( " + inner + " ) " + redirect,
		"an if/then":           "if true; then " + inner + "; fi " + redirect,
		"an else branch":       "if false; then true; else " + inner + "; fi " + redirect,
		"a for loop":           "for i in 1; do " + inner + "; done " + redirect,
		"a while loop":         "while false; do " + inner + "; done " + redirect,
		"a case arm":           "case x in x) " + inner + ";; esac " + redirect,
		"a nested block":       "{ { " + inner + "; }; } " + redirect,
		"a block in subshell":  "( { " + inner + "; } ) " + redirect,
		"a backgrounded block": "{ " + inner + "; } " + redirect + " &",
	}
}

// TestCompoundRedirectContained pins the compound half of "every
// input-redirect form carries the same verdict as its own operand form", and the
// write half alongside it. Only the CallExpr arm of the walk consumed the
// redirects it was handed; every compound arm recursed with the INNER statement's
// redirects and discarded the enclosing statement's, so the redirect vanished
// before any classifier saw it:
//
//	cat < /etc/passwd                     deny   (the simple form, graded)
//	{ cat; } < /etc/passwd                ALLOW  (operand-less `cat` — a bypass)
//	echo x > <out-of-repo>                defer
//	{ echo x; } > <out-of-repo>           ALLOW  (bare `echo` — a WRITE bypass)
//
// The write row is the serious one: with the redirect dropped the line reduces to
// a pure-output, non-path-bearing command that is allow-eligible on its own, and
// an allow outranks settings.json — so the gate positively blessed an arbitrary
// out-of-repo write it never saw.
//
// The equivalence assertions are the load-bearing ones: each compound spelling is
// compared against the bare command carrying the same redirect, never against a
// hardcoded bucket, so the two cannot drift whatever either verdict later becomes.
func TestCompoundRedirectContained(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	uid := os.Getuid()
	bev := bashEvIn(t, root, "issue-developer")

	outOfRepo := filepath.Join(canonicalize(sibling), ".env")
	sess := scratchTarget(uid, sessionSlug, sessionUUID, "scratchpad", "f")

	// READ side. Each source is graded once in the bare form, then every compound
	// spelling of the same read must land on that same bucket.
	for label, src := range map[string]string{
		"an out-of-repo source":         outOfRepo,
		"an in-repo source":             "a.txt",
		"a session scratchpad source":   sess,
		"a /tmp source outside the uid": "/tmp/loose-compound-source.md",
		"an unresolvable source":        "$UNRESOLVED_SOURCE",
	} {
		want := classifyBash("cat < "+src, bev)
		for shape, spelling := range compoundSpellings("cat", "< "+src) {
			got := classifyBash(spelling, bev)
			if got.Bucket != want.Bucket {
				t.Errorf("%s in %s: %q must match the bare form %q; got %q vs %q (%s)",
					label, shape, spelling, "cat < "+src, got.Bucket, want.Bucket, got.Reason)
			}
		}
	}

	// WRITE side.
	for label, dst := range map[string]string{
		"an out-of-repo destination":       outOfRepo,
		"an in-repo destination":           "a.txt",
		"a session scratchpad destination": sess,
		"an unresolvable destination":      "$UNRESOLVED_DEST",
	} {
		want := classifyBash("echo x > "+dst, bev)
		for shape, spelling := range compoundSpellings("echo x", "> "+dst) {
			got := classifyBash(spelling, bev)
			if got.Bucket != want.Bucket {
				t.Errorf("%s in %s: %q must match the bare form %q; got %q vs %q (%s)",
					label, shape, spelling, "echo x > "+dst, got.Bucket, want.Bucket, got.Reason)
			}
		}
	}

	// The two headline rows asserted directly as well, so a future refactor that
	// collapsed BOTH sides of an equivalence to `allow` would still fail here.
	wantBucket(t, classifyBash("{ cat; } < "+outOfRepo, bev), BucketDeny,
		"a redirected read on a compound denies")
	if d := classifyBash("{ echo x; } > "+outOfRepo, bev); d.Bucket == BucketAllow {
		t.Errorf("a redirected out-of-repo write on a compound must never ALLOW; got %q (%s)",
			d.Bucket, d.Reason)
	}
	// …and the carve-out stays reachable through a compound, or the fix would
	// have closed the hole by breaking the feature.
	wantBucket(t, classifyBash("{ cat; } < "+sess, bev), BucketAllow,
		"a redirected scratchpad read on a compound allows")
	wantBucket(t, classifyBash("{ echo x; } > "+sess, bev), BucketAllow,
		"a redirected scratchpad write on a compound allows")

	// Nesting COMPOSES: bash performs both opens, so an inner redirect does not
	// cancel an outer one and either escaping side denies on its own.
	wantBucket(t, classifyBash("{ cat < "+outOfRepo+"; } < a.txt", bev), BucketDeny,
		"an inner escaping source still denies under an outer redirect")
	wantBucket(t, classifyBash("{ cat < a.txt; } < "+outOfRepo, bev), BucketDeny,
		"an outer escaping source still denies over an inner redirect")

	// A relative source on a compound resolves against the RUNNING cwd, exactly as
	// a relative operand does — the cd tracking the same walk drives is unaffected.
	if err := os.MkdirAll(filepath.Join(root, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	wantBucket(t, classifyBash("cd sub && { cat; } < ../../sibling/.env", bev), BucketDeny,
		"a relative source on a compound resolves against the running cwd")

	// Heredocs and herestrings are inline text, not file reads, on a compound too.
	for _, cmd := range []string{"{ cat; } <<EOF\nhi\nEOF", "{ cat; } <<< hello", "{ cat; } < /dev/null"} {
		wantBucket(t, classifyBash(cmd, bev), BucketAllow, "not a file read: "+cmd)
	}
}

// TestCompoundRedirectThreading is the structural half: the verdicts above
// could match by luck, so this asserts that the enclosing statement's redirects
// actually REACH the inner commands, and that they reach the right ones.
func TestCompoundRedirectThreading(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)

	reduceAll := func(cmd string) []simpleCommand {
		t.Helper()
		cmds, err := extractSimpleCommands(mustParse(t, cmd), cwd, defaultVarResolver(), nil)
		if err != nil {
			t.Fatalf("reduce %q: %v", cmd, err)
		}
		return cmds
	}
	sources := func(sc simpleCommand) []string { return sc.inputRedirectTargets }

	// Negative control on the superseded shape: this is exactly what the walk
	// produced before — one command, zero sources, nothing for containment to
	// grade. If a future refactor drops the threading again, this is the assertion
	// that catches it at the reduction level rather than via a verdict.
	for shape, spelling := range compoundSpellings("cat", "< /etc/passwd") {
		cmds := reduceAll(spelling)
		if len(cmds) == 0 {
			t.Fatalf("%s reduced to no commands", shape)
		}
		for _, sc := range cmds {
			if len(sources(sc)) != 1 || sources(sc)[0] != "/etc/passwd" {
				t.Errorf("%s: every command inside must inherit the source; %v got %v",
					shape, sc.args, sources(sc))
			}
			if sc.hasRedirectToFile {
				t.Errorf("%s: an inherited INPUT redirect must not set the write flag", shape)
			}
		}
	}

	// An output redirect on a compound reaches the write side, not the read side.
	for shape, spelling := range compoundSpellings("echo x", "> out.log") {
		for _, sc := range reduceAll(spelling) {
			if !sc.hasRedirectToFile || len(sc.redirectTargets) != 1 || sc.redirectTargets[0] != "out.log" {
				t.Errorf("%s: every command inside must inherit the destination; %v got %v/%v",
					shape, sc.args, sc.hasRedirectToFile, sc.redirectTargets)
			}
			if len(sources(sc)) != 0 {
				t.Errorf("%s: an output redirect must not be recorded as a read source", shape)
			}
		}
	}

	// Nesting composes: the inner command sees BOTH files, because bash opens both.
	inner := reduceAll("{ cat < inner.txt; } < outer.txt")
	if len(inner) != 1 {
		t.Fatalf("expected one command; got %d", len(inner))
	}
	if got := sources(inner[0]); len(got) != 2 {
		t.Errorf("an inner redirect must not cancel the outer one; got %v", got)
	}

	// A command substitution does NOT inherit. Bash expands it during word
	// expansion, BEFORE it applies the enclosing command's redirections, so the
	// substituted command reads the shell's stdin — attributing the outer file to
	// it would blame a read it never performs.
	for _, sc := range reduceAll(`{ echo "$(cat)"; } < outer.txt`) {
		if len(sc.args) > 0 && basename(sc.args[0]) == "cat" && len(sources(sc)) != 0 {
			t.Errorf("a command substitution must not inherit the enclosing redirect; got %v",
				sources(sc))
		}
	}

	// The cd side effect the same walk drives is unchanged: a `cd` inside a
	// redirected block still moves the running cwd for the commands after it.
	cds := reduceAll("{ cd sub && cat f; } < in.txt")
	last := cds[len(cds)-1]
	if last.cwd != filepath.Join(cwd, "sub") {
		t.Errorf("cd tracking must survive redirect threading; got cwd %q, want %q",
			last.cwd, filepath.Join(cwd, "sub"))
	}
}

// TestRedirectOnlyConstructGraded covers the other half of the same class:
// a statement whose redirects are attached to NO program at all. `[[ … ]]`,
// `(( … ))`, `let`, `export A=1`, an empty `case`, a bare `A=1`, and a bare `> f`
// each emit no command, so their redirects were graded nowhere — and a line that
// pairs one with an ordinary allow-eligible command was therefore ALLOWed
// outright while the shell performed the write:
//
//	[[ -f x ]] > <out-of-repo> && echo hi     ALLOW, and the file is created
//
// The gate now emits a synthetic redirect-only command for exactly these
// statements, graded on the paths its redirects open. As everywhere else, the
// assertion is equivalence with the operand-form spelling.
func TestRedirectOnlyConstructGraded(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	uid := os.Getuid()
	bev := bashEvIn(t, root, "issue-developer")

	outOfRepo := filepath.Join(canonicalize(sibling), ".env")
	sess := scratchTarget(uid, sessionSlug, sessionUUID, "scratchpad", "f")

	// Every construct that runs no program. Each is paired with `&& echo hi` so a
	// dropped redirect leaves a line that is otherwise a clean ALLOW — which is
	// exactly the bypass, and without the pairing the line would defer anyway and
	// the test would pass vacuously.
	constructs := map[string]string{
		"a bare redirect":     "",
		"a test clause":       "[[ -f a ]]",
		"an arithmetic":       "(( 1 + 1 ))",
		"a let clause":        "let n=1+2",
		"a declaration":       "export A=1",
		"an empty case":       "case q in esac",
		"a bare assignment":   "A=1",
		"a redirect-only sub": "( [[ -f a ]] )",
	}

	for label, head := range constructs {
		for _, tc := range []struct{ op, target, partner string }{
			{">", outOfRepo, "echo x > " + outOfRepo},
			{">", "a.txt", "echo x > a.txt"},
			{">", sess, "echo x > " + sess},
			{"<", outOfRepo, "cat < " + outOfRepo},
			{"<", "a.txt", "cat < a.txt"},
			{"<", sess, "cat < " + sess},
		} {
			cmd := strings.TrimSpace(head+" "+tc.op+" "+tc.target) + " && echo hi"
			got := classifyBash(cmd, bev)
			want := classifyBash(tc.partner, bev)
			if got.Bucket != want.Bucket {
				t.Errorf("%s: %q must match its operand form %q; got %q vs %q (%s)",
					label, cmd, tc.partner, got.Bucket, want.Bucket, got.Reason)
			}
		}
		// The headline row, asserted directly: an out-of-repo WRITE through one of
		// these constructs must never ride the companion command's allow.
		cmd := strings.TrimSpace(head+" > "+outOfRepo) + " && echo hi"
		if d := classifyBash(cmd, bev); d.Bucket == BucketAllow {
			t.Errorf("%s: %q must never ALLOW; got %s", label, cmd, d.Reason)
		}
	}

	// Redirects that name no file must NOT cost the line a defer — the fallback
	// fires only when there is something to grade.
	for _, cmd := range []string{
		"[[ -f a ]] > /dev/null && echo hi",
		"[[ -f a ]] >&2 && echo hi",
		"(( 1 + 1 )) < /dev/null && echo hi",
		"[[ -f a ]] && echo hi",
	} {
		wantBucket(t, classifyBash(cmd, bev), BucketAllow, "nothing to grade: "+cmd)
	}

	// Fail-closed on a target the gate cannot pin, matching the operand forms.
	for _, pair := range [][2]string{
		{"[[ -f a ]] < $UNRESOLVED && echo hi", "cat < $UNRESOLVED"},
		{"[[ -f a ]] > $UNRESOLVED && echo hi", "echo x > $UNRESOLVED"},
	} {
		got, want := classifyBash(pair[0], bev), classifyBash(pair[1], bev)
		if got.Bucket != want.Bucket {
			t.Errorf("%q must match %q; got %q vs %q", pair[0], pair[1], got.Bucket, want.Bucket)
		}
		if got.Bucket == BucketAllow {
			t.Errorf("%q must not ALLOW an unresolvable target", pair[0])
		}
	}

	// Structural: the synthetic command is flagged, carries no real program, and
	// records the paths it opens.
	cmds, err := extractSimpleCommands(mustParse(t, "[[ -f a ]] > out.log < in.txt"), root,
		defaultVarResolver(), nil)
	if err != nil || len(cmds) != 1 {
		t.Fatalf("expected one synthetic command; got %d (%v)", len(cmds), err)
	}
	sc := cmds[0]
	if !sc.redirectOnly {
		t.Error("a construct that runs no program must emit a redirect-only command")
	}
	if len(sc.args) != 1 || sc.args[0] != redirectOnlyProgram {
		t.Errorf("the synthetic command must carry only its display name; got %v", sc.args)
	}
	if len(sc.redirectTargets) != 1 || len(sc.inputRedirectTargets) != 1 {
		t.Errorf("both halves must be recorded; got %v / %v",
			sc.redirectTargets, sc.inputRedirectTargets)
	}
}

// Unshaped-remainder row: a target under the <system-tmp>/claude-<uid>
// prefix whose remainder matches NEITHER shape is never denied and never
// escalated — a shape miss costs at most a DEFER, which is what makes the tight
// shape affordable. The verdict is a function of region × TRACK, not of region
// alone: the path-reader and write tracks defer, while the curated
// read-utility track ALLOWs, which is that track's pre-existing terminal for any
// contained-or-carved-out operand (the same one it returns for an in-repo
// operand and for the ~/.claude carve-out) and not something this carve-out
// decides. An earlier revision of the verdict table asserted one verdict per
// region and was wrong about exactly this row.
func TestHarnessScratchShapeMissDefers(t *testing.T) {
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
		// The row, per track, asserted exactly — so a refactor cannot collapse
		// the three columns back into one verdict.
		for _, cmd := range []string{"less " + target, "od " + target, "tee " + target, "touch " + target,
			"cp a.txt " + target} {
			wantBucket(t, classifyBash(cmd, bev), BucketDefer,
				label+": the path-reader and write tracks defer: "+cmd)
		}
		for _, cmd := range []string{"cat " + target, "head " + target, "ls " + target} {
			wantBucket(t, classifyBash(cmd, bev), BucketAllow,
				label+": the curated read-utility track's pre-existing contained terminal is an allow: "+cmd)
		}
	}
}

// Defective-root row (DEFER, and DENY for the write tracks): when the
// claude-<uid> root is not a plain directory
// owned by this uid, the gate cannot prove where a path under it lands, so it
// escalates — with a reason that NAMES the defect, so the failure is not
// mistaken for the containment bug reappearing.
func TestHarnessScratchDefectiveRootEscalates(t *testing.T) {
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
			wantBucket(t, d, BucketDefer, tc.defect+": "+tool+" through a defective scratchpad root")
			if !containsSubstr(d.Reason, tc.wantIn) {
				t.Errorf("%s: the analysis must name the defect (%q); got %q", tc.defect, tc.wantIn, d.Reason)
			}
			if !containsSubstr(d.Reason, harnessScratchDisplay()) {
				t.Errorf("%s: the analysis must name the scratchpad root; got %q", tc.defect, d.Reason)
			}
			if !containsSubstr(d.Reason, "NOT a containment escape") {
				t.Errorf("%s: the analysis must distinguish itself from a containment escape; got %q",
					tc.defect, d.Reason)
			}
		}

		bev := bashEvIn(t, root, "issue-developer")
		for _, cmd := range []string{"cat " + target, "less " + target, "tee " + target, "touch " + target} {
			d := classifyBash(cmd, bev)
			wantBucket(t, d, BucketDefer, tc.defect+": "+cmd)
			if !containsSubstr(d.Reason, tc.wantIn) {
				t.Errorf("%s: %q defer analysis must name the defect; got %q", tc.defect, cmd, d.Reason)
			}
		}
	}

	// A genuine escape in the same command still outranks the root DEFER: the
	// scratchpad-root finding is recorded, not returned inline.
	withScratchRoot(t, harnessScratchRootState{root: fake, defect: "a symlink"})
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	src := filepath.Join(fake, sessionSlug, sessionUUID, "scratchpad", "x.md")
	cpBev := bashEvIn(t, root, "issue-developer")
	wantBucket(t, classifyBash("cp "+src+" "+filepath.Join(canonicalize(sibling), "stolen.md"), cpBev),
		BucketDeny, "a cross-repo destination outranks the defective-root defer")
}

// Outside-the-prefix row (DENY): everything else under /tmp still denies
// exactly as before — a loose /tmp file, and another uid's
// claude-<other-uid> prefix. The carve-out is per-uid, derived from
// os.Getuid() at runtime, never a claude-* glob: real
// machines host claude-501 and claude-503 side by side.
func TestHarnessScratchOutsidePrefixStillDenies(t *testing.T) {
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
			t.Errorf("the /tmp escape deny must name %q; got %q", want, outD.Reason)
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

// NOTHING below the carve-out root needs its own symlink check —
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
func TestHarnessScratchSymlinkBelowRootDenies(t *testing.T) {
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

// The root check itself. Only the FINAL claude-<uid> component is
// Lstat-ed; the parent is symlink-resolved first. Lstat-ing the whole path — or
// rejecting a symlink anywhere in it — would break macOS outright, where /tmp is
// itself a symlink to /private/tmp, so that case is pinned here directly rather
// than left to the end-to-end tests to notice.
func TestScratchRootCheck(t *testing.T) {
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
	// becomes the destination so the defective-root DEFER can fire at all (a fully-canonicalized
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

// The session-shape pattern is matched against the REMAINDER after the
// canonical root is stripped, never the full path, so it is platform-
// independent by construction — it contains neither "/tmp" nor "/private/tmp".
func TestHarnessSessionShape(t *testing.T) {
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

// Both shapes must match the LIVE harness layout on the machine running
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
// i.e. reintroduces the original symptom wherever settings.json still denies /tmp.
func TestHarnessShapesMatchLiveLayout(t *testing.T) {
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
						t.Errorf("the LIVE bundled-skills directory %q does not match the shipped "+
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
					t.Errorf("the LIVE session directory %q does not match the shipped session shape "+
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
	t.Logf("checked %d live session subdirectories and %d live bundled-skills directories under %q",
		checkedSessions, checkedBundles, st.root)
}

// The bundled-skills shape — the OTHER remainder shape under the same
// per-uid prefix, `bundled-skills/<version>/<32-lowercase-hex>/…`. Like the
// session shape it is matched against the remainder only, so it stays platform-
// independent by construction.
func TestHarnessBundledSkillsShape(t *testing.T) {
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

// Bundled-skills rows: the tree is READ/WRITE-GRADED.
// A read matching the shape is ALLOWed outright (the model legitimately reads
// bundled skills, and a DEFER would still lose to a /tmp deny in settings.json);
// a WRITE matching it DEFERS — the content is harness-installed, so the gate has
// no positive grounds to bless a rewrite, but neither is it an escape to deny.
//
// The write case is asserted as EXACTLY BucketDefer — neither allow nor deny —
// so a later refactor cannot quietly collapse it into the read row (an
// allow-or-deny-agnostic assertion would pass under that collapse).
func TestHarnessBundledSkillsReadAllowedWriteDefers(t *testing.T) {
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
		t.Error("a READ of the bundled-skills tree must be allow-eligible")
	}
	if scratchAllowEligible(harnessScratchBundled, false) {
		t.Error("a WRITE to the bundled-skills tree must NOT be allow-eligible — it defers")
	}
	for _, readClass := range []bool{true, false} {
		if !scratchAllowEligible(harnessScratchSession, readClass) {
			t.Errorf("the session scratchpad must be allow-eligible for both classes (readClass=%v)", readClass)
		}
		for _, res := range []containmentResult{contained, escapeRepo, escapeWorktree, claudeConfig,
			harnessScratch, harnessScratchBadRoot} {
			if scratchAllowEligible(res, readClass) {
				t.Errorf("containmentResult %d must not be allow-eligible (readClass=%v)", res, readClass)
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

// A path under bundled-skills/ that does NOT match the shape defers for
// BOTH read and write — it is inside the carved-out prefix, so it is never
// denied, but it is not provably the bundled-skills tree either, so it is never
// allowed. Pinned separately from the shape unit test because the read track's
// terminal ALLOW is what a shape miss must fall short of.
func TestHarnessBundledSkillsShapeMissDefers(t *testing.T) {
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
		// any contained-or-carved-out operand is an ALLOW — the pre-existing
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

// §10 + the .git/-tree write rule, broadened to the whole tree: a direct file-tool
// Write/Edit whose target resolves to ANYWHERE under .git/ is denied (the
// Engine B half of the write criterion, generalized to the whole .git/
// tree). Reads of .git/ files are not mutations and stay allowed/deferred.
func TestGitTreeWriteDenied(t *testing.T) {
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

	// Writes to other paths under .git/ are now denied too.
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

	// An Edit of a submodule-style nested .git/config is denied via
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
	// the .git/ rule (it is in-repo, so it defers).
	rev := &Event{
		ToolName:  "Read",
		CWD:       canonicalize(repo),
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + cfg + `"}`),
	}
	if rd := classifyFileTool(rev); rd.Bucket == BucketDeny {
		t.Errorf("Read of .git/config must not DENY as a .git/-tree write; got %q (%s)", rd.Bucket, rd.Reason)
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

// The under-specified containment-escape denies must be prescriptive —
// they must name <repo-root>/.claude/tmp/ as the scratch destination for
// mutating tools and explicitly warn against .git/ as a workaround target.
// A guardrail that only forbids invites a workaround (writing under .git/
// because it is gitignored and in-repo); one that prescribes prevents it.
func TestContainmentDeniesArePrescriptive(t *testing.T) {
	// Cross-repo Write deny (the file-tool path) names .claude/tmp/ and
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
	wantBucket(t, wd, BucketDeny, "cross-repo Write")
	if !containsSubstr(wd.Reason, ".claude/tmp/") {
		t.Errorf("cross-repo Write deny must name .claude/tmp/; got %q", wd.Reason)
	}
	if !containsSubstr(wd.Reason, ".git/") {
		t.Errorf("cross-repo Write deny must warn against .git/; got %q", wd.Reason)
	}
	// Prescribing ONLY the in-repo destination left a genuine cross-repo /
	// cross-session handoff file with no legal landing spot, so the write denies
	// now name the harness scratchpad as the second destination.
	if !containsSubstr(wd.Reason, harnessScratchDisplay()) {
		t.Errorf("cross-repo Write deny must also name the harness scratchpad; got %q", wd.Reason)
	}

	// Cross-repo Read deny (a non-mutating tool) still forbids .git/ but
	// does not prescribe .claude/tmp/ (the scratch hint is write-only).
	readEv := &Event{
		ToolName:  "Read",
		CWD:       canonicalize(repoA),
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + target + `"}`),
	}
	rd := classifyFileTool(readEv)
	wantBucket(t, rd, BucketDeny, "cross-repo Read")
	if !containsSubstr(rd.Reason, ".git/") {
		t.Errorf("cross-repo Read deny must forbid .git/ as a workaround; got %q", rd.Reason)
	}
	// A read deny still prescribes no scratch destination (that hint is
	// write-only), but it must point at the handoff location — the blocked read
	// is often a session reaching for a file another session wrote.
	if !containsSubstr(rd.Reason, harnessScratchDisplay()) {
		t.Errorf("cross-repo Read deny must name the harness scratchpad handoff location; got %q", rd.Reason)
	}

	// The worktree-escape Write deny steers scratch writes to the worktree's
	// .claude/tmp/ and warns against .git/.
	primary, wt := setupWorktree(t)
	wtEv := &Event{
		ToolName:  "Write",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + filepath.Join(primary, "agents", "x.md") + `"}`),
	}
	wtd := classifyFileTool(wtEv)
	wantBucket(t, wtd, BucketDeny, "worktree escape Write")
	if !containsSubstr(wtd.Reason, ".claude/tmp/") {
		t.Errorf("worktree-escape Write deny must steer scratch to .claude/tmp/; got %q", wtd.Reason)
	}
	if !containsSubstr(wtd.Reason, ".git/") {
		t.Errorf("worktree-escape Write deny must warn against .git/; got %q", wtd.Reason)
	}

	// The bash-read cross-repo deny explicitly forbids the .git/ workaround.
	bev := &Event{ToolName: "Bash", CWD: canonicalize(repoA), AgentType: "main"}
	bd := classifyBash("cat "+target, bev)
	wantBucket(t, bd, BucketDeny, "bash-read cross-repo")
	if !containsSubstr(bd.Reason, ".git/") {
		t.Errorf("cross-repo bash-read deny must forbid .git/ as a workaround; got %q", bd.Reason)
	}

	// A bash-read under the primary clone's .git/ tree carries the .git/-tree
	// reason, not the working-file one: that deny is checked first and names
	// the git internals it protects, so the .git/ workaround stays shut for
	// bash-reads of the primary clone.
	gitCfg := filepath.Join(primary, ".git", "config")
	bwev := &Event{ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	bwd := classifyBash("cat "+gitCfg, bwev)
	wantBucket(t, bwd, BucketDeny, "bash-read of .git/ under primary clone")
	if !containsSubstr(bwd.Reason, ".git/") {
		t.Errorf(".git/-tree bash-read deny must forbid .git/ as a workaround; got %q", bwd.Reason)
	}
}

// §10: a symlinked target that points outside the worktree is blocked (both
// sides canonicalized). Uses a mutating tool (Write): the write deny names the
// state another worktree depends on, where the read deny names the staleness
// hazard, and a WRITE resolving through a symlink into the primary clone must
// be caught by canonicalization rather than by the read rule.
func TestContainmentSymlinkEscape(t *testing.T) {
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
	wantBucket(t, d, BucketDeny, "symlink escaping worktree")
}

// A Read through a symlink that resolves into the primary clone (a
// non-.git/ path) DENIES — the working-file deny must apply after symlink
// canonicalization too, not just to literal paths.
func TestContainmentSymlinkPrimaryCloneRead(t *testing.T) {
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
	wantBucket(t, d, BucketDeny, "Read through a symlink into the primary clone")
	if d.Operation != "read:worktree-escape" {
		t.Errorf("symlinked Read deny must carry the worktree-escape operation; got %q", d.Operation)
	}
}

// §10: never ALLOW when git rev-parse cannot resolve the context. The
// residual is a DEFER carrying the resolution failure as its analysis —
// the boundary is unknown, which is an absence of proof rather than a proven
// escape, and a human clicking Yes learns nothing the evaluator would not.
// What must never happen, then or now, is the ALLOW.
func TestContainmentNoRepoNeverAllows(t *testing.T) {
	nonRepo := t.TempDir()
	ev := &Event{
		ToolName:  "Write",
		CWD:       nonRepo,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + filepath.Join(nonRepo, "x") + `"}`),
	}
	d := classifyFileTool(ev)
	if d.Bucket != BucketDefer {
		t.Errorf("no-repo containment must defer; got %q (%s)", d.Bucket, d.Reason)
	}
	if d.Operation != "file:no-repo-context" || d.Reason == "" {
		t.Errorf("no-repo defer must be loggable; got op=%q reason=%q", d.Operation, d.Reason)
	}
}

// §10: the same when the event has no cwd at all.
func TestContainmentNoCWDNeverAllows(t *testing.T) {
	ev := &Event{ToolName: "Write", CWD: "", ToolInput: []byte(`{"file_path":"/etc/passwd"}`)}
	d := classifyFileTool(ev)
	if d.Bucket != BucketDefer {
		t.Errorf("empty cwd must defer; got %q (%s)", d.Bucket, d.Reason)
	}
	if d.Operation != "file:no-repo-context" || d.Reason == "" {
		t.Errorf("no-cwd defer must be loggable; got op=%q reason=%q", d.Operation, d.Reason)
	}
}

// TestCanonicalizeFromExpandsTilde pins the containment-level fix (found in PR
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
// Resolver's no-home branch directly: a round-3 PR review found that the
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
// the exact "HOME unset" scenario from that round-3 PR review (cron
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
