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

// The permission-gate must track an in-command `cd` when resolving a
// Bash command's relative path operands, instead of always resolving against
// the event's cwd (ev.CWD). These tests cover the original repro and the full
// cd-tracking test plan.

// TestCdTrackingContainsRelativeOperandAfterCd is the original regression: a
// `cd <subdir> && cmd ../x` must resolve `../x` against <subdir>, landing back
// inside the worktree, and must NOT be treated as escaping into the primary
// clone just because ev.CWD is higher up the tree.
func TestCdTrackingContainsRelativeOperandAfterCd(t *testing.T) {
	primary, wt := setupWorktree(t)

	// Build <worktree>/plugins/claude-vm/payload and a sibling
	// <worktree>/plugins/claude-vm/.claude-plugin/plugin.json, matching the
	// original repro shape.
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
		t.Errorf("repro: 'cd payload && cat ../.claude-plugin/plugin.json' must not ASK/DENY; got %q (%s)",
			d.Bucket, d.Reason)
	}

	_ = primary // referenced only to build the worktree pair
}

// TestCdTrackingMultipleDotDotLevels covers a `cd a/b; cat ../../c`
// resolving back to the worktree root's c.
func TestCdTrackingMultipleDotDotLevels(t *testing.T) {
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

// TestCdTrackingDynamicCdFailsClosed covers `cd "$UNKNOWN" && cat ../x`:
// a dynamic cd target invalidates the running cwd, so the later relative
// operand must fail closed (DEFER), not silently resolve against ev.CWD.
func TestCdTrackingDynamicCdFailsClosed(t *testing.T) {
	_, wt := setupWorktree(t)

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `cd "$UNKNOWN" && cat ../x`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "dynamic cd must invalidate running cwd and withhold the allow")
}

// TestCdTrackingAbsoluteOperandUnaffected covers `cd <worktree>/a &&
// cat /abs/outside/x`: an absolute operand is unaffected by cd-tracking and
// the cross-repo deny still fires.
func TestCdTrackingAbsoluteOperandUnaffected(t *testing.T) {
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
	wantBucket(t, d, BucketDeny, "absolute operand after cd is still cross-repo denied")
}

// TestCdTrackingKnownVarCdTarget covers `P=<known>; cd "$P"/sub && cat
// ./x` — the cd target resolves via a knownVars literal (assignment tracking
// feeds cd tracking).
func TestCdTrackingKnownVarCdTarget(t *testing.T) {
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
		t.Errorf("cd to a knownVars-resolved target must resolve; got %q (%s)", d.Bucket, d.Reason)
	}
}

// TestCdTrackingSubshellCdDoesNotPersist covers `( cd <worktree>/a ) &&
// cat ../x`: the subshell's cd must not persist; '../x' must resolve against
// the PRE-subshell cwd (scopeDepth discipline, mirroring assignment tracking).
// Asserts directly on the per-command cwd stamped by extractSimpleCommands,
// rather than the aggregate classifyBash bucket, so the assertion pins the
// scope discipline precisely instead of depending on how `cat`'s eventual
// containment result happens to bucket.
func TestCdTrackingSubshellCdDoesNotPersist(t *testing.T) {
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
		t.Errorf("subshell cd leaked into the enclosing scope — cat's cwd = %q, want %q (pre-subshell cwd)",
			catCmd.cwd, wt)
	}
}

// TestCdTrackingDeepDotDotStillCrossRepoDeny covers `cd <worktree>/a &&
// cat ../../../../../../etc/passwd`: the '..' chain escapes even from the
// tracked cwd, and containment still catches it as a cross-repo/outside read.
func TestCdTrackingDeepDotDotStillCrossRepoDeny(t *testing.T) {
	_, wt := setupWorktree(t)

	a := filepath.Join(wt, "a")
	if err := os.MkdirAll(a, 0o755); err != nil {
		t.Fatal(err)
	}

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := "cd " + a + " && cat ../../../../../../etc/passwd"
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAllow {
		t.Errorf("a '..' chain escaping even the tracked cwd must not ALLOW; got %q (%s)", d.Bucket, d.Reason)
	}
}

// TestCdTrackingPreservedGuarantees pins that the cross-worktree
// write deny, the cross-repo deny, and the .git/-tree deny are all
// unchanged by cd-tracking.
func TestCdTrackingPreservedGuarantees(t *testing.T) {
	primary, wt := setupWorktree(t)

	// Cross-worktree: cd inside the worktree, then write into the primary clone by
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
			t.Errorf("cross-worktree write via tracked cwd must still deny/ask; got %q (%s)", d.Bucket, d.Reason)
		}
	})

	// Cross-repo: cd inside the worktree, then read a sibling repo by relative
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
		wantBucket(t, d, BucketDeny, "cross-repo read via tracked cwd must still deny")
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

// TestCdTrackingBareTildeTracksCleanedHome pins what a quoted bare tilde,
// `cd '~'`, tracks when $HOME carries a trailing slash: home CLEANED, not home
// verbatim. The tracked cwd is handed to `$PWD` unmodified, so the trailing
// slash would otherwise reach concatenation — `"$PWD"x` would resolve as
// <home>/x rather than <home>x. Bash agrees with the Cleaned spelling: its own
// $PWD carries no trailing slash after a successful cd (measured in bash:
// `cd /tmp/` then `echo "$PWD"` prints `/tmp`).
//
// The QUOTED spelling is what this exercises, and it is the only one that
// reaches applyCd's tilde branch: literalWord expands an unquoted `cd ~`
// upstream, so that spelling arrives absolute and takes the branch above it.
// Bash does not expand the quoted one at all — `cd '~'` looks for a directory
// literally named `~`, and unless one exists the cd fails and leaves $PWD put
// (measured in bash: `bash: line 0: cd: ~: No such file or directory`; zsh
// spells the same failure `zsh:cd:1: no such file or directory: ~`). Treating
// it as $HOME is the gate's over-approximation, recorded in applyCd's own
// comment and in the README's cd-tracking section; the sibling below pins the
// no-argument `cd`, whose $HOME target bash really does take.
func TestCdTrackingBareTildeTracksCleanedHome(t *testing.T) {
	_, wt := setupWorktree(t)

	home := t.TempDir() + string(filepath.Separator)
	want := filepath.Clean(home)

	cmd := "cd '~' && cat \"$PWD\"x"
	cmds, err := extractSimpleCommands(mustParse(t, cmd), wt, fakeResolver(home, nil, nil), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 2 {
		t.Fatalf("expected 2 simple commands, got %d: %+v", len(cmds), cmds)
	}
	catCmd := cmds[1]
	if catCmd.cwd != want {
		t.Errorf("bare-tilde cd tracked cwd = %q, want %q (home Cleaned, not %q verbatim)", catCmd.cwd, want, home)
	}
	if len(catCmd.args) != 2 || catCmd.args[1] != want+"x" {
		t.Errorf("concatenated $PWD operand = %v, want [cat %q]", catCmd.args, want+"x")
	}
}

// TestCdTrackingBareCdTracksCleanedHome is the sibling of the test above on the
// branch bash agrees with unconditionally: a no-argument `cd` really does go to
// $HOME, and bash's $PWD carries no trailing slash afterwards. So the tracked
// cwd must be home Cleaned here too, or `"$PWD"x` after a trailing-slash $HOME
// resolves as <home>/x rather than <home>x.
func TestCdTrackingBareCdTracksCleanedHome(t *testing.T) {
	_, wt := setupWorktree(t)

	home := t.TempDir() + string(filepath.Separator)
	want := filepath.Clean(home)

	cmd := "cd && cat \"$PWD\"x"
	cmds, err := extractSimpleCommands(mustParse(t, cmd), wt, fakeResolver(home, nil, nil), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 2 {
		t.Fatalf("expected 2 simple commands, got %d: %+v", len(cmds), cmds)
	}
	catCmd := cmds[1]
	if catCmd.cwd != want {
		t.Errorf("bare-cd tracked cwd = %q, want %q (home Cleaned, not %q verbatim)", catCmd.cwd, want, home)
	}
	if len(catCmd.args) != 2 || catCmd.args[1] != want+"x" {
		t.Errorf("concatenated $PWD operand = %v, want [cat %q]", catCmd.args, want+"x")
	}
}

// TestCdTrackingAbsoluteCdTracksCleanedPath pins the third arm of the same
// class: an absolute `cd` operand is tracked CLEANED, not verbatim. `cd /tmp/`
// otherwise leaves the trailing slash in the tracked cwd, which reaches `$PWD`
// concatenation unmodified, so `"$PWD"x` resolves as /tmp/x where bash yields
// /tmpx (measured in bash: `cd /tmp/` then `echo "$PWD"x` prints `/tmpx`).
//
// The second row is the spelling that makes this arm the tilde branch's
// sibling: an UNQUOTED `cd ~` never reaches applyCd's tilde case, because
// literalWord tilde-expands it upstream and the result arrives absolute here.
// So a $HOME carrying a trailing slash rides this arm, not the one the two
// tests above exercise.
func TestCdTrackingAbsoluteCdTracksCleanedPath(t *testing.T) {
	_, wt := setupWorktree(t)

	home := t.TempDir() + string(filepath.Separator)

	for _, tc := range []struct {
		name string
		cmd  string
		want string
	}{
		{"trailing slash on a literal absolute path", "cd /tmp/ && cat \"$PWD\"x", "/tmp"},
		{"unquoted tilde under a trailing-slash $HOME", "cd ~ && cat \"$PWD\"x", filepath.Clean(home)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmds, err := extractSimpleCommands(mustParse(t, tc.cmd), wt, fakeResolver(home, nil, nil), nil)
			if err != nil {
				t.Fatal(err)
			}
			if len(cmds) != 2 {
				t.Fatalf("expected 2 simple commands, got %d: %+v", len(cmds), cmds)
			}
			catCmd := cmds[1]
			if catCmd.cwd != tc.want {
				t.Errorf("tracked cwd = %q, want %q (Cleaned, not verbatim)", catCmd.cwd, tc.want)
			}
			if len(catCmd.args) != 2 || catCmd.args[1] != tc.want+"x" {
				t.Errorf("concatenated $PWD operand = %v, want [cat %q]", catCmd.args, tc.want+"x")
			}
		})
	}
}

// TestCdTrackingSeedCWDIsCleaned pins the fourth arm of the same class, and
// the only one that reaches `$PWD` with no `cd` on the line at all: the
// event's own cwd seeds the tracked cwd, so a seed carrying a trailing slash
// reaches concatenation directly. `cat "$PWD"x` under a seed of `<dir>/` must
// resolve as <dir>x, matching what bash yields — its $PWD carries no trailing
// slash (measured in bash: `cd /tmp/` then `echo "$PWD"x` prints `/tmpx`).
//
// The empty seed is the row that keeps the Clean from being unconditional:
// filepath.Clean("") is ".", while an empty ev.CWD means the cwd is UNKNOWN
// rather than the process's relative ".". Turning it into "." would hand
// resolveVar a resolvable `$PWD` where its `cc.cwd == ""` guard instead has to
// fail closed, so the second row pins that an empty seed stays empty.
func TestCdTrackingSeedCWDIsCleaned(t *testing.T) {
	dir := t.TempDir()

	t.Run("trailing slash on the seed cwd", func(t *testing.T) {
		seed := dir + string(filepath.Separator)
		want := filepath.Clean(seed)

		cmds, err := extractSimpleCommands(mustParse(t, "cat \"$PWD\"x"), seed, defaultVarResolver(), nil)
		if err != nil {
			t.Fatal(err)
		}
		if len(cmds) != 1 {
			t.Fatalf("expected 1 simple command, got %d: %+v", len(cmds), cmds)
		}
		if cmds[0].cwd != want {
			t.Errorf("seeded cwd = %q, want %q (Cleaned, not %q verbatim)", cmds[0].cwd, want, seed)
		}
		if len(cmds[0].args) != 2 || cmds[0].args[1] != want+"x" {
			t.Errorf("concatenated $PWD operand = %v, want [cat %q]", cmds[0].args, want+"x")
		}
	})

	t.Run("empty seed cwd stays empty", func(t *testing.T) {
		cmds, err := extractSimpleCommands(mustParse(t, "cat \"$PWD\"x"), "", defaultVarResolver(), nil)
		if err != nil {
			t.Fatal(err)
		}
		if len(cmds) != 1 {
			t.Fatalf("expected 1 simple command, got %d: %+v", len(cmds), cmds)
		}
		if cmds[0].cwd != "" {
			t.Errorf("seeded cwd = %q, want %q (unknown, not Clean's %q)", cmds[0].cwd, "", filepath.Clean(""))
		}
	})
}

// TestCdTrackingNonAbsoluteHomeInvalidates pins the invariant the two $HOME
// arms of applyCd carry: a valid tracked cwd is always ABSOLUTE. Every other
// writer already guarantees it — the seed is the event cwd, which
// resolveRepoContext fails closed on unless it is absolute, and a relative `cd`
// target joins onto an already-absolute cwd — so a relative $HOME is the only
// spelling that could track a non-absolute cwd while reporting it valid. Such a
// cwd reaches testContainmentFrom as the base, where canonicalizeFromResolver
// falls through to filepath.Abs and grades the operand against the hook
// PROCESS's cwd, which can read a genuine escape as `contained`.
//
// The fixture home is deliberately RELATIVE, which is what no other
// cd-tracking test can supply: they all use t.TempDir(), which is absolute, so
// nothing else in the suite exercises this path. All three spellings the README
// folds into this rule are covered — bare `cd`, the quoted tilde `cd '~'`, and
// the UNQUOTED `cd ~` — because each takes $HOME as the target and each must
// invalidate, exactly as they already do for an unresolvable or empty home.
//
// The unquoted spelling reaches the rule by a different route than the other
// two, which is why it is a row here rather than an obvious duplicate.
// literalWord tilde-expands `cd ~` upstream through expand.Literal, whose tilde
// handling reads $HOME from the same resolveVar the operand path uses, so with a
// resolvable home the word arrives at applyCd already ABSOLUTE and never reaches
// the leading-tilde arm at all. What routes it there instead is resolveVar's
// absolute-home guard: a relative home fails to resolve, the `~` survives
// expansion unexpanded, and the leading-tilde arm invalidates on it. Without
// that guard the word expanded to `relative/home`, took the relative-target arm,
// and tracked `<cwd>/relative/home` as a VALID cwd — the one spelling that made
// the README's rule false.
func TestCdTrackingNonAbsoluteHomeInvalidates(t *testing.T) {
	_, wt := setupWorktree(t)

	for _, tc := range []struct {
		name string
		cmd  string
	}{
		{"bare cd", "cd && cat ../x"},
		{"quoted tilde", "cd '~' && cat ../x"},
		{"unquoted tilde", "cd ~ && cat ../x"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmds, err := extractSimpleCommands(mustParse(t, tc.cmd), wt, fakeResolver("relative/home", nil, nil), nil)
			if err != nil {
				t.Fatal(err)
			}
			if len(cmds) != 2 {
				t.Fatalf("expected 2 simple commands, got %d: %+v", len(cmds), cmds)
			}
			catCmd := cmds[1]
			if !catCmd.cwdInvalid {
				t.Errorf("tracked cwd after %q under a relative $HOME: cwdInvalid = false, cwd = %q; want invalid "+
					"(a non-absolute cwd reaches testContainmentFrom's filepath.Abs fallback)", tc.cmd, catCmd.cwd)
			}
			if catCmd.cwd != "" && !filepath.IsAbs(catCmd.cwd) {
				t.Errorf("tracked cwd after %q = %q, want absolute or empty", tc.cmd, catCmd.cwd)
			}
		})
	}
}
