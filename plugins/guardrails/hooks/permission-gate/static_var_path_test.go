package main

import (
	"os"
	"path/filepath"
	"testing"
)

// #60: a read-class command whose path argument is built from a variable that
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
	// inside the repo → containment returns contained → DEFER (not ASK).
	cmd1 := `P=` + payload + `; echo "header"; cat "$P/ecosystem-block.yml"; cat "$P/dependabot.yml"`
	d1 := classifyBash(cmd1, ev())
	if d1.Bucket == BucketAsk {
		t.Errorf("#60 trace 1: static-var in-repo path must not ASK; got ASK (%s)", d1.Reason)
	}
	wantBucket(t, d1, BucketDefer, "#60 trace 1: static-var in-repo cat")

	// Trace 2 shape: assign the payload dir, then cat a file under it.
	cmd2 := `P=` + payload + `; echo "header"; cat "$P/README.md"`
	d2 := classifyBash(cmd2, ev())
	if d2.Bucket == BucketAsk {
		t.Errorf("#60 trace 2: static-var in-repo path must not ASK; got ASK (%s)", d2.Reason)
	}
	wantBucket(t, d2, BucketDefer, "#60 trace 2: static-var in-repo cat")

	// The braced form `${P}` resolves the same way.
	cmd3 := `P=` + payload + `; cat "${P}/README.md"`
	d3 := classifyBash(cmd3, ev())
	wantBucket(t, d3, BucketDefer, "#60 braced ${P} in-repo cat")

	// Containment now actually runs on the resolved path: a static var pointing
	// at a SIBLING repo's node_modules is denied (#148), proving resolution
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
func TestStaticVarPathFromCmdSubstStillEscalates_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `D=$(pwd); cat "$D/README.md"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketAsk, "#60 cmd-subst-assigned var still escalates")
	if !containsSubstr(d.Reason, "expansion the gate cannot resolve statically") {
		t.Errorf("#60: cmd-subst var should hit the dynamic-path ask; got %q", d.Reason)
	}

	// A reassignment from a static literal to a dynamic value must DROP the
	// previously-known value: `P=/repo; P=$(pwd); cat "$P/x"` escalates.
	cmd2 := `P=` + repo + `; P=$(pwd); cat "$P/README.md"`
	d2 := classifyBash(cmd2, ev)
	wantBucket(t, d2, BucketAsk, "#60 static-then-dynamic reassignment escalates")
}

// TestUndefinedVarPathStillEscalates_60 covers case (c): a variable that was
// never assigned in the program (an environment variable, or simply undefined)
// is not statically known and must STILL escalate (fail-closed).
func TestUndefinedVarPathStillEscalates_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	cmd := `cat "$HOME/.ssh/id_rsa"`
	d := classifyBash(cmd, ev)
	wantBucket(t, d, BucketAsk, "#60 undefined/env var still escalates")
	if !containsSubstr(d.Reason, "expansion the gate cannot resolve statically") {
		t.Errorf("#60: undefined var should hit the dynamic-path ask; got %q", d.Reason)
	}

	// A non-plain expansion of a known var (e.g. ${P:-/fallback}) is NOT
	// resolved — it keeps the word inexact and escalates.
	cmd2 := `P=` + repo + `; cat "${P:-/etc}/passwd"`
	d2 := classifyBash(cmd2, ev)
	wantBucket(t, d2, BucketAsk, "#60 non-plain expansion of known var still escalates")
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
	wantBucket(t, d, BucketAsk, "#60 env-prefix var must not persist")
}

// #60 follow-up: an assignment made inside a SCOPED construct — a `( … )`
// subshell, a function body, or a backgrounded group — runs in a child shell
// and does NOT persist to the program-global scope in real bash. Such a scoped
// assignment must NOT populate knownVars, so a later top-level `$VAR` use stays
// unknown and escalates (fail-closed). The cases below pin that the scope gate
// is honored, that the top-level #60 fix is not regressed, and that #5's
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
	wantBucket(t, d, BucketAsk, "#60 subshell assignment must not leak to top-level use")
	if !containsSubstr(d.Reason, "expansion the gate cannot resolve statically") {
		t.Errorf("#60: subshell-scoped var should hit the dynamic-path ask; got %q", d.Reason)
	}

	// A subshell assignment must also not SHADOW a later genuinely-unknown use:
	// `( P=/repo; cat "$P/x" ); cat "$P/y"` — the inner cat resolves inside the
	// subshell (correct), but the outer cat must still escalate. The aggregate
	// verdict therefore stays ASK.
	cmd2 := `( P=` + repo + `; cat "$P/README.md" ); cat "$P/README.md"`
	d2 := classifyBash(cmd2, ev)
	wantBucket(t, d2, BucketAsk, "#60 subshell assignment must not leak past the subshell")
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
	wantBucket(t, d, BucketAsk, "#60 function-body assignment must not leak to outside call")
	if !containsSubstr(d.Reason, "expansion the gate cannot resolve statically") {
		t.Errorf("#60: function-scoped var should hit the dynamic-path ask; got %q", d.Reason)
	}

	// A `local` assignment inside a function body is likewise scoped and must
	// not leak: `f() { local P=/repo; }; cat "$P/README.md"` escalates.
	cmd2 := `f() { local P=` + repo + `; }; cat "$P/README.md"`
	d2 := classifyBash(cmd2, ev)
	wantBucket(t, d2, BucketAsk, "#60 function-body local assignment must not leak")
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
	wantBucket(t, d, BucketAsk, "#60 backgrounded-group assignment must not leak")

	// `( P=/repo ) & cat "$P/README.md"` — backgrounded subshell, same outcome.
	cmd2 := `( P=` + repo + ` ) & cat "$P/README.md"`
	d2 := classifyBash(cmd2, ev)
	wantBucket(t, d2, BucketAsk, "#60 backgrounded-subshell assignment must not leak")
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

	// Top-level P, used inside a subshell — resolves and lands in-repo → DEFER.
	cmd := `P=` + repo + `; ( cat "$P/README.md" )`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAsk {
		t.Errorf("#60: top-level var must resolve inside a subshell; got ASK (%s)", d.Reason)
	}
	wantBucket(t, d, BucketDefer, "#60 top-level var resolves inside subshell")

	// Top-level P, used inside a function body — resolves the same way.
	cmd2 := `P=` + repo + `; f() { cat "$P/README.md"; }`
	d2 := classifyBash(cmd2, ev)
	if d2.Bucket == BucketAsk {
		t.Errorf("#60: top-level var must resolve inside a function body; got ASK (%s)", d2.Reason)
	}
}

// TestProcSubstInScopeStillSafe_60 guards that #5's process-substitution
// crash-safety is not regressed by the scope-tracking change: a `<(…)` inside a
// subshell must still classify (inexact → escalate) rather than panic.
func TestProcSubstInScopeStillSafe_60(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	cwd := canonicalize(repo)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}

	// Must not panic, and a process substitution is inexact so it must never ride
	// the ALLOW track (it defers to the normal pipeline, matching the #5 fast
	// path). The crash-safety guarantee is "classifies instead of panicking".
	cmd := `( diff <(echo a) <(echo b) )`
	d := classifyBash(cmd, ev)
	if d.Bucket == BucketAllow {
		t.Errorf("#5 process substitution inside a subshell must not ALLOW; got %q", d.Bucket)
	}
}
