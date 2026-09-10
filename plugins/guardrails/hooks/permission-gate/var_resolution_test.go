package main

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
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
// $HOME must NOT resolve — the word stays inexact and the command withholds
// the allow (a dynamic-path DEFER), it must never silently resolve to "" or
// guess ALLOW.
func TestHomeVarUnresolvableFailsClosed(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)

	file := mustParse(t, `cat "$HOME/.ssh/id_rsa"`)
	resolver := fakeResolver("", errors.New("no home directory"), nil)
	cmds, err := extractSimpleCommands(file, cwd, resolver, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(cmds) != 1 {
		t.Fatalf("expected 1 simple command, got %d", len(cmds))
	}
	if !cmds[0].hasUnknownExpansion {
		t.Errorf("$HOME must fail closed (hasUnknownExpansion=true) when homeDir() errors; got false")
	}

	// Empty string from homeDir() (no error, but no home) must also fail
	// closed, not resolve to an empty-string $HOME.
	resolverEmpty := fakeResolver("", nil, nil)
	cmds2, err := extractSimpleCommands(file, cwd, resolverEmpty, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !cmds2[0].hasUnknownExpansion {
		t.Errorf("$HOME must fail closed when homeDir() returns empty; got hasUnknownExpansion=false")
	}

	// A RELATIVE home is the third spelling, and the one that fails closed
	// least obviously: it is neither an error nor empty, so resolving it hands
	// back a path that is not absolute. `$HOME/.ssh/id_rsa` would then
	// relative-join onto the tracked cwd — the repo — and a home-directory
	// operand would be graded as an in-repo path, which is the same fabricated
	// base applyCd's two $HOME arms already invalidate on.
	resolverRelative := fakeResolver("relative/home", nil, nil)
	cmds3, err := extractSimpleCommands(file, cwd, resolverRelative, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !cmds3[0].hasUnknownExpansion {
		t.Errorf("$HOME must fail closed when homeDir() returns a RELATIVE path; got hasUnknownExpansion=false")
	}
	if len(cmds3[0].args) > 1 && strings.Contains(cmds3[0].args[1], "relative/home") {
		t.Errorf("$HOME under a relative home resolved the operand to %q; a non-absolute home must not reach the operand",
			cmds3[0].args[1])
	}
}

// TestUnresolvableHomeTildeIsInexact pins the TILDE spelling of the rule the
// test above pins for `$HOME`: the two must agree. Failing to resolve $HOME is
// what leaves an unquoted `~` unexpanded — expand.Literal tilde-expands through
// resolveVar — and a surviving literal graded EXACT is a word the gate claims
// to have pinned while it holds a path whose base it does not know. Bare `cat ~`
// is the same word with nothing after the tilde.
//
// Inexactness is where this rule stops. What such an operand is WORTH is
// containment's, and containment denies it: see
// TestUnresolvableHomeTildeOperandDenies.
//
// The quoted `'~/x'` row is deliberate over-approximation rather than bash
// parity (bash reads it as a literal filename under the cwd): containment
// expands a leading tilde whatever the quoting was, so grading it exact here
// would put the two paths back out of step in the fail-open direction.
func TestUnresolvableHomeTildeIsInexact(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)

	for _, home := range []struct {
		name     string
		resolver varResolver
	}{
		{"erroring home", fakeResolver("", errors.New("no home directory"), nil)},
		{"empty home", fakeResolver("", nil, nil)},
		{"relative home", fakeResolver("relative/home", nil, nil)},
	} {
		for _, cmd := range []string{`cat ~/x`, `cat ~`, `cat '~/x'`} {
			cmds, err := extractSimpleCommands(mustParse(t, cmd), cwd, home.resolver, nil)
			if err != nil {
				t.Fatal(err)
			}
			if len(cmds) != 1 {
				t.Fatalf("expected 1 simple command for %q, got %d", cmd, len(cmds))
			}
			if !cmds[0].hasUnknownExpansion {
				t.Errorf("%q under an %s: hasUnknownExpansion = false, want true; a tilde left unexpanded because "+
					"$HOME did not resolve is no more exact than the $HOME spelling it stands in for", cmd, home.name)
			}
		}
	}

	// Negative control: with a usable (absolute) home the tilde resolves, so the
	// word stays EXACT and flows into ordinary containment — this guard must not
	// mark every tilde operand inexact.
	absHome := t.TempDir()
	cmds, err := extractSimpleCommands(mustParse(t, `cat ~/x`), cwd, fakeResolver(absHome, nil, nil), nil)
	if err != nil {
		t.Fatal(err)
	}
	if cmds[0].hasUnknownExpansion {
		t.Errorf("`cat ~/x` under an absolute home %q: hasUnknownExpansion = true, want false", absHome)
	}
	if want := filepath.Join(absHome, "x"); len(cmds[0].args) < 2 || cmds[0].args[1] != want {
		t.Errorf("`cat ~/x` under an absolute home resolved to %v, want the operand %q", cmds[0].args, want)
	}
}

// TestUnresolvableHomeTildeOperandDenies pins the shipped verdict the
// inexactness above must not cost: a `~`-spelled OPERAND under an unusable
// $HOME is a containment escape, and containment's DENY is delivered ahead of
// the dynamic-path defer the marking would otherwise earn (tildeEscapeDeny,
// classify_files.go). os.UserHomeDir reads $HOME directly on Unix, so a
// relative $HOME reaches classifyBash's own resolver.
//
// A defer here would be a REGRESSION, not a conservative reading: `cat
// ~/.ssh/id_rsa` denied outright before the tilde was ever marked inexact, and
// trading that terminal for a prompt weakens the gate on exactly the read the
// deny exists for. Every path list that carries such a spelling is covered — a
// read operand, an input-redirect source, a write target, and a credentialed
// tool's redirect destination — because each defers through an arm of its own.
func TestUnresolvableHomeTildeOperandDenies(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("os.UserHomeDir reads the USERPROFILE env var on windows, not HOME")
	}
	t.Setenv("HOME", "relative/home")

	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: canonicalize(repo), AgentType: "main"}

	for _, cmd := range []string{
		`cat ~/x`, `cat ~`, `cat ~/.ssh/id_rsa`, `cat '~/x'`,
		`cat < ~/.ssh/id_rsa`, `less ~/x`,
		`cp a.md ~/f`, `mkdir ~/d`,
		`git status > ~/f`,
	} {
		if got := classifyBash(cmd, ev).Bucket; got != BucketDeny {
			t.Errorf("%q under a relative $HOME = %q, want %q; a tilde the gate cannot expand is an escape "+
				"containment grades, not a path it cannot read", cmd, got, BucketDeny)
		}
	}

	// The other side of the same rule: a tilde no operand walk returns was never
	// graded by containment, so there is no deny to deliver and the inexactness
	// stands on its own — withholding the allow the word would otherwise ride.
	// `echo ~` ALLOWed before the marking; it must not deny either, since
	// nothing established where that tilde points.
	for _, cmd := range []string{`echo ~`, `printf %s ~`} {
		if got := classifyBash(cmd, ev).Bucket; got == BucketAllow || got == BucketDeny {
			t.Errorf("%q under a relative $HOME = %q, want the withheld allow: no path operand carries the "+
				"tilde, so it is neither provable nor an escape", cmd, got)
		}
	}
}

// TestInScriptHomeAssignmentGraded pins the third source of a home directory
// against the same test the other two get: an in-script `HOME=` assignment is
// what bash expands this script's own `~` against, and resolveVar used to hand
// it back unchecked. With an ABSOLUTE process $HOME masking the fault, a
// relative in-script one expanded `~/x` to `relhome/x`, which relative-joined
// onto the tracked cwd and ALLOWed as an in-worktree read.
func TestInScriptHomeAssignmentGraded(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("os.UserHomeDir reads the USERPROFILE env var on windows, not HOME")
	}
	absHome := t.TempDir()
	t.Setenv("HOME", absHome)

	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: canonicalize(repo), AgentType: "main"}

	if got := classifyBash(`HOME=relhome; cat ~/x`, ev).Bucket; got != BucketDeny {
		t.Errorf("`HOME=relhome; cat ~/x` = %q, want %q; the script's own home is the one its `~` expands "+
			"against, so a relative one fails closed however usable the process's home is", got, BucketDeny)
	}
	// A bare `cd` goes to the script's home too, so the same assignment
	// invalidates the tracked cwd rather than tracking the process's home.
	if got := classifyBash(`HOME=relhome; cd; cat a.md`, ev).Bucket; got == BucketAllow || got == BucketDeny {
		t.Errorf("`HOME=relhome; cd; cat a.md` = %q, want the withheld allow: the cwd the read resolves "+
			"against is unknown, not known-good and not known-bad", got)
	}

	// Negative control: an ABSOLUTE in-script home resolves, and it is that home
	// — not the process's — that the operand is graded against.
	other := filepath.Join(t.TempDir(), "other")
	if got := classifyBash(`HOME=`+other+`; cat ~/x`, ev); got.Bucket != BucketDeny ||
		!strings.Contains(got.Reason, other) {
		t.Errorf("`HOME=%s; cat ~/x` = %q / %q, want a deny naming %q", other, got.Bucket, got.Reason, other)
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
	cmds, err := extractSimpleCommands(file, wt, defaultVarResolver(), nil)
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
	cmds, err := extractSimpleCommands(file, wt, defaultVarResolver(), nil)
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
	cmds, err := extractSimpleCommands(file, cwd, resolver, nil)
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
	cmds, err := extractSimpleCommands(file, cwd, resolver, nil)
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
	cmds, err := extractSimpleCommands(file, cwd, resolver, nil)
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
