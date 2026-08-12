package main

import (
	"os"
	"path/filepath"
	"testing"
)

// A read-class command whose path argument is built from a variable that
// was assigned a STATIC literal value earlier in the SAME parsed program must
// be resolved to its concrete literal and run through normal containment,
// rather than failing closed on hasUnknownExpansion. Genuinely dynamic paths
// (a variable assigned from a command substitution, or an undefined/env
// variable) must STILL escalate (fail-closed) — the resolution must not regress
// that behavior.

// TestStaticVarPathResolvesToContainment_60 covers case (a): the two traces
// from the issue. A static in-repo `P=...` followed by `cat "$P/file"` resolves
// and runs containment; an in-repo target defers (not ask), and a cross-repo
// target denies (containment now actually runs because the path is resolved).
func TestStaticVarPathResolvesToContainment_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	payload := filepath.Join(repo, "payload")
	if err := os.MkdirAll(payload, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"README.md", "ecosystem-block.yml", "dependabot.yml"} {
		if err := os.WriteFile(filepath.Join(payload, f), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cwd := canonicalize(repo)
	ev := func() *Event {
		return &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}
	}

	// Trace 1 shape: assign the payload subdir, then cat two files under it via
	// a quoted "$P/..." expansion. The path is statically resolvable and lands
	// inside the repo → containment returns contained. Since cat joined the
	// read-only-utility ALLOW, the resolved-and-contained form now ALLOWs (it
	// formerly DEFERRED); the invariant under test is that resolution feeds
	// Engine B (in-repo → not ASK, cross-repo → DENY below), not the terminal.
	cmd1 := `P=` + payload + `; echo "header"; cat "$P/ecosystem-block.yml"; cat "$P/dependabot.yml"`
	d1 := classifyBash(cmd1, ev())
	if d1.Bucket == BucketAsk {
		t.Errorf("#60 trace 1: static-var in-repo path must not ASK; got ASK (%s)", d1.Reason)
	}
	wantBucket(t, d1, BucketAllow, "#60 trace 1: static-var in-repo cat")

	// Trace 2 shape: assign the payload dir, then cat a file under it.
	cmd2 := `P=` + payload + `; echo "header"; cat "$P/README.md"`
	d2 := classifyBash(cmd2, ev())
	if d2.Bucket == BucketAsk {
		t.Errorf("#60 trace 2: static-var in-repo path must not ASK; got ASK (%s)", d2.Reason)
	}
	wantBucket(t, d2, BucketAllow, "#60 trace 2: static-var in-repo cat")

	// The braced form `${P}` resolves the same way.
	cmd3 := `P=` + payload + `; cat "${P}/README.md"`
	d3 := classifyBash(cmd3, ev())
	wantBucket(t, d3, BucketAllow, "#60 braced ${P} in-repo cat")

	// Containment now actually runs on the resolved path: a static var pointing
	// at a SIBLING repo's node_modules is denied, proving resolution
	// feeds Engine B rather than blanket-deferring.
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	nm := filepath.Join(sibling, "node_modules", "pkg")
	if err := os.MkdirAll(nm, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nm, "index.js"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd4 := `Q=` + nm + `; cat "$Q/index.js"`
	d4 := classifyBash(cmd4, ev())
	wantBucket(t, d4, BucketDeny, "#60 static-var cross-repo cat still denied (#148)")
}

// TestStaticVarPathFromCmdSubstStillEscalates_60 covers case (b): a variable
// assigned from a command substitution is NOT statically known, so a later use
// must keep marking hasUnknownExpansion and escalate (fail-closed). It must NOT
// be resolved to an empty / bogus path.
//
// NOTE: `$(pwd)` itself was the example command substitution here before the
// gate began resolving it as a known-anchor substitution (see
// TestPwdAnchorResolvesToTrackedCwd_132 in anchor_cmdsubst_test.go for its new
// behavior). This test now uses `$(git log)` — a real, but NOT allowlisted,
// command substitution — to keep pinning the general "arbitrary command
// substitution stays unresolvable" invariant.
func TestStaticVarPathFromCmdSubstStillEscalates_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `D=$(git log); cat "$D/README.md"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#60 cmd-subst-assigned var still escalates")
	if !containsSubstr(d.Reason, "expansion the gate cannot resolve statically") {
		t.Errorf("#60: cmd-subst var should hit the dynamic-path ask; got %q", d.Reason)
	}

	// A reassignment from a static literal to a dynamic value must DROP the
	// previously-known value: `P=/repo; P=$(git log); cat "$P/x"` escalates.
	cmd2 := `P=` + repo + `; P=$(git log); cat "$P/README.md"`
	d2 := classifyBash(cmd2, ev)
	wantBucket(t, d2, BucketDefer, "#60 static-then-dynamic reassignment escalates")
}

// TestUndefinedVarPathStillEscalates_60 covers case (c): a variable that was
// never assigned in the program (an environment variable, or simply undefined)
// is not statically known and must STILL escalate (fail-closed). $HOME is
// EXCLUDED from this case — it is now resolved via os.UserHomeDir()
// (see TestHomeVarResolvesLikeTilde_156 in var_resolution_test.go) — so this
// test uses $FOO, a name outside that closed allowlist, to keep pinning
// the general "arbitrary env var stays unresolvable" invariant.
func TestUndefinedVarPathStillEscalates_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `cat "$FOO/.ssh/id_rsa"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#60 undefined/env var still escalates")
	if !containsSubstr(d.Reason, "expansion the gate cannot resolve statically") {
		t.Errorf("#60: undefined var should hit the dynamic-path ask; got %q", d.Reason)
	}

	// A non-plain expansion of a known var (e.g. ${P:-/fallback}) is NOT
	// resolved — it keeps the word inexact and escalates.
	cmd2 := `P=` + repo + `; cat "${P:-/etc}/passwd"`
	d2 := classifyBash(cmd2, ev)
	wantBucket(t, d2, BucketDefer, "#60 non-plain expansion of known var still escalates")
}

// TestEnvPrefixVarDoesNotPersist_60 guards an edge of the resolution semantics:
// a `VAR=x cmd` prefix sets env for THAT command only and must NOT persist to a
// later command. A later `cat "$VAR/x"` must still escalate.
func TestEnvPrefixVarDoesNotPersist_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	// `P=/repo true` is a prefix on `true`, not a bare assignment, so P does not
	// persist; the later cat must escalate.
	cmd := `P=` + repo + ` true; cat "$P/README.md"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#60 env-prefix var must not persist")
}

// Follow-up: an assignment made inside a SCOPED construct — a `( … )`
// subshell, a function body, or a backgrounded group — runs in a child shell
// and does NOT persist to the program-global scope in real bash. Such a scoped
// assignment must NOT populate knownVars, so a later top-level `$VAR` use stays
// unknown and escalates (fail-closed). The cases below pin that the scope gate
// is honored, that the top-level resolution fix is not regressed, and that the
// process-substitution crash-safety still holds.

// TestSubshellAssignmentDoesNotLeak_60 covers scope case (a): a static
// assignment inside a `( … )` subshell does not resolve a later TOP-LEVEL use.
// The later `cat "$P/..."` must escalate as an unknown expansion, exactly as if
// P had never been assigned.
func TestSubshellAssignmentDoesNotLeak_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	// `( P=/repo ); cat "$P/README.md"` — P is assigned only in the subshell, so
	// the top-level use is unresolved and escalates.
	cmd := `( P=` + repo + ` ); cat "$P/README.md"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#60 subshell assignment must not leak to top-level use")
	if !containsSubstr(d.Reason, "expansion the gate cannot resolve statically") {
		t.Errorf("#60: subshell-scoped var should hit the dynamic-path ask; got %q", d.Reason)
	}

	// A subshell assignment must also not SHADOW a later genuinely-unknown use:
	// `( P=/repo; cat "$P/x" ); cat "$P/y"` — the inner cat resolves inside the
	// subshell (correct), but the outer cat must still escalate. The aggregate
	// verdict therefore stays ASK.
	cmd2 := `( P=` + repo + `; cat "$P/README.md" ); cat "$P/README.md"`
	d2 := classifyBash(cmd2, ev)
	wantBucket(t, d2, BucketDefer, "#60 subshell assignment must not leak past the subshell")
}

// TestFuncBodyAssignmentDoesNotLeak_60 covers scope case (b): a static
// assignment inside a function body does not leak to a call outside the
// function. Declaring a function does not run its body, and even when run the
// body's assignments are scoped; a later top-level `$P` use must escalate.
func TestFuncBodyAssignmentDoesNotLeak_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	// `f() { P=/repo; }; cat "$P/README.md"` — P is assigned only inside f's
	// body, so the top-level use is unresolved and escalates.
	cmd := `f() { P=` + repo + `; }; cat "$P/README.md"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#60 function-body assignment must not leak to outside call")
	if !containsSubstr(d.Reason, "expansion the gate cannot resolve statically") {
		t.Errorf("#60: function-scoped var should hit the dynamic-path ask; got %q", d.Reason)
	}

	// A `local` assignment inside a function body is likewise scoped and must
	// not leak: `f() { local P=/repo; }; cat "$P/README.md"` escalates.
	cmd2 := `f() { local P=` + repo + `; }; cat "$P/README.md"`
	d2 := classifyBash(cmd2, ev)
	wantBucket(t, d2, BucketDefer, "#60 function-body local assignment must not leak")
}

// TestBackgroundedGroupAssignmentDoesNotLeak_60 covers the backgrounded-scope
// case: a `{ … ; } &` group (or a `( … ) &` subshell) runs in a child shell, so
// an assignment inside it must not leak to a later top-level use.
func TestBackgroundedGroupAssignmentDoesNotLeak_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	// `{ P=/repo; } & cat "$P/README.md"` — the assignment runs in the
	// backgrounded child shell and must not leak; the foreground cat escalates.
	cmd := `{ P=` + repo + `; } & cat "$P/README.md"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#60 backgrounded-group assignment must not leak")

	// `( P=/repo ) & cat "$P/README.md"` — backgrounded subshell, same outcome.
	cmd2 := `( P=` + repo + ` ) & cat "$P/README.md"`
	d2 := classifyBash(cmd2, ev)
	wantBucket(t, d2, BucketDefer, "#60 backgrounded-subshell assignment must not leak")
}

// TestTopLevelVarResolvesInsideScope_60 pins the CORRECT direction of shell
// scope semantics: a TOP-LEVEL static assignment IS visible inside a nested
// scope (a subshell inherits the parent's variables). So a top-level `P=/repo`
// followed by a `( cat "$P/x" )` inside a subshell resolves and runs
// containment — the scope gate only blocks the leak-OUT direction, not the
// inherit-IN direction.
func TestTopLevelVarResolvesInsideScope_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	// Top-level P, used inside a subshell — resolves and lands in-repo. The cat
	// is a read-only-utility ALLOW; the invariant under test is that the
	// inherited var resolves (so the path is contained, not ASK), not the
	// terminal bucket.
	cmd := `P=` + repo + `; ( cat "$P/README.md" )`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("#60: top-level var must resolve inside a subshell; got ASK (%s)", d.Reason)
	}
	wantBucket(t, d, BucketAllow, "#60 top-level var resolves inside subshell")

	// Top-level P, used inside a function body — resolves the same way.
	cmd2 := `P=` + repo + `; f() { cat "$P/README.md"; }`
	d2 := classifyBash(cmd2, ev)
	if d2.Bucket == BucketAsk {
		t.Errorf("#60: top-level var must resolve inside a function body; got ASK (%s)", d2.Reason)
	}
}

// TestProcSubstInScopeStillSafe_60 guards that the process-substitution
// crash-safety is not regressed by the scope-tracking change: a `<(…)` inside a
// subshell must classify rather than panic.
//
// The expected VERDICT changed with the process-substitution grading: an input
// `<(…)` is a /dev/fd pipe, never a path, so it no longer marks the enclosing
// command unprovable, and the substituted commands are classified on their own
// terms. With `echo` on both sides everything is allow-classified, so the line
// allows. The crash-safety guarantee this test was written for — "classifies
// instead of panicking" — is unchanged and still what the call exercises.
func TestProcSubstInScopeStillSafe_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `( diff <(echo a) <(echo b) )`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketAllow, "#5/#225 process substitution inside a subshell classifies without panicking")
}

// A `for x in <words>; do …; done` whose header is a fully static item
// list makes the loop variable's complete value set visible at parse time.
// The loop-var binding must resolve body path operands (or correctly report
// an escaping item), while dynamic lists / globs / in-less loops must keep
// failing closed exactly as before.

// TestForLoopStaticInListResolves_131 is the shape-A repro: a for loop
// over four static in-worktree paths. Each iteration's "$f" resolves and
// contains, so the whole line must not ASK (regression test for the fan-out).
func TestForLoopStaticInListResolves_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	for _, f := range []string{"a.md", "b.md", "c.md", "d.md"} {
		if err := os.WriteFile(filepath.Join(repo, f), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in a.md b.md c.md d.md; do sed -n '1,12p' "$f"; done`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("#131: static for-in list must not ASK; got ASK (%s)", d.Reason)
	}
	wantBucket(t, d, BucketAllow, "#131 static for-in list resolves and contains")
}

// TestForLoopStaticInListEscapingItemDenied_131 pins that EVERY item is
// checked, not just the first: a static list whose second item escapes the
// repo must still be reported (denied), not masked by the first safe item.
func TestForLoopStaticInListEscapingItemDenied_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in a.md ../../../etc/passwd; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 escaping item in an otherwise-static for-in list must be denied")
}

// TestForLoopDynamicInListStillEscalates_131 covers a dynamic `in` list
// (`for f in $LIST`): the item is not statically resolvable, so the loop
// variable must NOT be bound and body uses of "$f" must still fail closed.
func TestForLoopDynamicInListStillEscalates_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in $LIST; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#131 dynamic for-in list must still escalate")
}

// TestForLoopGlobInListResolvesUnderValidCwd_131 (follow-up) covers a glob
// item (`*.md`) under a valid, tracked running cwd: containment is pure path
// arithmetic on the glob's directory prefix (cwd tracking + glob prefixes), so
// every possible match of `*.md` is a child of the tracked cwd and the loop
// now resolves (contained) instead of failing closed.
func TestForLoopGlobInListResolvesUnderValidCwd_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in *.md; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("#131 follow-up: glob for-in list under a valid cwd must not ASK; got ASK (%s)", d.Reason)
	}
	wantBucket(t, d, BucketAllow, "#131 follow-up: glob for-in list resolves via directory-prefix containment")
}

// TestForLoopGlobInListEscapingPrefixDenied_131 covers a glob whose directory
// prefix escapes the repo (`../../*.md`): every possible match is a child of
// that escaping prefix, so the loop must deny, not ask or allow.
func TestForLoopGlobInListEscapingPrefixDenied_131(t *testing.T) {
	base := t.TempDir()
	outer := filepath.Join(base, "outer")
	if err := os.MkdirAll(outer, 0o755); err != nil {
		t.Fatal(err)
	}
	repo := filepath.Join(outer, "nested", "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in ../../*.md; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 follow-up: glob prefix escaping the repo must be denied")
}

// TestForLoopGlobInListCwdInvalidStillEscalates_131 covers a glob item after
// an earlier dynamic `cd` invalidated the running cwd: a relative glob
// cannot be safely anchored, so the loop must still fail closed (ASK).
func TestForLoopGlobInListCwdInvalidStillEscalates_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `cd "$UNKNOWN" && for f in *.md; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#131 follow-up: glob for-in list with invalid running cwd must still escalate")
}

// Loop follow-up (from PR review): braces, known-variable expansion, and
// glob-directory-prefix resolution broaden the for-loop in-list fan-out.
// staticForItems must expand every statically-knowable form and feed EVERY
// expanded item through the existing containment pipeline; irreducibly
// dynamic parts must still fail closed.

// TestForLoopBraceInListBothContained_131 covers the simplest brace case:
// `{a,b}.md`, both members in-repo, must resolve to contained (not ASK).
func TestForLoopBraceInListBothContained_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	for _, f := range []string{"a.md", "b.md"} {
		if err := os.WriteFile(filepath.Join(repo, f), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a,b}.md; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("#131 follow-up: brace for-in list must not ASK; got ASK (%s)", d.Reason)
	}
	wantBucket(t, d, BucketAllow, "#131 follow-up: brace for-in list resolves and contains")
}

// TestForLoopBraceInListDotDotEscapingMemberDenied_131 pins the CORRECT
// behavior for `{a,../../../etc/passwd}`, replacing an earlier version of
// this test that pinned the wrong one. Real bash splits this into "a" and
// "../../../etc/passwd" (verified live: `bash -c 'for f in
// {a,../../../etc/passwd}; do echo "$f"; done'` prints both members
// unchanged). mvdan.cc/sh's own syntax.SplitBraces declines to split any
// brace element containing "..", as a guard against ambiguity with the
// `{x..y}` sequence form — and empirically that decline is not even
// "leave literal braces behind": for other list shapes it can silently DROP
// members instead (see engine_a_bash.go staticExpandItem's doc comment).
// Falling back to ASK whenever upstream declines would push an entirely
// mechanical case onto a human for every escaping-path brace list — the
// guardrails gate's job is to MINIMIZE unnecessary ASK, not maximize it.
// staticExpandBraceFallback now does the comma-list split itself whenever
// upstream's result is declined or suspect, so every member — including the
// escaping one — flows through the existing containment pipeline and gets
// its real verdict via worst-wins: the escaping member denies.
func TestForLoopBraceInListDotDotEscapingMemberDenied_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a,../../../etc/passwd}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 follow-up: '..'-bearing brace list's escaping member must DENY via worst-wins, not ASK")
}

// TestForLoopBraceInListDotDotAllInRepoContained_131 covers the companion
// mixed-list shape: every member of a ".."-bearing brace list resolves
// in-repo (the ".." stays inside the worktree), so the whole line must
// CONTAIN (not ASK) — dropping the fan-out to ASK merely because upstream
// declined the split would waste human attention on a case with an
// unambiguous, all-safe verdict.
func TestForLoopBraceInListDotDotAllInRepoContained_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.MkdirAll(filepath.Join(repo, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"a.md", "b.md"} {
		if err := os.WriteFile(filepath.Join(repo, f), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a.md,sub/../b.md}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("#131 follow-up: all-in-repo '..'-bearing brace list must not ASK; got ASK (%s)", d.Reason)
	}
	wantBucket(t, d, BucketAllow, "#131 follow-up: all-in-repo '..'-bearing brace list resolves and contains")
}

// TestForLoopBraceInListDotDotThreeMemberMiddleDropBugDenied_131 is a
// regression pin for the specific silent-drop failure mode discovered while
// building the fallback splitter: upstream's expand.Braces on a 3+-member
// ".."-bearing list does not always leave residual "{"/"}" text — it can
// instead silently DROP the escaping (and any later) member from its
// returned sub-word slice with no error and no residual-brace signal
// (verified via a probe of mvdan.cc/sh: `{a,b,../c}` returns only two
// sub-words, "a" and "b", never "../c"). A fallback that only checked for
// residual "{"/"}" text would miss this and treat the truncated two-item
// result as fully resolved, silently ALLOWing past the escaping member.
// staticExpandItem's independent hasDotDotBraceMember raw-text cross-check
// (not just the subWords' own content) is what catches this.
func TestForLoopBraceInListDotDotThreeMemberMiddleDropBugDenied_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	for _, f := range []string{"a", "b"} {
		if err := os.WriteFile(filepath.Join(repo, f), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a,b,../../../etc/passwd}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 follow-up: escaping third member of a 3-element '..'-bearing brace list must DENY, not be silently dropped")
}

// TestForLoopBraceNestedFormStillFailsClosed_131 pins the deliberate,
// narrower carve-out: staticExpandBraceFallback only understands the single
// UNNESTED comma-list grammar `{a,b,c}`. Real bash DOES resolve a nested
// ".."-bearing brace group (`{a,{b,../c}}` splits into "a", "b", "../c" —
// verified live), but reproducing bash's full nested-brace grammar is
// exactly the complexity the follow-up spec says to avoid ("if you hit
// a range form you don't handle, fall closed" generalizes to any brace
// grammar this narrow fallback doesn't implement). Upstream's own
// SplitBraces/expand.Braces partially declines this shape too (resolves "a"
// but leaves residual "{"/"}" text for the nested "{b,../c}" sub-part), so
// staticExpandItem's declined-detection fires and hands the raw text to
// staticExpandBraceFallback, whose depth-tracking correctly detects the
// nested "{" and returns ok=false — the whole item then fails closed to ASK
// rather than mis-splitting it.
func TestForLoopBraceNestedFormStillFailsClosed_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a,{b,../c}}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#131 follow-up: a nested '..'-bearing brace group is not the fallback's grammar and must still fail closed")
}

// TestForLoopBraceInListEscapingMemberDeniedNoDotDot_131 covers the same
// worst-wins requirement with a brace member that escapes WITHOUT triggering
// the upstream ".." SplitBraces ambiguity guard, so the brace genuinely
// splits into two items and containment denies the second.
func TestForLoopBraceInListEscapingMemberDeniedNoDotDot_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(base, "etc-passwd-stand-in")
	if err := os.WriteFile(outside, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a,` + outside + `}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 follow-up: escaping brace member denied even when an earlier member was safe")
}

// TestForLoopBraceWithKnownVarContained_131 covers `{a,b}$X.md` where $X was
// assigned a static literal earlier in the program: the brace expansion
// combines with the resolved variable, producing concrete in-repo paths.
func TestForLoopBraceWithKnownVarContained_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	for _, f := range []string{"asub.md", "bsub.md"} {
		if err := os.WriteFile(filepath.Join(repo, f), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `X=sub; for f in {a,b}$X.md; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("#131 follow-up: brace+known-var for-in list must not ASK; got ASK (%s)", d.Reason)
	}
	wantBucket(t, d, BucketAllow, "#131 follow-up: brace+known-var for-in list resolves and contains")
}

// TestForLoopBraceWithUnresolvableVarStillEscalates_131 covers the same
// brace+var shape when $X is NOT statically known: the whole list must still
// fail closed.
func TestForLoopBraceWithUnresolvableVarStillEscalates_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a,b}$X.md; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#131 follow-up: brace+unresolvable-var for-in list must still escalate")
}

// TestForLoopKnownVarListContained_131 covers `for f in $LIST` where LIST was
// assigned a static literal earlier: it must be split on IFS the way bash
// word-splits an unquoted expansion, and each resulting word resolved and
// contained.
func TestForLoopKnownVarListContained_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	for _, f := range []string{"a.md", "b.md"} {
		if err := os.WriteFile(filepath.Join(repo, f), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `LIST="a.md b.md"; for f in $LIST; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("#131 follow-up: known-var for-in list must not ASK; got ASK (%s)", d.Reason)
	}
	wantBucket(t, d, BucketAllow, "#131 follow-up: known-var for-in list splits on IFS and contains")
}

// TestForLoopUnknownVarListStillEscalates_131 covers `for f in $LIST` when
// LIST is NOT statically known (an env var, or simply undefined): the loop
// must still fail closed exactly as before (regression pin).
func TestForLoopUnknownVarListStillEscalates_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in $LIST; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#131 follow-up: unknown-var for-in list must still escalate")
}

// TestForLoopEmptyInListClassifiesBodyZeroTimes_131 pins the deliberate empty
// in-list behavior: `for f in; do …; done` iterates zero times in real bash,
// so the body must be classified (walked) zero times. We pin this by using a
// body that would otherwise escalate (an unresolvable path) — if the body
// were walked even once, the aggregate would ASK; since bash never enters the
// loop, the command has nothing else to classify and must not ASK.
func TestForLoopEmptyInListClassifiesBodyZeroTimes_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in; do cat "$f/../../../etc/passwd"; done`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk || d.Bucket == BucketDeny {
		t.Errorf("#131 follow-up: empty for-in list must classify the body zero times (bash never enters the loop); got %s (%s)", d.Bucket, d.Reason)
	}
}

// TestForLoopCommandSubstInListStillEscalates_131 is a regression pin: a
// command-substitution list (`for f in $(ls)`) is irreducibly dynamic and
// must still escalate.
func TestForLoopCommandSubstInListStillEscalates_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in $(ls); do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#131 follow-up: command-substitution for-in list must still escalate")
}

// TestForLoopNoInListStillEscalates_131 covers a `for x; do …` with no `in`
// clause (iterates "$@"): there is no static item set, so it must still fail
// closed exactly as before.
func TestForLoopNoInListStillEscalates_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `f() { for f; do cat "$f"; done; }`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDefer, "#131 in-less for loop must still escalate")
}

// TestForLoopNestedSaveRestoresOuterBinding_131 covers the save/restore
// discipline: an outer loop binds "f", and a nested inner loop binds "g" from
// a static list built off "$f". After the inner loop finishes, the outer "f"
// binding must be exactly what it was for that outer iteration — the inner
// loop's own save/restore of "g" (and the outer loop's own re-binding of "f"
// per outer iteration) must not corrupt it. Both bodies resolve statically
// across every outer x inner pairing, so the whole line must not ASK.
func TestForLoopNestedSaveRestoresOuterBinding_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	for _, dir := range []string{"a", "b"} {
		sub := filepath.Join(repo, dir, "sub")
		if err := os.MkdirAll(sub, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(sub, "x.md"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in a b; do for g in "$f/sub/x.md"; do cat "$g"; done; cat "$f/sub/x.md"; done`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("#131 nested for loop save/restore: outer var must resolve after inner loop; got ASK (%s)", d.Reason)
	}
	wantBucket(t, d, BucketAllow, "#131 nested for loop save/restore of loop variable")
}

// TestForLoopBraceInListTildeEscapingMemberDenied_131 pins a real fail-open
// found in PR review: a for-loop brace member expressed as a
// tilde-prefixed path (`~/.ssh/id_rsa`) is NOT dropped by upstream
// expand.Braces (only ".."-bearing members are, per hasDotDotBraceMember) and
// is NOT absolute per filepath.IsAbs, so before the containment fix in this
// commit it fell through canonicalizeFrom's relative-join branch and
// resolved to a literal in-repo-looking child path (`<repo>/~/.ssh/id_rsa`)
// — an ALLOW, not a DENY. canonicalizeFrom now expands a leading `~`/`~/`
// against the real home directory before the relative-join step (mirroring
// applyCd's existing `cd ~` handling), so the member resolves to the user's
// real home directory and earns the escapeRepo verdict its true location
// deserves, joining worst-wins with the rest of the brace list.
func TestForLoopBraceInListTildeEscapingMemberDenied_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a.md,~/.ssh/id_rsa}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 follow-up: tilde-expanded escaping brace member must DENY via worst-wins, not ALLOW")
}

// TestForLoopBraceInListAbsoluteEscapingMemberDenied_131 pins the absolute-
// path escaping-member shape named in the PR review High finding. Upstream
// expand.Braces preserves an absolute member unchanged (verified: `{a,
// /etc/passwd}` => `[a /etc/passwd]`, no silent drop), so it reaches
// literalWord/containment on the normal (non-fallback) path and denies via
// ordinary worst-wins — same machinery as any other absolute operand.
func TestForLoopBraceInListAbsoluteEscapingMemberDenied_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a.md,/etc/passwd}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 follow-up: absolute escaping brace member must DENY")
}

// TestForLoopBraceInListHomeVarEscapingMemberDenied_131 pins the $HOME-based
// escaping-member shape named in the PR review High finding. $HOME
// is resolved from its authoritative source (os.UserHomeDir(), the same
// source the sibling `~` tests below already use) rather than failing closed,
// so `$HOME/.ssh/id_rsa` now agrees with `~/.ssh/id_rsa` — both DENY. See
// TestForLoopBraceInListTildeEscapingMemberFirstPosition_131 for the
// equivalent tilde shape this now matches.
func TestForLoopBraceInListHomeVarEscapingMemberDenied_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a.md,$HOME/.ssh/id_rsa}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#156: $HOME-based brace member must DENY, matching the equivalent ~-based member")
}

// TestForLoopBraceInListTildeEscapingMemberFirstPosition_131 and
// TestForLoopBraceInListTildeEscapingMemberMiddlePosition_131 sweep the
// tilde-escape shape across member position, since worst-wins must catch the
// escaping member regardless of where it sits in the list (not just last).
func TestForLoopBraceInListTildeEscapingMemberFirstPosition_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {~/.ssh/id_rsa,a.md}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 follow-up: tilde-escaping brace member in FIRST position must still DENY")
}

func TestForLoopBraceInListTildeEscapingMemberMiddlePosition_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "b.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a.md,~/.ssh/id_rsa,b.md}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 follow-up: tilde-escaping brace member in MIDDLE position must still DENY")
}

// TestForLoopBraceInListMixedDotDotAndAbsoluteEscapeDenied_131 covers a
// three-member list combining a safe literal, a ".."-bearing escaping
// member (the silent-drop shape from the round-2 review), and an absolute
// escaping member (the preserved-by-upstream shape) in the SAME brace list.
// Worst-wins must deny on this combination regardless of which detection
// path (hasDotDotBraceMember fallback vs. normal literalWord path) catches
// which member.
func TestForLoopBraceInListMixedDotDotAndAbsoluteEscapeDenied_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {a,../../x,/etc/y}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 follow-up: mixed '..'-escape + absolute-escape brace members must DENY")
}

// TestForLoopBraceInListBareTildeMemberDenied_131 covers the bare `~` member
// (no trailing slash) — the same tilde-expansion branch in canonicalizeFrom
// handles `~` alone (expands to exactly the home directory) as well as
// `~/...`.
func TestForLoopBraceInListBareTildeMemberDenied_131(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "a.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `for f in {~,a.md}; do cat "$f"; done`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketDeny, "#131 follow-up: bare '~' brace member must DENY (resolves to the real home directory, outside the repo)")
}
