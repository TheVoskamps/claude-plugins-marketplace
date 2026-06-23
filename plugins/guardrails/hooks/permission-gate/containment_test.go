package main

import (
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

// §10 + #125 (write half): a direct file-tool Write/Edit whose target resolves
// to a .git/config is denied (the Engine B half of the #125 write criterion).
func TestGitConfigFileWriteDenied_125(t *testing.T) {
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
		if !containsSubstr(d.Reason, "#125") {
			t.Errorf("%s .git/config deny reason should cite #125; got %q", tool, d.Reason)
		}
	}

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
}

// §10: a symlinked target that points outside the worktree is blocked (#12 —
// both sides canonicalized).
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
		ToolName:  "Read",
		CWD:       wt,
		AgentType: "issue-developer",
		ToolInput: []byte(`{"file_path":"` + link + `"}`),
	}
	d := classifyFileTool(ev)
	// The link resolves into the primary clone → worktree escape (DENY).
	wantBucket(t, d, BucketDeny, "#12 symlink escaping worktree")
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
