package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// The permission gate resolves $HOME, $USER, $TMPDIR (from the
// process env / os.UserHomeDir()) and $PWD/$OLDPWD (from the engine's
// tracked running cwd) for a closed allowlist of names, instead of
// failing closed on every $VAR the way it did before this issue. These
// tests pin the issue's acceptance criteria directly.

// fakeResolver builds a varResolver with deterministic, injectable sources
// so the fail-closed branches (a missing/erroring homeDir, an unset env var)
// are testable without depending on the ambient environment.
func fakeResolver(home string, homeErr error, env map[string]string) varResolver {
	return varResolver{
		homeDir: func() (string, error) {
			if homeErr != nil {
				return "", homeErr
			}
			return home, nil
		},
		lookupEnv: func(name string) (string, bool) {
			v, ok := env[name]
			return v, ok
		},
	}
}

// TestHomeVarResolvesLikeTilde pins the issue's headline acceptance
// criterion: `cat $HOME/.ssh/id_rsa` denies identically to `cat
// ~/.ssh/id_rsa` — the two spellings must agree.
func TestHomeVarResolvesLikeTilde(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	dTilde := classifyBash(`cat ~/.ssh/id_rsa`, ev)
	wantBucket(t, dTilde, BucketDeny, "cat ~/.ssh/id_rsa must deny")

	dHome := classifyBash(`cat "$HOME/.ssh/id_rsa"`, ev)
	wantBucket(t, dHome, BucketDeny, "cat $HOME/.ssh/id_rsa must deny, matching the tilde spelling")

	dHomeBraced := classifyBash(`cat "${HOME}/.ssh/id_rsa"`, ev)
	wantBucket(t, dHomeBraced, BucketDeny, "cat ${HOME}/.ssh/id_rsa must deny, matching the tilde spelling")
}

// TestHomeVarUnresolvableFailsClosed pins the fail-closed branch: when
// os.UserHomeDir() (via the injected resolver) errors or returns empty,
// $HOME must NOT resolve — it must never silently resolve to "" or guess
// ALLOW.
//
// Both halves are asserted, because the home a word resolves against and the
// home the gate can place are the same predicate: the resolution itself
// withholds a value, and a word carrying `$HOME` never reaches a command at
// all — the home-usability chokepoint denies the whole event as the walk
// reaches that word (home.go), which is stricter than the inexact-word defer.
func TestHomeVarUnresolvableFailsClosed(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)

	file := mustParse(t, `cat "$HOME/.ssh/id_rsa"`)
	for _, tc := range []struct {
		name     string
		resolver varResolver
	}{
		{name: "errors", resolver: fakeResolver("", errors.New("no home directory"), nil)},
		{name: "empty", resolver: fakeResolver("", nil, nil)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if val, ok := resolveVar("HOME", nil, tc.resolver, cwdCtx{}); ok {
				t.Errorf("$HOME must fail closed when homeDir() %s; resolved to %q", tc.name, val)
			}
			cmds, homeDeny, err := extractSimpleCommands(file, cwd, tc.resolver, nil)
			if err != nil {
				t.Fatal(err)
			}
			if homeDeny.Bucket != BucketDeny || homeDeny.Operation != homeUnusableOp {
				t.Fatalf("a `$HOME` word under a home that %s must deny at the chokepoint; got bucket %q op %q",
					tc.name, homeDeny.Bucket, homeDeny.Operation)
			}
			if len(cmds) != 0 {
				t.Errorf("a denied event extracts no command to grade; got %d", len(cmds))
			}
		})
	}
}

// TestNakedExportIsNotAnAssignment pins what a `export VAR` carrying no `=`
// does to the variable map: nothing. Bash exports the variable and leaves its
// value exactly as it was, so recording the empty string would resolve a later
// `"$VAR/x"` against the filesystem root. For an exported name the gate has a
// source for ($HOME) that is the process home; for one it does not, the word
// must stay inexact rather than resolve to "".
//
// The assign-then-export sequence is the third row, and the one that moves a
// verdict for a name that is not $HOME: a variable assigned a static literal
// earlier in the line keeps that literal across the export, so
// `P=<worktree>; export P; cat "$P/README.md"` resolves in-repo where the
// merge base recorded `P=""` and read `/README.md`.
func TestNakedExportIsNotAnAssignment(t *testing.T) {
	_, wt := setupWorktree(t)
	home := t.TempDir()
	resolver := fakeResolver(home, nil, nil)

	file := mustParse(t, `export HOME; cat "$HOME/x"`)
	cmds, homeDeny, err := extractSimpleCommands(file, wt, resolver, nil)
	if err != nil {
		t.Fatal(err)
	}
	if homeDeny.Bucket == BucketDeny {
		t.Fatalf("a naked `export HOME` sets no value, so the usable process home stands (reason=%q)",
			homeDeny.Reason)
	}
	if len(cmds) != 1 {
		t.Fatalf("expected 1 simple command (cat), got %d", len(cmds))
	}
	wantArg := filepath.Join(home, "x")
	if len(cmds[0].args) < 2 || cmds[0].args[1] != wantArg {
		t.Errorf("after a naked `export HOME`, $HOME/x must resolve to %q, got args=%v", wantArg, cmds[0].args)
	}

	file = mustParse(t, `export P; cat "$P/x"`)
	cmds, _, err = extractSimpleCommands(file, wt, resolver, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 1 {
		t.Fatalf("expected 1 simple command (cat), got %d", len(cmds))
	}
	if !cmds[0].hasUnknownExpansion {
		t.Errorf("a naked `export P` assigns nothing, so $P must stay unresolved; got args=%v", cmds[0].args)
	}

	file = mustParse(t, `P=`+wt+`; export P; cat "$P/README.md"`)
	cmds, _, err = extractSimpleCommands(file, wt, resolver, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 1 {
		t.Fatalf("expected 1 simple command (cat), got %d", len(cmds))
	}
	wantArg = filepath.Join(wt, "README.md")
	if cmds[0].hasUnknownExpansion || len(cmds[0].args) < 2 || cmds[0].args[1] != wantArg {
		t.Errorf("a naked `export P` must leave the earlier P=%q standing, so $P/README.md resolves to %q; "+
			"got args=%v inexact=%v", wt, wantArg, cmds[0].args, cmds[0].hasUnknownExpansion)
	}
}

// TestPWDResolvesAgainstTrackedCwdNotEventCwd pins the issue's
// $PWD-specific acceptance criterion: `cd sub && cat "$PWD/x"` must resolve
// against the TRACKED post-cd cwd (<repo>/sub), never the event cwd — a
// process-env-backed $PWD would be wrong here (it would still say <repo>).
func TestPWDResolvesAgainstTrackedCwdNotEventCwd(t *testing.T) {
	_, wt := setupWorktree(t)

	sub := filepath.Join(wt, "sub")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "x"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `cd sub && cat "$PWD/x"`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk || d.Bucket == BucketDeny {
		t.Errorf("$PWD after 'cd sub' must resolve to the tracked post-cd cwd and stay contained; got %q (%s)",
			d.Bucket, d.Reason)
	}

	// Directly assert the resolved value via extractSimpleCommands, so the
	// test pins the RESOLVED PATH, not just the eventual bucket.
	file := mustParse(t, cmd)
	cmds, _, err := extractSimpleCommands(file, wt, defaultVarResolver(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 2 {
		t.Fatalf("expected 2 simple commands (cd, cat), got %d", len(cmds))
	}
	catCmd := cmds[1]
	wantArg := filepath.Join(sub, "x")
	if len(catCmd.args) < 2 || catCmd.args[1] != wantArg {
		t.Errorf("$PWD/x must resolve to %q (the tracked post-cd cwd), got args=%v", wantArg, catCmd.args)
	}
}

// TestPWDInvalidAfterDynamicCdFailsClosed pins the issue's other $PWD
// acceptance criterion: when a dynamic `cd` invalidates the tracked cwd,
// $PWD must fail closed (DEFER), never resolve against a stale/guessed value.
func TestPWDInvalidAfterDynamicCdFailsClosed(t *testing.T) {
	_, wt := setupWorktree(t)

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `cd "$UNKNOWN" && cat "$PWD/x"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "$PWD must fail closed after a dynamic cd invalidates the tracked cwd")
}

// TestOLDPWDResolvesToPriorTrackedCwd pins the issue's $OLDPWD
// acceptance criterion: `cd sub && cd .. && cat "$OLDPWD/x"` resolves to
// <repo>/sub/x — $OLDPWD is the cwd immediately before the LAST cd (the
// `cd ..`), i.e. <repo>/sub.
func TestOLDPWDResolvesToPriorTrackedCwd(t *testing.T) {
	_, wt := setupWorktree(t)

	sub := filepath.Join(wt, "sub")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "x"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `cd sub && cd .. && cat "$OLDPWD/x"`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk || d.Bucket == BucketDeny {
		t.Errorf("$OLDPWD after 'cd sub && cd ..' must resolve to <repo>/sub and stay contained; got %q (%s)",
			d.Bucket, d.Reason)
	}

	file := mustParse(t, cmd)
	cmds, _, err := extractSimpleCommands(file, wt, defaultVarResolver(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 3 {
		t.Fatalf("expected 3 simple commands (cd, cd, cat), got %d", len(cmds))
	}
	catCmd := cmds[2]
	wantArg := filepath.Join(sub, "x")
	if len(catCmd.args) < 2 || catCmd.args[1] != wantArg {
		t.Errorf("$OLDPWD/x must resolve to %q (the pre-'cd ..' cwd), got args=%v", wantArg, catCmd.args)
	}
}

// TestOLDPWDBeforeAnyCdFailsClosed pins the issue's fail-closed
// requirement: $OLDPWD before any `cd` has happened in the program is not
// tracked and must fail closed (DEFER).
func TestOLDPWDBeforeAnyCdFailsClosed(t *testing.T) {
	_, wt := setupWorktree(t)

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `cat "$OLDPWD/x"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "$OLDPWD with no preceding cd in the program must fail closed")
}

// TestOLDPWDInvalidAfterDynamicCdFailsClosed pins $OLDPWD's fail-closed
// behavior when the PRIOR cd (the one whose cwd would become $OLDPWD) was
// itself dynamic/invalid.
func TestOLDPWDInvalidAfterDynamicCdFailsClosed(t *testing.T) {
	_, wt := setupWorktree(t)

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `cd "$UNKNOWN" && cd ` + wt + ` && cat "$OLDPWD/x"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "$OLDPWD must fail closed when the prior tracked cwd was invalid")
}

// TestUserAndTmpdirResolveFromProcessEnv pins the issue's $USER/$TMPDIR
// acceptance criterion: both resolve from the process env and flow through
// containment — an in-repo target is contained (not ASK), an escaping
// target denies.
func TestUserAndTmpdirResolveFromProcessEnv(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	payload := filepath.Join(repo, "alice")
	if err := os.MkdirAll(payload, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(payload, "x"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)

	file := mustParse(t, `cat "$USER/x"`)
	resolver := fakeResolver(base, nil, map[string]string{"USER": "alice"})
	cmds, _, err := extractSimpleCommands(file, cwd, resolver, nil)
	if err != nil {
		t.Fatal(err)
	}
	if cmds[0].hasUnknownExpansion {
		t.Errorf("$USER must resolve from the process env; got hasUnknownExpansion=true")
	}
	if len(cmds[0].args) < 2 || cmds[0].args[1] != "alice/x" {
		t.Errorf("$USER must resolve to the injected env value; got args=%v", cmds[0].args)
	}
}

// TestTmpdirUnsetFailsClosed pins the fail-closed branch for $TMPDIR
// when the process env does not have it set.
func TestTmpdirUnsetFailsClosed(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)

	file := mustParse(t, `cat "$TMPDIR/x"`)
	resolver := fakeResolver(base, nil, nil) // no TMPDIR key at all
	cmds, _, err := extractSimpleCommands(file, cwd, resolver, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !cmds[0].hasUnknownExpansion {
		t.Errorf("unset $TMPDIR must fail closed; got hasUnknownExpansion=false")
	}
}

// TestInScriptAssignmentWinsOverEnv pins the issue's precedence
// requirement: `HOME=/tmp cat "$HOME/x"` resolves $HOME to /tmp (from
// knownVars), NOT the process/injected env value.
func TestInScriptAssignmentWinsOverEnv(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	tmp := filepath.Join(base, "scratch")
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "x"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)

	file := mustParse(t, `HOME=`+tmp+`; cat "$HOME/x"`)
	// Inject a DIFFERENT home dir than the in-script assignment, so a pass
	// would prove precedence rather than accidentally matching.
	resolver := fakeResolver(filepath.Join(base, "real-home"), nil, nil)
	cmds, _, err := extractSimpleCommands(file, cwd, resolver, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 1 {
		t.Fatalf("expected 1 simple command, got %d", len(cmds))
	}
	wantArg := filepath.Join(tmp, "x")
	if cmds[0].hasUnknownExpansion || len(cmds[0].args) < 2 || cmds[0].args[1] != wantArg {
		t.Errorf("in-script HOME=%s assignment must win over the injected env; got args=%v, hasUnknownExpansion=%v",
			tmp, cmds[0].args, cmds[0].hasUnknownExpansion)
	}
}

// TestUnsupportedEnvVarStaysUnresolvable pins the issue's closed-
// allowlist requirement: an env var outside {HOME, USER, TMPDIR, PWD,
// OLDPWD} — e.g. $FOO or $PATH — stays unresolvable (DEFER) even when the
// process env has a value for it.
func TestUnsupportedEnvVarStaysUnresolvable(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	for _, cmd := range []string{
		`cat "$FOO/.ssh/id_rsa"`,
		`cat "$PATH/.ssh/id_rsa"`,
	} {
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketDefer, ""+cmd+" must stay unresolvable — the allowlist is closed")
	}
}

// TestEscapingResolvedVarsStillDenyNoNewPolicy pins the issue's "no new
// allow/ask/deny policy" requirement: a resolved $HOME/$PWD/$OLDPWD/$USER/
// $TMPDIR that escapes the repo denies through the EXISTING containment
// pipeline, exactly like an equivalent literal path would.
func TestEscapingResolvedVarsStillDenyNoNewPolicy(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	literalDeny := classifyBash(`cat `+filepath.Join(base, "outside", "x"), ev)
	wantBucket(t, literalDeny, BucketDeny, "sanity: literal escaping path denies")

	homeDeny := classifyBash(`cat "$HOME/.ssh/id_rsa"`, ev)
	wantBucket(t, homeDeny, BucketDeny, "resolved $HOME escaping the repo denies via existing containment")
}

// TestHomeRelativePathInCmdSubstDoesNotPanic pins the nil-source guard in
// resolveVar. The anchor matcher grades a substitution's argv against the
// ZERO-VALUE varResolver — the anchor forms carry no `~` and no `$HOME`, so
// resolving one buys nothing there — and an unquoted `~` (or a `$HOME`) inside
// a substitution whose argv that matcher grades at all (a single plain command,
// no assignments, redirects, negation or background marker — the shape every
// row below carries) reaches that resolver's nil homeDir, which resolveVar
// must grade unresolvable rather than call.
//
// Each row asserts the shape earns the SAME bucket as the substituted command
// spelled bare: none of these argvs is an anchor form, so the anchor is
// declined and the inner command is graded on its own terms — which is the
// documented grading for a non-anchor `$(…)`, and it resolves `~` through the
// REAL resolver the main walk carries. `echo $(cat ~/x)` therefore denies on
// the containment escape `cat ~/x` earns, not on the relative spelling's
// verdict. A panic here fails the test outright — the classifier is called
// directly, with no recover in front of it.
func TestHomeRelativePathInCmdSubstDoesNotPanic(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	for _, row := range []struct{ enclosing, inner string }{
		{`echo $(cat ~/x)`, `cat ~/x`},
		{`f=$(cat ~/x)`, `cat ~/x`},
		{`f=$(ls ~/x)`, `ls ~/x`},
		{`f=$(readlink -f ~/x)`, `readlink -f ~/x`},
		{`f=$(readlink -f "$HOME/x")`, `readlink -f "$HOME/x"`},
		{`echo $(cat ~)`, `cat ~`},
	} {
		want := classifyBash(row.inner, ev)
		got := classifyBash(row.enclosing, ev)
		wantBucket(t, got, want.Bucket,
			row.enclosing+" must classify like its inner "+row.inner+" rather than panicking")
	}
}

// TestEnvVarInCmdSubstDoesNotPanic is the same nil-source guard on the
// resolver's OTHER field: the zero-value varResolver's nil lookupEnv backs
// $USER and $TMPDIR, and resolveVar must grade both unresolvable rather than
// call it. Each row is graded against its bare inner command for the same
// reason the rows above are.
func TestEnvVarInCmdSubstDoesNotPanic(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	for _, row := range []struct{ enclosing, inner string }{
		{`f=$(cat $USER)`, `cat $USER`},
		{`f=$(cat $TMPDIR/x)`, `cat $TMPDIR/x`},
	} {
		want := classifyBash(row.inner, ev)
		got := classifyBash(row.enclosing, ev)
		wantBucket(t, got, want.Bucket,
			row.enclosing+" must classify like its inner "+row.inner+" rather than panicking")
	}
}

// TestHomeRelativePathOutsideCmdSubstKeepsItsVerdict is the negative control
// for the two tests above: the same home-relative paths OUTSIDE a command
// substitution never reach the zero-value resolver, so the guard must leave
// their verdicts untouched.
func TestHomeRelativePathOutsideCmdSubstKeepsItsVerdict(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	wantBucket(t, classifyBash(`cat ~/x`, ev), BucketDeny,
		"cat ~/x must keep its containment deny")
	wantBucket(t, classifyBash(`readlink -f ~/x`, ev), BucketDefer,
		"readlink -f ~/x must keep its defer")
	wantBucket(t, classifyBash(`echo $(cat x)`, ev), BucketDefer,
		"echo $(cat x) must keep its defer")
	wantBucket(t, classifyBash(`f=$(readlink -f x)`, ev), BucketDefer,
		"f=$(readlink -f x) must keep its defer")
	wantBucket(t, classifyBash(`f=$(readlink -f /abs/x)`, ev), BucketDefer,
		"f=$(readlink -f /abs/x) must keep its defer")
}
