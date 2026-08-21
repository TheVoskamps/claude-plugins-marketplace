package main

import (
	"os"
	"path/filepath"
	"testing"
)

// A path anchored to a command substitution whose output is a KNOWN
// filesystem location ($(git rev-parse --show-toplevel), $(git rev-parse
// --git-common-dir), $(pwd)/`pwd`) must resolve instead of failing closed to
// a human ASK. Anchor resolution only makes the path KNOWABLE — it must never
// bypass containment or the .git/ deny, and it must respect scopeDepth like
// any other recorded assignment.

// TestGitTopLevelAnchorResolvesToContainment is the shape-B repro:
// `root=$(git rev-parse --show-toplevel); cat "$root/…"` must resolve and run
// through normal containment (contained, not ASK) instead of failing closed
// on the unresolvable command substitution.
func TestGitTopLevelAnchorResolvesToContainment(t *testing.T) {
	_, wt := setupWorktree(t)

	pluginDir := filepath.Join(wt, "plugins", "sdlc", ".claude-plugin")
	if err := os.MkdirAll(pluginDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}

	cmd1 := `root=$(git rev-parse --show-toplevel)
cat "$root/plugins/sdlc/.claude-plugin/plugin.json"`
	d1 := classifyBash(cmd1, ev)
	if d1.Bucket == BucketAsk {
		t.Errorf("repro: $(git rev-parse --show-toplevel) anchor must not ASK; got ASK (%s)", d1.Reason)
	}

	cmd2 := `root=$(git rev-parse --show-toplevel)
grep -rn X "$root/plugins/"`
	d2 := classifyBash(cmd2, ev)
	if d2.Bucket == BucketAsk {
		t.Errorf("$(git rev-parse --show-toplevel) anchor over a directory must not ASK; got ASK (%s)", d2.Reason)
	}
}

// TestGitCommonDirAnchorResolvesThenDeniesGitDir pins the design's
// explicit carve-out: $(git rev-parse --git-common-dir) resolves (it is NOT
// left unresolvable), but a path anchored there lands under .git/ and must
// hit the deterministic .git/ deny — never a fail-closed ASK, and never a
// silent allow.
//
// This must run from a linked WORKTREE (not a plain repo): a plain repo's
// .git/ lives directly under its own topLevel, so testContainmentFrom
// classifies it as merely `contained` (a literal .git/config read there
// already ALLOWs today, pre-dating and unrelated to the anchor work — see
// TestPrimaryCloneReadRelaxed for the existing gated case). The .git/
// deny fires via the escapeWorktree branch, which only diverges from
// `contained` when commonDir sits outside THIS worktree's topLevel — i.e.
// a linked worktree pointing at a primary clone's shared .git/.
func TestGitCommonDirAnchorResolvesThenDeniesGitDir(t *testing.T) {
	_, wt := setupWorktree(t)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}

	cmd := `g=$(git rev-parse --git-common-dir); cat "$g/config"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "$(git rev-parse --git-common-dir)/config must resolve then hit the .git/ deny")
	if d.Bucket == BucketAsk {
		t.Errorf("git-common-dir anchor must not fail closed to ASK; got ASK (%s)", d.Reason)
	}
}

// TestPwdAnchorResolvesToTrackedCwd pins the $(pwd)/`pwd` anchor: it must
// resolve against the CD-TRACKED running cwd (the tracked runningCWD), not ev.CWD
// — a preceding `cd` changes what a real `pwd` would print.
func TestPwdAnchorResolvesToTrackedCwd(t *testing.T) {
	_, wt := setupWorktree(t)

	sub := filepath.Join(wt, "sub")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "x"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}

	// $(pwd) form.
	cmd := `cd ` + sub + `; p=$(pwd); cat "$p/x"`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("$(pwd) anchor after cd must not ASK; got ASK (%s)", d.Reason)
	}

	// Backtick `pwd` form resolves identically.
	cmdBacktick := "cd " + sub + "; p=`pwd`; cat \"$p/x\""
	dBacktick := classifyBash(cmdBacktick, ev)
	if dBacktick.Bucket == BucketAsk {
		t.Errorf("`pwd` (backtick) anchor after cd must not ASK; got ASK (%s)", dBacktick.Reason)
	}

	// Directly assert the RESOLVED value is the tracked post-cd cwd (sub),
	// not the event cwd (wt).
	file := mustParse(t, cmd)
	cmds, err := extractSimpleCommands(file, wt, defaultVarResolver(), nil)
	if err != nil {
		t.Fatal(err)
	}
	// cmds: cd, cat
	if len(cmds) != 2 {
		t.Fatalf("expected 2 simple commands (cd, cat), got %d: %+v", len(cmds), cmds)
	}
	catCmd := cmds[1]
	wantArg := filepath.Join(sub, "x")
	if len(catCmd.args) < 2 || catCmd.args[1] != wantArg {
		t.Errorf("$(pwd) must resolve to the tracked cwd %q, got args=%v", wantArg, catCmd.args)
	}
}

// TestHomeAnchorStillYieldsToClaudeConfigCarveOut is regression coverage
// for the $HOME/$PWD env-var read-side resolution: $HOME must keep
// resolving (this test confirms the existing behavior rather than pinning
// anything new). A $HOME-anchored path under
// ~/.claude/ hits the claudeConfig carve-out — not an escape, so the calling
// track's own terminal for a contained target governs — distinct from the DENY
// a $HOME/.ssh/id_rsa path gets.
//
// The name says "yields", not "defers": the body asserts only that the verdict
// is neither ASK nor DENY, and deliberately does not pin WHICH of the
// remaining buckets the carve-out lands in. An earlier name said "Defers",
// which read as a BucketDefer assertion the body never makes.
func TestHomeAnchorStillYieldsToClaudeConfigCarveOut(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	d := classifyBash(`cat "$HOME/.claude/CLAUDE.md"`, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("$HOME must still resolve (not fail closed); got ASK (%s)", d.Reason)
	}
	if d.Bucket == BucketDeny {
		t.Errorf("$HOME/.claude/* must yield to the claudeConfig carve-out, not DENY; got DENY (%s)", d.Reason)
	}
}

// TestCompoundCmdSubstNotAnAnchor pins the "matching must be strict" rule:
// a compound substitution (more than one statement inside `$(...)`) is NOT
// recognized as an anchor even though its first statement is
// `git rev-parse --show-toplevel` — it must stay unresolved (fail closed).
func TestCompoundCmdSubstNotAnAnchor(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `x=$(git rev-parse --show-toplevel; echo hi); cat "$x/y"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "compound command substitution must not be recognized as an anchor")
}

// TestNonAllowlistedCmdSubstStillEscalates pins the negative case: an
// arbitrary, non-allowlisted command substitution (`$(git log)`) must stay
// unresolved (fail closed), exactly as before this issue.
func TestNonAllowlistedCmdSubstStillEscalates(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `x=$(git log); cat "$x"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "non-allowlisted command substitution must still escalate")
}

// TestAnchorInSubshellDoesNotLeak pins scopeDepth discipline for anchor
// assignments: an anchor assigned inside a `( … )` subshell must not persist
// into the program-global knownVars, exactly like any other recorded
// assignment (a follow-up to the assignment-tracking work).
func TestAnchorInSubshellDoesNotLeak(t *testing.T) {
	_, wt := setupWorktree(t)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}

	cmd := `( root=$(git rev-parse --show-toplevel) ) ; cat "$root/x"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "anchor assigned inside a subshell must not leak to the enclosing scope")
}
