package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// #156: the permission gate resolves $HOME, $USER, $TMPDIR (from the
// process env / os.UserHomeDir()) and $PWD/$OLDPWD (from the engine's
// tracked running cwd, #129) for a closed allowlist of names, instead of
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

// TestHomeVarResolvesLikeTilde_156 pins the issue's headline acceptance
// criterion: `cat $HOME/.ssh/id_rsa` denies identically to `cat
// ~/.ssh/id_rsa` — the two spellings must agree.
func TestHomeVarResolvesLikeTilde_156(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	dTilde := classifyBash(`cat ~/.ssh/id_rsa`, ev)
	wantBucket(t, dTilde, BucketDeny, "#156: cat ~/.ssh/id_rsa must deny")

	dHome := classifyBash(`cat "$HOME/.ssh/id_rsa"`, ev)
	wantBucket(t, dHome, BucketDeny, "#156: cat $HOME/.ssh/id_rsa must deny, matching the tilde spelling")

	dHomeBraced := classifyBash(`cat "${HOME}/.ssh/id_rsa"`, ev)
	wantBucket(t, dHomeBraced, BucketDeny, "#156: cat ${HOME}/.ssh/id_rsa must deny, matching the tilde spelling")
}

// TestHomeVarUnresolvableFailsClosed_156 pins the fail-closed branch: when
// os.UserHomeDir() (via the injected resolver) errors or returns empty,
// $HOME must NOT resolve — the word stays inexact and the command
// escalates (ASK), it must never silently resolve to "" or guess ALLOW.
func TestHomeVarUnresolvableFailsClosed_156(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)

	file := mustParse(t, `cat "$HOME/.ssh/id_rsa"`)
	resolver := fakeResolver("", errors.New("no home directory"), nil)
	cmds, err := extractSimpleCommands(file, cwd, resolver)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 1 {
		t.Fatalf("expected 1 simple command, got %d", len(cmds))
	}
	if !cmds[0].hasUnknownExpansion {
		t.Errorf("#156: $HOME must fail closed (hasUnknownExpansion=true) when homeDir() errors; got false")
	}

	// Empty string from homeDir() (no error, but no home) must also fail
	// closed, not resolve to an empty-string $HOME.
	resolverEmpty := fakeResolver("", nil, nil)
	cmds2, err := extractSimpleCommands(file, cwd, resolverEmpty)
	if err != nil {
		t.Fatal(err)
	}
	if !cmds2[0].hasUnknownExpansion {
		t.Errorf("#156: $HOME must fail closed when homeDir() returns empty; got hasUnknownExpansion=false")
	}
}

// TestPWDResolvesAgainstTrackedCwdNotEventCwd_156 pins the issue's
// $PWD-specific acceptance criterion: `cd sub && cat "$PWD/x"` must resolve
// against the TRACKED post-cd cwd (<repo>/sub), never the event cwd — a
// process-env-backed $PWD would be wrong here (it would still say <repo>).
func TestPWDResolvesAgainstTrackedCwdNotEventCwd_156(t *testing.T) {
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
		t.Errorf("#156: $PWD after 'cd sub' must resolve to the tracked post-cd cwd and stay contained; got %q (%s)",
			d.Bucket, d.Reason)
	}

	// Directly assert the resolved value via extractSimpleCommands, so the
	// test pins the RESOLVED PATH, not just the eventual bucket.
	file := mustParse(t, cmd)
	cmds, err := extractSimpleCommands(file, wt, defaultVarResolver())
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 2 {
		t.Fatalf("expected 2 simple commands (cd, cat), got %d", len(cmds))
	}
	catCmd := cmds[1]
	wantArg := filepath.Join(sub, "x")
	if len(catCmd.args) < 2 || catCmd.args[1] != wantArg {
		t.Errorf("#156: $PWD/x must resolve to %q (the tracked post-cd cwd), got args=%v", wantArg, catCmd.args)
	}
}

// TestPWDInvalidAfterDynamicCdFailsClosed_156 pins the issue's other $PWD
// acceptance criterion: when a dynamic `cd` invalidates the tracked cwd,
// $PWD must fail closed (ASK), never resolve against a stale/guessed value.
func TestPWDInvalidAfterDynamicCdFailsClosed_156(t *testing.T) {
	_, wt := setupWorktree(t)

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `cd "$UNKNOWN" && cat "$PWD/x"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketAsk, "#156: $PWD must fail closed after a dynamic cd invalidates the tracked cwd")
}

// TestOLDPWDResolvesToPriorTrackedCwd_156 pins the issue's $OLDPWD
// acceptance criterion: `cd sub && cd .. && cat "$OLDPWD/x"` resolves to
// <repo>/sub/x — $OLDPWD is the cwd immediately before the LAST cd (the
// `cd ..`), i.e. <repo>/sub.
func TestOLDPWDResolvesToPriorTrackedCwd_156(t *testing.T) {
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
		t.Errorf("#156: $OLDPWD after 'cd sub && cd ..' must resolve to <repo>/sub and stay contained; got %q (%s)",
			d.Bucket, d.Reason)
	}

	file := mustParse(t, cmd)
	cmds, err := extractSimpleCommands(file, wt, defaultVarResolver())
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 3 {
		t.Fatalf("expected 3 simple commands (cd, cd, cat), got %d", len(cmds))
	}
	catCmd := cmds[2]
	wantArg := filepath.Join(sub, "x")
	if len(catCmd.args) < 2 || catCmd.args[1] != wantArg {
		t.Errorf("#156: $OLDPWD/x must resolve to %q (the pre-'cd ..' cwd), got args=%v", wantArg, catCmd.args)
	}
}

// TestOLDPWDBeforeAnyCdFailsClosed_156 pins the issue's fail-closed
// requirement: $OLDPWD before any `cd` has happened in the program is not
// tracked and must fail closed (ASK).
func TestOLDPWDBeforeAnyCdFailsClosed_156(t *testing.T) {
	_, wt := setupWorktree(t)

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `cat "$OLDPWD/x"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketAsk, "#156: $OLDPWD with no preceding cd in the program must fail closed")
}

// TestOLDPWDInvalidAfterDynamicCdFailsClosed_156 pins $OLDPWD's fail-closed
// behavior when the PRIOR cd (the one whose cwd would become $OLDPWD) was
// itself dynamic/invalid.
func TestOLDPWDInvalidAfterDynamicCdFailsClosed_156(t *testing.T) {
	_, wt := setupWorktree(t)

	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}
	cmd := `cd "$UNKNOWN" && cd ` + wt + ` && cat "$OLDPWD/x"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketAsk, "#156: $OLDPWD must fail closed when the prior tracked cwd was invalid")
}

// TestUserAndTmpdirResolveFromProcessEnv_156 pins the issue's $USER/$TMPDIR
// acceptance criterion: both resolve from the process env and flow through
// containment — an in-repo target is contained (not ASK), an escaping
// target denies.
func TestUserAndTmpdirResolveFromProcessEnv_156(t *testing.T) {
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
	cmds, err := extractSimpleCommands(file, cwd, resolver)
	if err != nil {
		t.Fatal(err)
	}
	if cmds[0].hasUnknownExpansion {
		t.Errorf("#156: $USER must resolve from the process env; got hasUnknownExpansion=true")
	}
	if len(cmds[0].args) < 2 || cmds[0].args[1] != "alice/x" {
		t.Errorf("#156: $USER must resolve to the injected env value; got args=%v", cmds[0].args)
	}
}

// TestTmpdirUnsetFailsClosed_156 pins the fail-closed branch for $TMPDIR
// when the process env does not have it set.
func TestTmpdirUnsetFailsClosed_156(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)

	file := mustParse(t, `cat "$TMPDIR/x"`)
	resolver := fakeResolver(base, nil, nil) // no TMPDIR key at all
	cmds, err := extractSimpleCommands(file, cwd, resolver)
	if err != nil {
		t.Fatal(err)
	}
	if !cmds[0].hasUnknownExpansion {
		t.Errorf("#156: unset $TMPDIR must fail closed; got hasUnknownExpansion=false")
	}
}

// TestInScriptAssignmentWinsOverEnv_156 pins the issue's precedence
// requirement: `HOME=/tmp cat "$HOME/x"` resolves $HOME to /tmp (from
// knownVars), NOT the process/injected env value.
func TestInScriptAssignmentWinsOverEnv_156(t *testing.T) {
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
	cmds, err := extractSimpleCommands(file, cwd, resolver)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 1 {
		t.Fatalf("expected 1 simple command, got %d", len(cmds))
	}
	wantArg := filepath.Join(tmp, "x")
	if cmds[0].hasUnknownExpansion || len(cmds[0].args) < 2 || cmds[0].args[1] != wantArg {
		t.Errorf("#156: in-script HOME=%s assignment must win over the injected env; got args=%v, hasUnknownExpansion=%v",
			tmp, cmds[0].args, cmds[0].hasUnknownExpansion)
	}
}

// TestUnsupportedEnvVarStaysUnresolvable_156 pins the issue's closed-
// allowlist requirement: an env var outside {HOME, USER, TMPDIR, PWD,
// OLDPWD} — e.g. $FOO or $PATH — stays unresolvable (ASK) even when the
// process env has a value for it.
func TestUnsupportedEnvVarStaysUnresolvable_156(t *testing.T) {
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
		wantBucket(t, d, BucketAsk, "#156: "+cmd+" must stay unresolvable — the allowlist is closed")
	}
}

// TestEscapingResolvedVarsStillDenyNoNewPolicy_156 pins the issue's "no new
// allow/ask/deny policy" requirement: a resolved $HOME/$PWD/$OLDPWD/$USER/
// $TMPDIR that escapes the repo denies through the EXISTING containment
// pipeline, exactly like an equivalent literal path would.
func TestEscapingResolvedVarsStillDenyNoNewPolicy_156(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	literalDeny := classifyBash(`cat `+filepath.Join(base, "outside", "x"), ev)
	wantBucket(t, literalDeny, BucketDeny, "sanity: literal escaping path denies")

	homeDeny := classifyBash(`cat "$HOME/.ssh/id_rsa"`, ev)
	wantBucket(t, homeDeny, BucketDeny, "#156: resolved $HOME escaping the repo denies via existing containment")
}
