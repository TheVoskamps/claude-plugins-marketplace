package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"mvdan.cc/sh/v3/syntax"
)

// The gate held enough information to decide each command below, and escalated
// anyway. Every command in this file is one that a real orchestration run
// prompted a human for — on `issue-fixer`, `pr-reviewer`, `doc-updater` and
// `agent-memory-scrubber` — so the cost was a click on every round of every
// loop, which is what trains a human to approve gate prompts without reading
// them.
//
// The classes are independent; each has its own test.

// --- 1. credentialed-tool redirects are GRADED, not vetoed --------------------

// TestCredentialedRedirectGraded_225 pins that a git/gh/aws redirect whose every
// destination is contained in this worktree earns the same verdict as the same
// write spelled through argv (`tee <path>`), instead of the ungraded ask the
// bare hasRedirectToFile bool used to produce.
func TestCredentialedRedirectGraded_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.MkdirAll(filepath.Join(root, ".claude", "tmp", "issue-update-107"), 0o755); err != nil {
		t.Fatal(err)
	}
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	sib := canonicalize(sibling)

	ev := bashEvIn(t, root, "issue-developer")

	// The control: the same write through argv already allowed. Both spellings
	// of one write must now carry one verdict.
	wantBucket(t, classifyBash("tee .claude/tmp/x.md", ev), BucketAllow, "control: tee into .claude/tmp")

	for _, cmd := range []string{
		"gh pr diff 224 > .claude/tmp/x.md",
		"gh issue view 107 --json body --jq .body > .claude/tmp/issue-update-107/body.md",
		"gh pr diff 212 > " + filepath.Join(root, ".claude", "tmp", "pr212.diff"),
		"gh pr view 208 --json body > " + filepath.Join(root, ".claude", "tmp", "pr208-body.md"),
		"git show HEAD:README.md > .claude/tmp/x",
		"git show HEAD:README.md > " + filepath.Join(root, ".claude", "tmp", "permission-gate"),
		"aws sts get-caller-identity > .claude/tmp/x.json",
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, "contained redirect: "+cmd)
	}

	// A PROVEN escape DENIES (#262), and the reason names clobber and escape
	// rather than exfiltration. It also carries the same prescriptive scratch
	// destinations the Write tool's deny for the identical path carries — which
	// is the whole point of the ask→deny move: one escape, one verdict,
	// whichever spelling reaches it.
	esc := classifyBash("gh pr diff 224 > "+filepath.Join(sib, "x.diff"), ev)
	wantBucket(t, esc, BucketDeny, "redirect escaping to a sibling repo")
	if !containsSubstr(esc.Reason, "clobber") {
		t.Errorf("the escape deny must name clobber; got %q", esc.Reason)
	}
	if containsSubstr(esc.Reason, "exfiltrate") {
		t.Errorf("the escape deny must not claim exfiltration for a local file write; got %q", esc.Reason)
	}
	if !containsSubstr(esc.Reason, ".claude/tmp/") || !containsSubstr(esc.Reason, harnessScratchDisplay()) {
		t.Errorf("the escape deny must prescribe both scratch destinations; got %q", esc.Reason)
	}
	// The spelling control: the Write tool's deny for the SAME destination
	// prescribes the same thing. Before #262 these two diverged — Write denied
	// with this prose while the redirect asked — which is the defect the move
	// closes.
	wd := fileToolBucket(t, "Write", root, filepath.Join(sib, "x.diff"))
	wantBucket(t, wd, BucketDeny, "control: Write to the same escaping destination")
	if !containsSubstr(wd.Reason, ".claude/tmp/") {
		t.Errorf("the Write control must carry the scratch prescription; got %q", wd.Reason)
	}

	// A `.git/` destination denies too, for parity with the Write tool's
	// treatment of the same tree.
	wantBucket(t, classifyBash("gh pr diff 224 > .git/x", ev), BucketDeny, "redirect into .git/")

	// A destination the gate cannot PIN is a different thing: an absence of
	// proof, not a proven escape. It withholds the allow and DEFERS, carrying
	// why into the §7 log.
	unp := classifyBash("gh pr diff 224 > $DEST", ev)
	wantBucket(t, unp, BucketDefer, "unpinnable redirect destination")
	if unp.Operation == "" || !containsSubstr(unp.Reason, "cannot pin statically") {
		t.Errorf("the unpinnable defer must be loggable and say why; got op=%q reason=%q",
			unp.Operation, unp.Reason)
	}

	// EVERY destination must qualify: one good and one escaping still denies.
	wantBucket(t, classifyBash("gh pr diff 224 > .claude/tmp/x.md 2> "+filepath.Join(sib, "e"), ev),
		BucketDeny, "mixed redirect destinations")

	// The wild-caught spelling #262 was filed on, tool by tool: `git show` into
	// `/tmp/` prompted an sdlc:theorem-disprover when the message it was shown
	// would have redirected it perfectly. All three credentialed tools reach the
	// same grading, so all three are pinned — a per-tool call site means a
	// per-tool regression is possible.
	for _, cmd := range []string{
		"git show HEAD:README.md > /tmp/x.md",
		"gh pr diff 224 > /tmp/x.md",
		"aws sts get-caller-identity > /tmp/x.json",
	} {
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketDeny, "credentialed redirect to /tmp: "+cmd)
		if !containsSubstr(d.Reason, ".claude/tmp/") {
			t.Errorf("the /tmp redirect deny must prescribe a scratch destination; got %q", d.Reason)
		}
	}
}

// TestCredentialedRedirectToScratchpadAllows_225 covers the second blessed
// destination: the harness scratchpad the #193 carve-out designates safe by
// construction, which the ungraded veto rejected just as hard as a sibling repo.
//
// All three credentialed tools are enumerated for the same reason the sibling
// `.claude/tmp/` and `/tmp` controls above enumerate them: the grading is
// reached from a per-tool call site (credentialedRedirectVerdict is invoked
// separately from classifyGit, classifyGh and classifyAws), so a per-tool
// regression is possible and a gh-only row would not catch it.
func TestCredentialedRedirectToScratchpadAllows_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	ev := bashEvIn(t, root, "issue-developer")

	dst := scratchTarget(os.Getuid(), sessionSlug, sessionUUID, "scratchpad", "pr224.diff")
	for _, cmd := range []string{
		"gh pr diff 224 > " + dst,
		"git show HEAD:README.md > " + dst,
		"aws sts get-caller-identity > " + dst,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow,
			"redirect into the session scratchpad: "+cmd)
	}
}

// --- 2. anchor command substitutions resolve wherever they appear -------------

// TestAnchorResolvesQuotedInlineAndAsCdTarget_225 pins the three placements the
// #132 allowlist did not reach: the correctly QUOTED assignment RHS (the
// spelling that survives a space in a path), an anchor embedded INLINE in a
// larger word, and an anchor used as a `cd` target.
func TestAnchorResolvesQuotedInlineAndAsCdTarget_225(t *testing.T) {
	_, wt := setupWorktree(t)
	for _, sub := range []string{filepath.Join(".claude", "agent-memory"), "docs"} {
		if err := os.MkdirAll(filepath.Join(wt, sub), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}

	for _, cmd := range []string{
		`R=$(git rev-parse --show-toplevel);   find "$R/.claude" -type f`,
		`R="$(git rev-parse --show-toplevel)"; find "$R/.claude" -type f`,
		`find "$(git rev-parse --show-toplevel)/.claude/agent-memory" -type f`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, "anchor placement: "+cmd)
	}

	// The `cd` forms converge on DEFER, which is what the already-working
	// spelling (`R=$(…); cd "$R" && …`) has always earned: `cd` itself matches no
	// rule, so the line has no high-confidence allow to aggregate and goes back
	// to the normal pipeline. The defect was that the anchor-as-cd-target
	// spellings ASKed instead — a prompt, where the reference spelling produced
	// none. What this pins is that all three now agree.
	for _, cmd := range []string{
		`cd "$(git rev-parse --show-toplevel)" && ls docs`,
		`cd $(git rev-parse --show-toplevel) && ls docs`,
		`R=$(git rev-parse --show-toplevel); cd "$R" && ls docs`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketDefer, "anchor as cd target: "+cmd)
	}
}

// TestAnchorStillRunsThroughContainment_225 is the other half of the widening:
// recognizing an anchor in more PLACES must never change what an anchor
// AUTHORIZES. A resolved anchor still passes through containment and the .git/
// deny exactly as a literal path does.
func TestAnchorStillRunsThroughContainment_225(t *testing.T) {
	_, wt := setupWorktree(t)
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: wt, AgentType: "issue-developer"}

	// The git-common-dir anchor, inline and quoted, still lands under .git/ and
	// still DENIES.
	wantBucket(t, classifyBash(`cat "$(git rev-parse --git-common-dir)/config"`, ev), BucketDeny,
		"inline git-common-dir anchor still hits the .git/ deny")
	// An escaping path built on a resolved anchor still denies as a cross-repo
	// read; the anchor makes the path KNOWABLE, not permitted.
	wantBucket(t, classifyBash(`cat "$(git rev-parse --show-toplevel)/../../../../etc/passwd"`, ev),
		BucketDeny, "an escaping path built on an anchor still denies")
	// A non-allowlisted substitution is still not an anchor.
	wantBucket(t, classifyBash(`find "$(git log -1 --format=%H)/x" -type f`, ev), BucketDefer,
		"a non-allowlisted substitution is not an anchor")
}

// --- 3. gh auth status ---------------------------------------------------------

// TestGhAuthStatusAllows_225 pins that the read verb allows while the
// credential-printing and identity-switching verbs keep their verdicts. `auth`
// is recognized in classifyGh's dedicated switch rather than by joining
// isGhReadOnly's knownNouns, because readVerbs already contains `get` and
// `gh auth token` must keep escalating.
func TestGhAuthStatusAllows_225(t *testing.T) {
	wantBucket(t, classifyCmd(t, "gh auth status", false), BucketAllow, "gh auth status")
	// The recorded spelling pipes into `head -5`, whose obsolete bare-count flag
	// headTailDefers deliberately treats as unrecognized — an unrelated,
	// documented conservatism. So the LINE aggregates to DEFER (back to the
	// normal pipeline, no gate prompt) rather than ALLOW. What matters for this
	// class is that the gh part no longer ASKs.
	piped := classifyCmd(t, "gh auth status 2>&1 | head -5", false)
	if piped.Bucket == BucketAsk {
		t.Errorf("gh auth status piped into head must not ASK; got ASK (%s)", piped.Reason)
	}
	wantBucket(t, classifyCmd(t, "gh auth token", false), BucketAsk, "gh auth token still escalates")
	wantBucket(t, classifyCmd(t, "gh auth switch", false), BucketDeny, "gh auth switch still denies")
}

// TestGhAuthStatusFlagScreen_225 pins the other half of that allow. The verb is a
// read only in the spellings that print no credential: `gh auth status` has its
// own credential-printing FLAG (`-t`/`--show-token`, which `--json hosts` embeds
// in the JSON), so recognizing the verb settles nothing on its own. The
// redirect case is the sharp one — the destination is contained, so without the
// flag screen `gh auth status -t > .claude/tmp/t` lands the live token in a file
// with no human in the loop.
func TestGhAuthStatusFlagScreen_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.MkdirAll(filepath.Join(root, ".claude", "tmp"), 0o755); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, root, "issue-fixer")

	// Every spelling of the credential-printing flag escalates: the separate
	// long flag, the `=`-joined form, the short flag, and a bundled cluster
	// carrying a `t`.
	for _, cmd := range []string{
		"gh auth status --show-token",
		"gh auth status --show-token=true",
		"gh auth status -t",
		"gh auth status -at",
		"gh auth status -ta",
		"gh auth status --json hosts --show-token",
		"gh auth status -t > .claude/tmp/t",
	} {
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketAsk, "credential-printing flag: "+cmd)
		if !containsSubstr(d.Reason, "--show-token") {
			t.Errorf("%q: the ask must name --show-token; got %q", cmd, d.Reason)
		}
	}

	// The control that keeps the redirect case honest: the same redirect WITHOUT
	// the flag allows, so the ask above comes from the flag screen rather than
	// from the destination grading.
	wantBucket(t, classifyBash("gh auth status > .claude/tmp/t", ev), BucketAllow,
		"control: a contained redirect of the credential-free form")

	// The credential-free flags keep the allow.
	for _, cmd := range []string{
		"gh auth status --active",
		"gh auth status -a",
		"gh auth status -h github.com",
		"gh auth status --hostname github.com",
		"gh auth status --hostname=github.com",
		"gh auth status --json hosts",
		"gh auth status --json hosts --jq '.hosts | add'",
		"gh auth status --active --hostname github.example.com",
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, "credential-free flag: "+cmd)
	}

	// An unrecognized flag fails closed rather than riding the verb's allow — a
	// future gh release can add another credential-printing one.
	unknown := classifyBash("gh auth status --print-secret", ev)
	wantBucket(t, unknown, BucketAsk, "unrecognized gh auth status flag")
	if !containsSubstr(unknown.Reason, "--print-secret") {
		t.Errorf("the unknown-flag ask must name the flag; got %q", unknown.Reason)
	}
}

// --- 4. git push HEAD:branch ---------------------------------------------------

// TestGitPushHeadRefspecAllows_225 pins the refspec verdicts. A plain
// `src:dst` is not an overwrite — receive-pack refuses a non-fast-forward
// update unless it is forced — so the ask rested on a false premise. The `+`
// prefix IS the force and is now escalated on its own merits rather than
// incidentally, because it happens to contain a colon.
func TestGitPushHeadRefspecAllows_225(t *testing.T) {
	for _, cmd := range []string{
		"git push origin HEAD:issue-216-fail-closed-on-missing-gate-binary",
		"git push origin HEAD:refs/heads/issue-216-fail-closed-on-missing-gate-binary",
	} {
		wantBucket(t, classifyCmd(t, cmd, true), BucketAllow, "plain refspec: "+cmd)
	}
	wantBucket(t, classifyCmd(t, "git push origin +HEAD:issue-216-x", true), BucketAsk, "forced refspec")

	// Unchanged neighbours.
	wantBucket(t, classifyCmd(t, "git push --mirror origin", true), BucketDeny, "--mirror")
	wantBucket(t, classifyCmd(t, "git push --prune origin", true), BucketDeny, "--prune")
	wantBucket(t, classifyCmd(t, "git push --force origin main", true), BucketAsk, "--force")
	// The refspec being safe does not make the command safe: the plain-refspec
	// branch moves on to the next positional, and --force is still graded after
	// the loop.
	wantBucket(t, classifyCmd(t, "git push --force origin HEAD:issue-216-x", true), BucketAsk,
		"--force alongside a plain refspec")
	wantBucket(t, classifyCmd(t, "git push --force-with-lease origin HEAD:main", true), BucketAllow,
		"--force-with-lease")
}

// --- 5. process substitution ----------------------------------------------------

// TestProcessSubstitutionIsNotAPath_225 pins that `<(cmd)` is graded as the
// /dev/fd pipe it is, not as "a path argument built from an expansion the gate
// cannot resolve statically". The substituted commands are classified on their
// own terms, which is what makes the enclosing command's allow sound.
func TestProcessSubstitutionIsNotAPath_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.MkdirAll(filepath.Join(root, ".claude", "agent-memory", "x"), 0o755); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, root, "issue-developer")

	for _, cmd := range []string{
		"comm -3 <(ls .claude/agent-memory/x | sort) <(grep -o name .claude/agent-memory/x | sort)",
		"diff <(echo a) <(echo b)",
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, "process substitution: "+cmd)
	}

	// The inner command is judged on its own terms: a substituted read that
	// escapes the repo still denies, even though the enclosing `comm` sees only
	// a pipe.
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	wantBucket(t, classifyBash("comm -3 <(cat "+filepath.Join(canonicalize(sibling), "x")+") <(echo b)", ev),
		BucketDeny, "an escaping read inside a process substitution still denies")

	// A real path operand alongside a process substitution is still contained.
	wantBucket(t, classifyBash("diff "+filepath.Join(canonicalize(sibling), "x")+" <(echo b)", ev),
		BucketDeny, "a real operand alongside a process substitution is still contained")
}

// TestProcSubstInRedirectPositionIsClassified_225 is the redirect-position half
// of the test above. Both positions have to earn the same verdict: `<(cmd)` is
// exact wherever it sits, and the containment walks skip the /dev/fd token in a
// redirect target exactly as they do in argv, so a descent wired only to argv
// would leave `cat < <(cat <escaping-path>)` graded by nobody and riding the
// enclosing command's ALLOW while the argv spelling denies.
func TestProcSubstInRedirectPositionIsClassified_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	ev := bashEvIn(t, root, "issue-developer")

	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	escaping := filepath.Join(canonicalize(sibling), ".env")

	// An escaping read inside a redirect-position substitution denies, in every
	// spelling the walk can reach it through: a simple command's own redirect, a
	// compound statement's redirect, and a statement that is redirects and
	// nothing else (no Cmd at all).
	for _, cmd := range []string{
		"cat < <(cat " + escaping + ")",
		"wc -l < <(cat " + escaping + ")",
		"grep x < <(cat " + escaping + ")",
		"cat < <(cat /etc/passwd)",
		"{ cat; } < <(cat /etc/passwd)",
		"< <(cat /etc/passwd)",
		// An OUTPUT substitution in a redirect position runs its command too,
		// so its escaping WRITE is graded the same way.
		"cat > >(tee " + filepath.Join(canonicalize(sibling), "out") + ")",
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketDeny, "redirect-position process substitution: "+cmd)
	}

	// The argv spelling of the same read — the control this must agree with.
	wantBucket(t, classifyBash("comm -3 <(cat "+escaping+") <(echo b)", ev),
		BucketDeny, "control: the argv spelling denies")

	// A contained substituted command keeps the enclosing ALLOW: the descent
	// classifies, it does not blanket-escalate.
	for _, cmd := range []string{
		"cat < <(echo hi)",
		"wc -l < <(grep x file)",
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, "benign redirect-position substitution: "+cmd)
	}

	// The substituted command is resolved against the cwd in effect BEFORE this
	// statement's own `cd`, matching bash (the pipe is set up during word
	// expansion, before `cd` runs) and matching the argv-position descent, which
	// also precedes applyCd. `sub/../x` would be contained; `../x` from the repo
	// root is not, and that is the one that must be graded.
	if err := os.MkdirAll(filepath.Join(root, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	wantBucket(t, classifyBash("cd sub < <(cat ../x)", ev), BucketDeny,
		"the substitution is resolved against the pre-cd cwd")

	// Structural: the descent must not swallow the #193 redirect-only fallback.
	// That fallback fires only when the descent into stmt.Cmd emitted nothing, so
	// a substituted command counted as "something emitted" would leave the WRITE
	// half of the same statement ungraded. It has to hold for a substitution in
	// the statement's COMMAND node as well as in its redirects — `[[ … ]]` runs no
	// program, so the fallback is the only thing grading `out.log` in either.
	for _, src := range []string{
		"[[ -f a ]] > out.log < <(echo hi)",
		"[[ -f <(echo hi) ]] > out.log",
	} {
		cmds, err := extractSimpleCommands(mustParse(t, src), root, defaultVarResolver(), nil)
		if err != nil {
			t.Fatalf("%q: extract failed: %v", src, err)
		}
		var haveRedirectOnly bool
		for _, sc := range cmds {
			if sc.redirectOnly && len(sc.redirectTargets) == 1 && sc.redirectTargets[0] == "out.log" {
				haveRedirectOnly = true
			}
		}
		if !haveRedirectOnly {
			t.Errorf("%q: the redirect-only fallback must still grade the write half; got %d commands %v",
				src, len(cmds), cmds)
		}
	}
}

// TestProcSubstGradedInEveryWordPosition_225 is the whole-class half. Bash
// accepts a process substitution in every word position, not just argv and a
// redirect target, and in each of them literalWord reduces an INPUT
// substitution to the procSubstFD token the containment walks skip — so a
// descent wired to a hand-listed few leaves the substituted command graded by
// nobody while the enclosing line rides the allow track. Every position below
// was measured to RUN the substituted command in real bash, so grading it is
// what bash itself does, not a conservative guess.
func TestProcSubstGradedInEveryWordPosition_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	ev := bashEvIn(t, root, "issue-developer")

	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	esc := filepath.Join(canonicalize(sibling), ".env")

	// Each row spells one position three ways: with an ESCAPING inner read,
	// which must DENY on the inner command's own terms; with a BENIGN one; and
	// with NO substitution at all. The last two must agree — that is what says
	// the descent classifies rather than blanket-escalating, and it keeps a
	// `defer` attributable to the construct (a line whose commands have no
	// high-confidence allow of their own) instead of to the descent.
	for _, tc := range []struct{ name, escaping, benign, noSubst string }{
		{
			// The two rows this PR regressed: the header word is now an exact
			// procSubstFD literal, so staticForItems fans out and binds the loop
			// variable, and recordAssign puts the same literal into knownVars —
			// both moving a body that uses the variable from defer to allow.
			"for-item, loop variable used in the body",
			`for f in <(cat ` + esc + `); do cat "$f"; done`,
			`for f in <(echo hi); do cat "$f"; done`,
			`for f in a; do cat "$f"; done`,
		},
		{
			"assignment RHS, variable used later",
			`x=<(cat ` + esc + `); cat "$x"`,
			`x=<(echo hi); cat "$x"`,
			`x=a; cat "$x"`,
		},
		{
			// Pre-existing allows on main: none of these positions was ever
			// descended into, so the inner command could be anything at all.
			"for-item, loop variable unused",
			`for f in <(cat ` + esc + `); do echo x; done`,
			`for f in <(echo hi); do echo x; done`,
			`for f in a; do echo x; done`,
		},
		{
			"select-item",
			`select f in <(cat ` + esc + `); do echo x; done`,
			`select f in <(echo hi); do echo x; done`,
			`select f in a; do echo x; done`,
		},
		{
			"case subject word",
			`case <(cat ` + esc + `) in *) echo x;; esac`,
			`case <(echo hi) in *) echo x;; esac`,
			`case a in *) echo x;; esac`,
		},
		{
			"case pattern",
			`case x in <(cat ` + esc + `)) echo x;; esac`,
			`case x in <(echo hi)) echo x;; esac`,
			`case x in a) echo x;; esac`,
		},
		{
			"array assignment element",
			`arr=( <(cat ` + esc + `) ); echo x`,
			`arr=( <(echo hi) ); echo x`,
			`arr=( a ); echo x`,
		},
		{
			"inline environment prefix",
			`FOO=<(cat ` + esc + `) true`,
			`FOO=<(echo hi) true`,
			`FOO=a true`,
		},
		{
			"declaration clause RHS",
			`export y=<(cat ` + esc + `); echo x`,
			`export y=<(echo hi); echo x`,
			`export y=a; echo x`,
		},
		{
			"declaration clause array element",
			`declare -a A=( <(cat ` + esc + `) ); echo x`,
			`declare -a A=( <(echo hi) ); echo x`,
			`declare -a A=( a ); echo x`,
		},
		{
			// `[[ … ]]` runs no external command, so nothing else in the
			// statement could ever have carried the inner verdict.
			"test clause operand",
			`[[ -e <(cat ` + esc + `) ]] && echo x`,
			`[[ -e <(echo hi) ]] && echo x`,
			`[[ -e a ]] && echo x`,
		},
		{
			"here-string",
			`cat <<< <(cat ` + esc + `)`,
			`cat <<< <(echo hi)`,
			`cat <<< a`,
		},
		{
			// The `else` arm is the one construct reached by a direct walkCmd
			// call rather than through walkStmt. Its line DEFERS either way —
			// `:` and `true` earn no high-confidence allow — which is exactly
			// what the no-substitution control establishes.
			"else arm",
			`if true; then :; else cat <(cat ` + esc + `); fi`,
			`if true; then :; else cat <(echo hi); fi`,
			`if true; then :; else cat a; fi`,
		},
	} {
		wantBucket(t, classifyBash(tc.escaping, ev), BucketDeny, "escaping read in "+tc.name)
		want := classifyBash(tc.noSubst, ev).Bucket
		if want == BucketDeny || want == BucketAsk {
			t.Fatalf("%s: the substitution-free control must not already escalate; got %v", tc.name, want)
		}
		wantBucket(t, classifyBash(tc.benign, ev), want, "benign substitution in "+tc.name)
	}

	// A substitution runs in a CHILD shell, so an assignment or a `cd` inside
	// one must not leak into the enclosing program's resolution state — the
	// descent walks it at scopeDepth+1, exactly as a `( … )` subshell is walked.
	// Without that, `$P` below would resolve to the sibling repo and the read
	// would be graded against a path bash never builds.
	for _, cmd := range []string{
		`cat <(P=` + filepath.Dir(esc) + `; echo hi); cat "$P/.env"`,
		`cat <(cd ` + filepath.Dir(esc) + `; echo hi); cat .env`,
	} {
		if got := classifyBash(cmd, ev).Bucket; got == BucketAllow {
			t.Errorf("a substituted subshell's state must not leak; %q allowed", cmd)
		}
	}
}

// TestProcSubstDescentIsExhaustive_225 is the structural guard the row-by-row
// test above cannot give: hand-enumerating word positions did not converge
// (each of three review rounds found a position the round before had missed),
// so this asserts the invariant directly — for every shape, the number of
// substituted commands the walk GRADES equals the number of ProcSubst nodes the
// PARSER reports. A future position added to bash, or a walk arm that stops
// forwarding, fails here rather than silently allowing.
func TestProcSubstDescentIsExhaustive_225(t *testing.T) {
	// `marker` is not a real program; it only has to arrive at the walk's output
	// as args[0] of its own simple command.
	const marker = "zz-substituted-marker"

	for _, tc := range []struct {
		src string
		// wantGraded is the number of substituted commands that must be graded,
		// normally the parser's ProcSubst-node count. The exceptions are stated
		// per row.
		wantGraded int
	}{
		{`cat <(` + marker + `)`, 1},
		{`cat < <(` + marker + `)`, 1},
		{`cat > >(` + marker + `)`, 1},
		{`cat <<< <(` + marker + `)`, 1},
		{`for f in <(` + marker + `); do :; done`, 1},
		{`for f in a <(` + marker + `) b; do :; done`, 1},
		{`select f in <(` + marker + `); do break; done`, 1},
		{`case <(` + marker + `) in *) :;; esac`, 1},
		{`case x in <(` + marker + `)) :;; esac`, 1},
		{`case x in y|<(` + marker + `)) :;; esac`, 1},
		{`x=<(` + marker + `)`, 1},
		{`arr=( <(` + marker + `) )`, 1},
		{`FOO=<(` + marker + `) true`, 1},
		{`export y=<(` + marker + `)`, 1},
		{`declare -a A=( <(` + marker + `) )`, 1},
		{`f() { local z=<(` + marker + `); :; }`, 1},
		{`[[ -e <(` + marker + `) ]]`, 1},
		{`(( 1 )) < <(` + marker + `)`, 1},
		{`coproc C { cat <(` + marker + `); }`, 1},
		{`time cat <(` + marker + `)`, 1},
		{`while cat <(` + marker + `); do break; done`, 1},
		{`until cat <(` + marker + `); do break; done`, 1},
		{`if true; then :; else cat <(` + marker + `); fi`, 1},
		{`for f in a; do cat <(` + marker + `); done`, 1},
		{`{ cat; } < <(` + marker + `)`, 1},
		{`( cat <(` + marker + `) )`, 1},
		{`cat <(` + marker + `) &`, 1},
		// Nesting: each substitution is graded exactly once, and the inner one is
		// reached through the outer one's own statements.
		{`cat <(cat <(` + marker + `))`, 1},
		{`cat <(` + marker + `) <(` + marker + `)`, 2},
		// Cross-class nesting. A process substitution inside a COMMAND
		// substitution's body is reached because descendCmdSubsts walks that body's
		// statements through walkStmt, which runs this descent on each of them.
		// This row wanted 0 while descendCmdSubsts was wired only to a declaration
		// clause's RHS.
		{`echo "$(cat <(` + marker + `))"`, 1},
		{`x=$(cat <(` + marker + `))`, 1},
	} {
		file := mustParse(t, tc.src)
		nodes := countProcSubstNodes(file)
		if nodes == 0 {
			t.Errorf("%q: the corpus row must contain a ProcSubst node to be worth anything", tc.src)
		}
		cmds, err := extractSimpleCommands(file, t.TempDir(), defaultVarResolver(), nil)
		if err != nil {
			t.Fatalf("%q: extract failed: %v", tc.src, err)
		}
		if graded := countGraded(cmds, marker); graded != tc.wantGraded {
			t.Errorf("%q: %d substituted command(s) graded, want %d (parser reports %d ProcSubst node(s))",
				tc.src, graded, tc.wantGraded, nodes)
		}
	}

	// A line carrying an unrecognized substituted command must not ride the allow
	// track, whichever class the substitution belongs to.
	ev := bashEvIn(t, canonicalize(t.TempDir()), "issue-developer")
	for _, src := range []string{
		`echo "$(cat <(` + marker + `))"`,
		`cat <(echo "$(` + marker + `)")`,
	} {
		if got := classifyBash(src, ev).Bucket; got == BucketAllow {
			t.Errorf("%q: a nested substitution must not ride the allow track; got %v", src, got)
		}
	}
}

// --- 5b. command substitution ---------------------------------------------------

// TestCmdSubstGradedInEveryWordPosition_225 is the command-substitution half of
// TestProcSubstGradedInEveryWordPosition_225, and it closes a hole that pre-dates
// this branch (every escaping row below ALLOWs at #225's merge base).
//
// A non-anchor `$(…)` leaves its word INEXACT, and that half-covers the class:
// inexactness stops the allow track only where the inexact word rides a command
// the walk emits. The positions below emit no command of their own — a
// `for`/`select` item list, a `case` subject or pattern, an inline `VAR=… cmd`
// prefix, an array element, a `[[ … ]]` operand, a bare or declared assignment
// RHS — so nothing carried the inexactness forward and the line allowed on its
// remaining parts while bash ran an arbitrary substituted command.
func TestCmdSubstGradedInEveryWordPosition_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	ev := bashEvIn(t, root, "issue-developer")

	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	esc := filepath.Join(canonicalize(sibling), ".env")

	// Each row spells one position three ways: with an ESCAPING inner read, which
	// must DENY on the inner command's own terms; with a BENIGN one; and with NO
	// substitution at all. The last two must agree — that is what says the descent
	// classifies rather than blanket-escalating.
	//
	// Rows whose substitution-free control runs no command at all (`export y=a`,
	// `x=a`, `[[ -e a ]]`, a function declaration) carry a trailing `; echo x` in
	// all three spellings, so the control has an allow of its own to earn and the
	// comparison is about the substitution rather than about an empty line.
	for _, tc := range []struct{ name, escaping, benign, noSubst string }{
		{
			"for-item list",
			`for f in $(cat ` + esc + `); do echo x; done`,
			`for f in $(echo hi); do echo x; done`,
			`for f in a; do echo x; done`,
		},
		{
			"select-item list",
			`select f in $(cat ` + esc + `); do echo x; done`,
			`select f in $(echo hi); do echo x; done`,
			`select f in a; do echo x; done`,
		},
		{
			"case subject word",
			`case $(cat ` + esc + `) in a) echo x;; esac`,
			`case $(echo hi) in a) echo x;; esac`,
			`case a in a) echo x;; esac`,
		},
		{
			"case pattern",
			`case x in $(cat ` + esc + `)) echo x;; esac`,
			`case x in $(echo hi)) echo x;; esac`,
			`case x in a) echo x;; esac`,
		},
		{
			// The prefix lives on the CallExpr's Assigns, not its Args, so
			// reduceCallExpr never even calls literalWord on it — the inexactness
			// this position could have inherited was never recorded in the first
			// place.
			"inline environment prefix",
			`FOO=$(cat ` + esc + `) echo hi`,
			`FOO=$(echo hi) echo hi`,
			`FOO=a echo hi`,
		},
		{
			"array assignment element",
			`arr=( $(cat ` + esc + `) ); echo x`,
			`arr=( $(echo hi) ); echo x`,
			`arr=( a ); echo x`,
		},
		{
			"declaration clause array element",
			`declare -a A=( $(cat ` + esc + `) ); echo x`,
			`declare -a A=( $(echo hi) ); echo x`,
			`declare -a A=( a ); echo x`,
		},
		{
			"test clause operand",
			`[[ -e $(cat ` + esc + `) ]] && echo x`,
			`[[ -e $(echo hi) ]] && echo x`,
			`[[ -e a ]] && echo x`,
		},
		{
			"bare assignment RHS",
			`x=$(cat ` + esc + `); echo x`,
			`x=$(echo hi); echo x`,
			`x=a; echo x`,
		},
		{
			"declaration clause RHS",
			`export y=$(cat ` + esc + `); echo x`,
			`export y=$(echo hi); echo x`,
			`export y=a; echo x`,
		},
		{
			"local declaration inside a function body",
			`f() { local d=$(cat ` + esc + `); }; echo x`,
			`f() { local d=$(echo hi); }; echo x`,
			`f() { local d=a; }; echo x`,
		},
		{
			// bash expands `$(…)` in an UNQUOTED here-document body and the parser
			// reports the node there; the quoted `<<'EOF'` spelling is covered by
			// the exhaustiveness test's own row.
			"unquoted here-document body",
			"cat <<EOF\n$(cat " + esc + ")\nEOF\n",
			"cat <<EOF\n$(echo hi)\nEOF\n",
			"cat <<EOF\na\nEOF\n",
		},
		{
			// A parameter expansion's word. This is the position the sibling
			// process-substitution class cannot reach at all (the parser reports no
			// ProcSubst node inside a ParamExp); for `$(…)` the node IS reported, so
			// the same traversal grades it. bash runs it in both the quoted and the
			// unquoted spelling when the parameter is unset.
			"parameter expansion default word",
			`for f in ${Q:-$(cat ` + esc + `)}; do echo x; done`,
			`for f in ${Q:-$(echo hi)}; do echo x; done`,
			`for f in ${Q:-a}; do echo x; done`,
		},
		{
			// The backtick spelling parses to the same *syntax.CmdSubst node, so it
			// needs no case of its own in the walk — only a row here saying so.
			"backtick spelling, argv position",
			"echo `cat " + esc + "`",
			"echo `echo hi`",
			"echo a",
		},
	} {
		wantBucket(t, classifyBash(tc.escaping, ev), BucketDeny, "escaping read in "+tc.name)
		want := classifyBash(tc.noSubst, ev).Bucket
		if want == BucketDeny || want == BucketAsk {
			t.Fatalf("%s: the substitution-free control must not already escalate; got %v", tc.name, want)
		}
		if tc.name == "backtick spelling, argv position" {
			// The one row whose benign form legitimately diverges from its control:
			// an argv-position substitution leaves `echo`'s own word inexact, so the
			// line cannot ride the allow track however benign the inner command is.
			// That is the pre-existing inexactness behavior, not the descent's.
			wantBucket(t, classifyBash(tc.benign, ev), BucketDefer, "benign substitution in "+tc.name)
			continue
		}
		wantBucket(t, classifyBash(tc.benign, ev), want, "benign substitution in "+tc.name)
	}

	// A substitution runs in a CHILD shell, so an assignment or a `cd` inside one
	// must not leak into the enclosing program's resolution state — the descent
	// walks it at scopeDepth+1, exactly as a `( … )` subshell is walked. Without
	// that, `$P` below would resolve to the sibling repo and the read would be
	// graded against a path bash never builds.
	for _, cmd := range []string{
		`x=$(P=` + filepath.Dir(esc) + `; echo hi); cat "$P/.env"`,
		`x=$(cd ` + filepath.Dir(esc) + `; echo hi); cat .env`,
	} {
		if got := classifyBash(cmd, ev).Bucket; got == BucketAllow {
			t.Errorf("a substituted subshell's state must not leak; %q allowed", cmd)
		}
	}
}

// TestCmdSubstDescentIsExhaustive_225 is the count-equality guard for the
// command-substitution class, mirroring TestProcSubstDescentIsExhaustive_225:
// for every shape, the number of substituted commands the walk GRADES equals the
// number of CmdSubst nodes the PARSER reports. Hand-enumerating word positions is
// what failed to converge on this issue, so the invariant is asserted directly
// rather than as a list of positions someone has to keep complete.
func TestCmdSubstDescentIsExhaustive_225(t *testing.T) {
	// `marker` is not a real program; it only has to arrive at the walk's output
	// as args[0] of its own simple command.
	const marker = "zz-substituted-marker"

	for _, tc := range []struct {
		src string
		// wantGraded is the number of substituted commands that must be graded,
		// always the parser's CmdSubst-node count here. The one class of exception
		// — an allowlisted anchor — is asserted separately below, because it needs
		// a resolved repoContext to be an anchor at all.
		wantGraded int
	}{
		{`echo $(` + marker + `)`, 1},
		{`echo "$(` + marker + `)"`, 1},
		{"echo `" + marker + "`", 1},
		{`echo pre$(` + marker + `)post`, 1},
		{`for f in $(` + marker + `); do :; done`, 1},
		{`for f in a $(` + marker + `) b; do :; done`, 1},
		{`select f in $(` + marker + `); do break; done`, 1},
		{`case $(` + marker + `) in *) :;; esac`, 1},
		{`case x in $(` + marker + `)) :;; esac`, 1},
		{`case x in y|$(` + marker + `)) :;; esac`, 1},
		{`x=$(` + marker + `)`, 1},
		{`arr=( $(` + marker + `) )`, 1},
		{`FOO=$(` + marker + `) true`, 1},
		{`export y=$(` + marker + `)`, 1},
		{`declare -a A=( $(` + marker + `) )`, 1},
		{`f() { local z=$(` + marker + `); :; }`, 1},
		{`[[ -e $(` + marker + `) ]]`, 1},
		{`true > $(` + marker + `)`, 1},
		{`true < $(` + marker + `)`, 1},
		{`(( 1 )) < $(` + marker + `)`, 1},
		{`cat <<< $(` + marker + `)`, 1},
		{"cat <<EOF\n$(" + marker + ")\nEOF\n", 1},
		{`: ${Q:-$(` + marker + `)}`, 1},
		{`: "${Q:-$(` + marker + `)}"`, 1},
		{`cd $(` + marker + `)`, 1},
		{`coproc C { cat $(` + marker + `); }`, 1},
		{`time cat $(` + marker + `)`, 1},
		{`while cat $(` + marker + `); do break; done`, 1},
		{`until cat $(` + marker + `); do break; done`, 1},
		{`if true; then :; else cat $(` + marker + `); fi`, 1},
		{`for f in a; do cat $(` + marker + `); done`, 1},
		{`{ cat; } < $(` + marker + `)`, 1},
		{`( cat $(` + marker + `) )`, 1},
		{`cat $(` + marker + `) &`, 1},
		// Nesting: each substitution is graded exactly once, and the inner one is
		// reached through the outer one's own statements.
		{`echo $(` + marker + `-a $(` + marker + `-b))`, 2},
		{`cat $(` + marker + `) $(` + marker + `)`, 2},
	} {
		file := mustParse(t, tc.src)
		nodes := countCmdSubstNodes(file)
		if nodes == 0 {
			t.Errorf("%q: the corpus row must contain a CmdSubst node to be worth anything", tc.src)
		}
		cmds, err := extractSimpleCommands(file, t.TempDir(), defaultVarResolver(), nil)
		if err != nil {
			t.Fatalf("%q: extract failed: %v", tc.src, err)
		}
		if graded := countGraded(cmds, marker); graded != tc.wantGraded {
			t.Errorf("%q: %d substituted command(s) graded, want %d (parser reports %d CmdSubst node(s))",
				tc.src, graded, tc.wantGraded, nodes)
		}
	}

	// The two spellings bash does NOT expand. Neither needs a case in the walk,
	// because the parser reports no CmdSubst node for either — measured here so a
	// future upstream change that starts reporting one fails loudly instead of
	// silently widening what gets graded.
	for _, src := range []string{
		`echo '$(` + marker + `)'`,
		"cat <<'EOF'\n$(" + marker + ")\nEOF\n",
	} {
		file := mustParse(t, src)
		if nodes := countCmdSubstNodes(file); nodes != 0 {
			t.Errorf("%q: parser now reports %d CmdSubst node(s); bash does not expand this spelling", src, nodes)
		}
	}
}

// countCmdSubstNodes returns how many *syntax.CmdSubst nodes the parser reports
// beneath n. Both spellings — `$(cmd)` and the backtick “ `cmd` “ — are one
// such node each.
func countCmdSubstNodes(n syntax.Node) int {
	count := 0
	syntax.Walk(n, func(node syntax.Node) bool {
		if node == nil {
			return false
		}
		if _, ok := node.(*syntax.CmdSubst); ok {
			count++
		}
		return true
	})
	return count
}

// countProcSubstNodes is countCmdSubstNodes for the sibling class.
func countProcSubstNodes(n syntax.Node) int {
	count := 0
	syntax.Walk(n, func(node syntax.Node) bool {
		if node == nil {
			return false
		}
		if _, ok := node.(*syntax.ProcSubst); ok {
			count++
		}
		return true
	})
	return count
}

// countGraded returns how many of the walk's emitted commands are a marker
// program, i.e. how many substituted commands the descent actually graded. The
// match is on a PREFIX so a nested corpus row can distinguish its two levels
// (`$(marker-a $(marker-b))`) while still counting both.
func countGraded(cmds []simpleCommand, marker string) int {
	graded := 0
	for _, sc := range cmds {
		if len(sc.args) > 0 && strings.HasPrefix(sc.args[0], marker) {
			graded++
		}
	}
	return graded
}

// TestAnchorCmdSubstIsNotDescendedInto_225 pins the descent's one deliberate
// exception, on both axes.
//
// STRUCTURAL: an allowlisted anchor substitution is skipped, so its CmdSubst node
// is reported by the parser and graded by nobody. That is sound because
// resolveAnchorCmdSubst admits only a single plain CallExpr whose argv equals one
// of three read-only forms EXACTLY — the command is already known in full, and
// the value it resolves to still runs through normal containment.
//
// BEHAVIORAL: grading them instead would regress #132's own idiom. Measured by
// deleting the skip and re-running this test, the two git anchors grade as ALLOW
// and cost nothing, but bare `pwd` earns no high-confidence allow of its own, so
// descending into `$(pwd)` turns `cat "$(pwd)/a.txt"`, `case "$(pwd)" in …` and
// `FOO=$(pwd) echo hi` from allows into prompts. The skip is applied uniformly
// across the allowlist anyway — one rule rots less than three — so the structural
// half below covers all three forms.
func TestAnchorCmdSubstIsNotDescendedInto_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, root, "issue-developer")

	rc, err := resolveRepoContext(root)
	if err != nil {
		t.Fatalf("resolveRepoContext: %v", err)
	}

	// Structural: the node is there, the descent emits nothing for it. `pwd` is
	// the row that would otherwise cost an allow; the two git forms are included
	// so a future edit cannot quietly narrow the exception to one anchor.
	for _, src := range []string{
		`cat "$(git rev-parse --show-toplevel)/a.txt"`,
		`cat "$(git rev-parse --git-common-dir)/config"`,
		`cat "$(pwd)/a.txt"`,
		`for f in "$(pwd)/a.txt"; do cat "$f"; done`,
		`case "$(pwd)" in *) echo x;; esac`,
		`FOO=$(pwd) echo hi`,
	} {
		file := mustParse(t, src)
		if nodes := countCmdSubstNodes(file); nodes != 1 {
			t.Fatalf("%q: want exactly 1 CmdSubst node, got %d", src, nodes)
		}
		cmds, err := extractSimpleCommands(file, root, defaultVarResolver(), rc)
		if err != nil {
			t.Fatalf("%q: extract failed: %v", src, err)
		}
		for _, sc := range cmds {
			if len(sc.args) > 0 && (sc.args[0] == "pwd" || sc.args[0] == "git") {
				t.Errorf("%q: an anchor substitution was descended into (emitted %v)", src, sc.args)
			}
		}
	}

	// Behavioral: the anchors keep resolving to an ALLOW in every word position.
	for _, src := range []string{
		`cat "$(git rev-parse --show-toplevel)/a.txt"`,
		`cat "$(pwd)/a.txt"`,
		`R=$(git rev-parse --show-toplevel); cat "$R/a.txt"`,
		`R="$(git rev-parse --show-toplevel)"; cat "$R/a.txt"`,
		`export R=$(git rev-parse --show-toplevel); cat "$R/a.txt"`,
		`for f in "$(git rev-parse --show-toplevel)/a.txt"; do cat "$f"; done`,
		`arr=( "$(git rev-parse --show-toplevel)/a.txt" ); echo x`,
		`[[ -f "$(git rev-parse --show-toplevel)/a.txt" ]] && echo x`,
		`case "$(pwd)" in *) echo x;; esac`,
		`FOO=$(pwd) echo hi`,
	} {
		wantBucket(t, classifyBash(src, ev), BucketAllow, "anchor keeps allowing: "+src)
	}

	// An anchor that cannot RESOLVE is not an anchor here either: with no
	// repoContext, `$(git rev-parse --show-toplevel)` is an ordinary substitution
	// and the descent grades it like any other.
	file := mustParse(t, `cat "$(git rev-parse --show-toplevel)/a.txt"`)
	cmds, err := extractSimpleCommands(file, root, defaultVarResolver(), nil)
	if err != nil {
		t.Fatalf("extract failed: %v", err)
	}
	if countGraded(cmds, "git") != 1 {
		t.Errorf("an UNRESOLVABLE anchor must be graded like any other substitution; emitted %v", cmds)
	}
}

// --- 6. dynamic tokens in established flag-value positions -----------------------

// TestGhDynamicFieldValueDoesNotDeny_225 pins the scoping of the non-static-argv
// precondition. The ordinary GraphQL chain — capture a node ID, feed it to the
// next mutation — could not be scripted at all, because a deny has no escape
// hatch; the only route through was to paste opaque node IDs as literals, which
// is strictly harder for a human to review than the variable-carrying form.
func TestGhDynamicFieldValueDoesNotDeny_225(t *testing.T) {
	const addItem = `gh api graphql -f query='mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id}}}' -F p=PVT_x -F c=I_y`
	wantBucket(t, classifyCmd(t, addItem, false), BucketAllow, "static allow-listed graphql mutation")

	// The same call with the item id carried in a variable must not DENY.
	dyn := classifyCmd(t, `gh api graphql -f query='mutation($i:ID!){clearProjectV2ItemFieldValue(input:{itemId:$i}){projectV2Item{id}}}' -F itemId=$ITEM`, false)
	if dyn.Bucket == BucketDeny {
		t.Errorf("a dynamic field VALUE must not deny; got DENY (%s)", dyn.Reason)
	}
	wantBucket(t, dyn, BucketAllow, "dynamic field value on an allow-listed mutation")

	// Output-shaping flags shield their value too.
	wantBucket(t, classifyCmd(t, `gh api graphql -f query='query{viewer{login}}' --jq $JQ`, false),
		BucketAllow, "dynamic --jq value")

	// A dynamic token that could still land on the noun, verb, endpoint, or a
	// value-taking global keeps the deny.
	for _, cmd := range []string{
		`gh $NOUN view 1`,
		`gh issue $VERB 1`,
		`gh api $ENDPOINT`,
		`gh issue comment 1 -R $TARGET --body hi`,
		`gh api graphql -f query=$DOC`,
		`gh api graphql -f query='query{viewer{login}}' -F $KEY=v`,
		`gh api graphql -f query='query{viewer{login}}' -F"$KEY"=v`,
		`gh api repos/o/r -H $HDR`,
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketDeny, "classification-bearing dynamic token: "+cmd)
	}

	// git and aws are unchanged: their argv is classification-bearing end to end.
	wantBucket(t, classifyCmd(t, `git $OP --hard`, false), BucketDeny, "git keeps the whole-argv deny")
	wantBucket(t, classifyCmd(t, `aws s3api $OP --bucket b`, false), BucketDeny, "aws keeps the whole-argv deny")
}

// --- 7. sed / awk program text is not a path ------------------------------------

// TestReadTrackOperandGrammar_225 pins the read track's per-program operand
// grammar. A `sed` range address earned the cross-repo DENY purely because its
// leading `/` made it look absolute — a guardrail agents had already memorized a
// workaround for, which is a guardrail enforcing nothing.
func TestReadTrackOperandGrammar_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	libDir := filepath.Join(root, "plugins", "issues", "skills", "lib")
	if err := os.MkdirAll(libDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(libDir, "issue.md"), []byte("# x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	sib := canonicalize(sibling)

	ev := bashEvIn(t, root, "pr-reviewer")

	for _, cmd := range []string{
		`sed -n '/Field-value read by kind/,/^## /p' plugins/issues/skills/lib/issue.md`,
		`sed -n '/^## Output/,$p' plugins/issues/skills/lib/issue.md`,
		`awk '/^## /{p=1} p' plugins/issues/skills/lib/issue.md`,
		`awk -v n=1 '/^## /{print n}' plugins/issues/skills/lib/issue.md`,
		`grep -n '/Field-value/' plugins/issues/skills/lib/issue.md`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, "program text is not a path: "+cmd)
	}

	// A genuine path operand alongside the script is still contained.
	for _, cmd := range []string{
		`sed -n '/x/p' ` + filepath.Join(sib, "issue.md"),
		`awk '/x/{print}' ` + filepath.Join(sib, "issue.md"),
		`grep -n '/x/' ` + filepath.Join(sib, "issue.md"),
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketDeny, "a real operand is still contained: "+cmd)
	}

	// The script supplied by -e/-f means EVERY non-flag operand is a file, so an
	// escaping one still denies.
	wantBucket(t, classifyBash(`sed -n -e '/x/p' `+filepath.Join(sib, "issue.md"), ev), BucketDeny,
		"-e script: the remaining operand is still a contained file")
}

// TestReadTrackFileFlagValuesAreContained_225 pins the boundary of that grammar.
// What an operand grammar may drop is a pattern, a script or a number — never a
// file the utility OPENS. `grep -f`, `sed -f` and `awk -f` all name a file the
// program reads, and diff/wc/sort/realpath carry path-valued flags whose GLUED
// spelling the plain non-flag walk drops (the token begins with `-`) while the
// separate-token spelling of the same command is contained. Both shapes are
// containment holes: the value escapes the repo and the command allows.
func TestReadTrackFileFlagValuesAreContained_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	for _, name := range []string{"README.md", "a.txt", "b.txt", "patterns.txt", "script.sed", "prog.awk", "exclude.txt", "list.txt"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	sib := canonicalize(sibling)
	out := filepath.Join(sib, "patterns.txt")

	ev := bashEvIn(t, root, "pr-reviewer")

	// A path-valued flag pointing outside the repo denies, in every spelling
	// getopt gives it — which is the whole set for these programs.
	for _, cmd := range []string{
		`grep -f ` + out + ` README.md`,
		`grep -f` + out + ` README.md`,
		`grep --file ` + out + ` README.md`,
		`grep --file=` + out + ` README.md`,
		`grep -rf ` + out + ` .`,
		`sed -n -f ` + out + ` README.md`,
		`sed -n --file=` + out + ` README.md`,
		`awk -f ` + out + ` README.md`,
		`awk -i ` + out + ` '{print}' README.md`,
		`diff -X ` + out + ` a.txt b.txt`,
		`diff -X` + out + ` a.txt b.txt`,
		`diff --exclude-from=` + out + ` a.txt b.txt`,
		`diff --from-file=` + out + ` b.txt`,
		`diff -S` + out + ` a.txt b.txt`,
		`wc --files0-from ` + out,
		`wc --files0-from=` + out,
		`sort --random-source=` + out + ` a.txt`,
		`sort -T` + filepath.Join(sib, "tmp") + ` a.txt`,
		`realpath --relative-to=` + sib + ` a.txt`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketDeny, "an escaping flag value is contained: "+cmd)
	}

	// The in-repo counterpart of each still allows — containing the value must
	// not cost the ordinary form its allow.
	for _, cmd := range []string{
		`grep -f patterns.txt README.md`,
		`grep -fpatterns.txt README.md`,
		`sed -n -f script.sed README.md`,
		`awk -f prog.awk README.md`,
		`diff -Xexclude.txt a.txt b.txt`,
		`diff --exclude-from=exclude.txt a.txt b.txt`,
		`wc --files0-from=list.txt`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, "in-repo flag value: "+cmd)
	}

	// A flag value that names no file is still not tested as a path, which is
	// what the operand grammar is for.
	for _, cmd := range []string{
		`grep -e '/etc/passwd' README.md`,
		`awk -v p=/etc/passwd '{print p}' README.md`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, "a non-path flag value is not a path: "+cmd)
	}

	// The write track carries the same rule for the one path-valued flag it
	// models: a `sed -i` script READ from outside the repo denies even though
	// every write target is contained, and the in-repo script still allows.
	wantBucket(t, classifyBash(`sed -i -f `+out+` README.md`, ev), BucketDeny,
		"sed -i reading an out-of-repo script")
	wantBucket(t, classifyBash(`sed -i -f script.sed README.md`, ev), BucketAllow,
		"sed -i reading an in-repo script")
}

// TestPathValueFlagsAreDeclaredValueFlags_225 is the structural guard on the two
// tables: pathFlagValues finds a value only for a flag its walk knows to be
// value-taking, so a pathValueFlags entry missing from valueFlags would be
// silently inert — the exact failure this class is about.
func TestPathValueFlagsAreDeclaredValueFlags_225(t *testing.T) {
	for prog, spec := range readOnlyUtilities {
		for flag := range spec.pathValueFlags {
			if !spec.valueFlags[flag] {
				t.Errorf("read track %q: pathValueFlags has %q but valueFlags does not", prog, flag)
			}
		}
	}
	for prog, spec := range inRepoWriters {
		for flag := range spec.pathValueFlags {
			if !spec.valueFlags[flag] {
				t.Errorf("write track %q: pathValueFlags has %q but valueFlags does not", prog, flag)
			}
		}
	}
}

// --- 8. a parse error is a syntax error, not a decision --------------------------

// TestParseErrorDenies_225 pins the one class where the gate's VERDICT was right
// and its RESPONSE was the defect. The command really is unparseable; real bash
// rejects the identical string. Approving runs a command bash will refuse, and a
// PreToolUse hook fires on commands the MODEL authored — a human cannot repair
// syntax by clicking Yes.
func TestParseErrorDenies_225(t *testing.T) {
	const backtick = "grep -n \"convention\\|doesn't match\\|does not match\\|B` empty\\|empty\" plugins/sdlc/agents/pr-reviewer.md"
	d := classifyCmd(t, backtick, false)
	wantBucket(t, d, BucketDeny, "unescaped backtick inside a double-quoted string")

	// The reason must be actionable: the parser's own position, the named cause,
	// and none of the advice that does not help.
	for _, want := range []string{"1:", "unescaped `", "double-quoted"} {
		if !containsSubstr(d.Reason, want) {
			t.Errorf("the parse-error deny must mention %q; got %q", want, d.Reason)
		}
	}
	for _, unwanted := range []string{"Simplify the command", "run its parts separately", "fail-closed"} {
		if containsSubstr(d.Reason, unwanted) {
			t.Errorf("the parse-error deny must not carry %q; got %q", unwanted, d.Reason)
		}
	}
	// The same class-level guard the other agent-facing reasons carry.
	if trackerRefInReason.MatchString(d.Reason) {
		t.Errorf("the parse-error deny must not carry a tracker pointer; got %q", d.Reason)
	}

	// The other recognizable classes each name their own cause.
	for _, tc := range []struct{ cmd, want string }{
		{`echo 'unterminated`, "single quote"},
		{`echo "unterminated`, "double quote"},
		{`echo $(foo`, "command substitution"},
		{`echo ${foo`, "parameter expansion"},
		{`( echo hi`, "parenthesis"},
		{`{ echo hi`, "brace"},
	} {
		got := classifyCmd(t, tc.cmd, false)
		wantBucket(t, got, BucketDeny, "parse error: "+tc.cmd)
		if !containsSubstr(got.Reason, tc.want) {
			t.Errorf("%q: reason should name %q; got %q", tc.cmd, tc.want, got.Reason)
		}
	}

	// An unrecognized parse-error class still denies, carrying the parser's
	// position without a fabricated cause.
	unknown := classifyCmd(t, "if true; then", false)
	wantBucket(t, unknown, BucketDeny, "unrecognized parse-error class")
	if !containsSubstr(unknown.Reason, "not valid shell syntax") {
		t.Errorf("an unrecognized parse-error class must still read as a syntax error; got %q", unknown.Reason)
	}
}
