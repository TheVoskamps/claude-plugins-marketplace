package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"mvdan.cc/sh/v3/syntax"
)

// mustParse parses a Bash command line to an AST, failing the test on a
// parse error. Used by the tests below that assert directly on
// extractSimpleCommands's per-command cwd stamping, rather than going through
// the full classifyBash decision (which can DEFER for reasons unrelated to
// cwd-tracking and so cannot precisely pin the scopeDepth discipline).
func mustParse(t *testing.T, cmd string) *syntax.File {
	t.Helper()
	parser := syntax.NewParser(syntax.KeepComments(false))
	file, err := parser.Parse(strings.NewReader(cmd), "")
	if err != nil {
		t.Fatalf("parse %q: %v", cmd, err)
	}
	return file
}

// #129: the permission-gate must track an in-command `cd` when resolving a
// Bash command's relative path operands, instead of always resolving against
// the event's cwd (ev.CWD). These tests cover the #125 repro and the full
// #129 test plan.

// TestCdTrackingContainsRelativeOperandAfterCd_129 is the #125 regression: a
// `cd <subdir> && cmd ../x` must resolve `../x` against <subdir>, landing back
// inside the worktree, and must NOT be treated as escaping into the primary
// clone just because ev.CWD is higher up the tree.
func TestCdTrackingContainsRelativeOperandAfterCd_129(t *testing.T) {
	primary, wt := setupWorktree(t)

	// Build <worktree>/plugins/claude-vm/payload and a sibling
	// <worktree>/plugins/claude-vm/.claude-plugin/plugin.json, matching the
	// #125 repro shape.
	claudeVM := filepath.Join(wt, "plugins", "claude-vm")
	payload := filepath.Join(claudeVM, "payload")
	pluginDir := filepath.Join(claudeVM, ".claude-plugin")
	if err := os.MkdirAll(payload, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(pluginDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	// ev.CWD is the worktree root (or higher); the command itself cd's down
	// into payload/ before reading '../.claude-plugin/plugin.json'.
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := "cd " + payload + " && cat ../.claude-plugin/plugin.json"
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk || d.Bucket == BucketDeny {
		t.Errorf("#125/#129 repro: 'cd payload && cat ../.claude-plugin/plugin.json' must not ASK/DENY; got %q (%s)",
			d.Bucket, d.Reason)
	}

	_ = primary // referenced only to build the worktree pair
}

// TestCdTrackingMultipleDotDotLevels_129 covers a `cd a/b; cat ../../c`
// resolving back to the worktree root's c.
func TestCdTrackingMultipleDotDotLevels_129(t *testing.T) {
	_, wt := setupWorktree(t)

	ab := filepath.Join(wt, "a", "b")
	if err := os.MkdirAll(ab, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(wt, "c"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := "cd " + ab + "; cat ../../c"
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk || d.Bucket == BucketDeny {
		t.Errorf("'cd a/b; cat ../../c' resolving to worktree root/c must not ASK/DENY; got %q (%s)", d.Bucket, d.Reason)
	}
}

// TestCdTrackingDynamicCdFailsClosed_129 covers `cd "$UNKNOWN" && cat ../x`:
// a dynamic cd target invalidates the running cwd, so the later relative
// operand must fail closed (ASK), not silently resolve against ev.CWD.
func TestCdTrackingDynamicCdFailsClosed_129(t *testing.T) {
	_, wt := setupWorktree(t)

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `cd "$UNKNOWN" && cat ../x`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketAsk, "#129 dynamic cd must invalidate running cwd and fail closed")
}

// TestCdTrackingAbsoluteOperandUnaffected_129 covers `cd <worktree>/a &&
// cat /abs/outside/x`: an absolute operand is unaffected by cd-tracking and
// the cross-repo deny still fires.
func TestCdTrackingAbsoluteOperandUnaffected_129(t *testing.T) {
	base := t.TempDir()
	_, wt := setupWorktree(t)

	a := filepath.Join(wt, "a")
	if err := os.MkdirAll(a, 0o755); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(base, "outside")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "x"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := "cd " + a + " && cat " + filepath.Join(outside, "x")
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#129 absolute operand after cd is still cross-repo denied (#148)")
}

// TestCdTrackingKnownVarCdTarget_129 covers `P=<known>; cd "$P"/sub && cat
// ./x` — the cd target resolves via a knownVars literal (#60 resolution feeds
// #129's cd tracking).
func TestCdTrackingKnownVarCdTarget_129(t *testing.T) {
	_, wt := setupWorktree(t)

	sub := filepath.Join(wt, "sub")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "x"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `P=` + wt + `; cd "$P"/sub && cat ./x`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk || d.Bucket == BucketDeny {
		t.Errorf("#129: cd to a knownVars-resolved target must resolve; got %q (%s)", d.Bucket, d.Reason)
	}
}

// TestCdTrackingSubshellCdDoesNotPersist_129 covers `( cd <worktree>/a ) &&
// cat ../x`: the subshell's cd must not persist; '../x' must resolve against
// the PRE-subshell cwd (scopeDepth discipline, mirroring the #60 follow-up).
// Asserts directly on the per-command cwd stamped by extractSimpleCommands,
// rather than the aggregate classifyBash bucket, so the assertion pins the
// scope discipline precisely instead of depending on how `cat`'s eventual
// containment result happens to bucket.
func TestCdTrackingSubshellCdDoesNotPersist_129(t *testing.T) {
	_, wt := setupWorktree(t)

	a := filepath.Join(wt, "a")
	if err := os.MkdirAll(a, 0o755); err != nil {
		t.Fatal(err)
	}

	cmd := "( cd " + a + " ) && cat ../x"
	cmds, err := extractSimpleCommands(mustParse(t, cmd), wt, defaultVarResolver(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 2 {
		t.Fatalf("expected 2 simple commands, got %d: %+v", len(cmds), cmds)
	}
	// cmds[0] is the `cd` inside the subshell; cmds[1] is `cat ../x` — its cwd
	// must still be wt (the pre-subshell cwd), NOT wt/a (the subshell's cd
	// target), because the subshell runs in a child shell.
	catCmd := cmds[1]
	if catCmd.cwd != wt {
		t.Errorf("#129: subshell cd leaked into the enclosing scope — cat's cwd = %q, want %q (pre-subshell cwd)",
			catCmd.cwd, wt)
	}
}

// TestCdTrackingDeepDotDotStillCrossRepoDeny_129 covers `cd <worktree>/a &&
// cat ../../../../../../etc/passwd`: the '..' chain escapes even from the
// tracked cwd, and containment still catches it as a cross-repo/outside read.
func TestCdTrackingDeepDotDotStillCrossRepoDeny_129(t *testing.T) {
	_, wt := setupWorktree(t)

	a := filepath.Join(wt, "a")
	if err := os.MkdirAll(a, 0o755); err != nil {
		t.Fatal(err)
	}

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := "cd " + a + " && cat ../../../../../../etc/passwd"
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAllow {
		t.Errorf("#129: a '..' chain escaping even the tracked cwd must not ALLOW; got %q (%s)", d.Bucket, d.Reason)
	}
}

// TestCdTrackingPreservedGuarantees_129 pins that the #127 cross-worktree
// write deny, the #148 cross-repo deny, and the .git/-tree deny are all
// unchanged by cd-tracking.
func TestCdTrackingPreservedGuarantees_129(t *testing.T) {
	primary, wt := setupWorktree(t)

	// #127: cd inside the worktree, then write into the primary clone by
	// relative path — must still deny as a worktree escape.
	t.Run("127-cross-worktree-write-deny", func(t *testing.T) {
		a := filepath.Join(wt, "a")
		if err := os.MkdirAll(a, 0o755); err != nil {
			t.Fatal(err)
		}
		rel, err := filepath.Rel(a, primary)
		if err != nil {
			t.Fatal(err)
		}
		ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
		cmd := "cd " + a + " && touch " + filepath.Join(rel, "escape.txt")
		d := classifyBash(cmd, ev)
		if d.Bucket != BucketDeny && d.Bucket != BucketAsk {
			t.Errorf("#127: cross-worktree write via tracked cwd must still deny/ask; got %q (%s)", d.Bucket, d.Reason)
		}
	})

	// #148: cd inside the worktree, then read a sibling repo by relative
	// path — must still deny as cross-repo.
	t.Run("148-cross-repo-deny", func(t *testing.T) {
		base := filepath.Dir(primary)
		sibling := filepath.Join(base, "sibling-129")
		gitInit(t, sibling)
		nm := filepath.Join(sibling, "node_modules", "pkg")
		if err := os.MkdirAll(nm, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(nm, "index.js"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		a := filepath.Join(wt, "a")
		if err := os.MkdirAll(a, 0o755); err != nil {
			t.Fatal(err)
		}
		rel, err := filepath.Rel(a, filepath.Join(nm, "index.js"))
		if err != nil {
			t.Fatal(err)
		}
		ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
		cmd := "cd " + a + " && cat " + rel
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketDeny, "#148: cross-repo read via tracked cwd must still deny")
	})

	// .git/ tree deny: cd inside the worktree, then write into .git/ by
	// relative path — must still deny.
	t.Run("dotgit-tree-deny", func(t *testing.T) {
		a := filepath.Join(wt, "a")
		if err := os.MkdirAll(a, 0o755); err != nil {
			t.Fatal(err)
		}
		ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
		cmd := "cd " + a + " && touch ../.git/hooks/pre-commit"
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketDeny, ".git/-tree write via tracked cwd must still deny")
	})
}
