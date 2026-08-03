package main

import (
	"os"
	"path/filepath"
	"testing"
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

	// An escaping destination still escalates, and the reason names clobber and
	// escape rather than exfiltration.
	esc := classifyBash("gh pr diff 224 > "+filepath.Join(sib, "x.diff"), ev)
	wantBucket(t, esc, BucketAsk, "redirect escaping to a sibling repo")
	if !containsSubstr(esc.Reason, "clobber") {
		t.Errorf("the escape ask must name clobber; got %q", esc.Reason)
	}
	if containsSubstr(esc.Reason, "exfiltrate") {
		t.Errorf("the escape ask must not claim exfiltration for a local file write; got %q", esc.Reason)
	}

	// A destination the gate cannot pin statically still escalates, and so does
	// one under .git/.
	wantBucket(t, classifyBash("gh pr diff 224 > $DEST", ev), BucketAsk, "unpinnable redirect destination")
	wantBucket(t, classifyBash("gh pr diff 224 > .git/x", ev), BucketAsk, "redirect into .git/")

	// EVERY destination must qualify: one good and one escaping still asks.
	wantBucket(t, classifyBash("gh pr diff 224 > .claude/tmp/x.md 2> "+filepath.Join(sib, "e"), ev),
		BucketAsk, "mixed redirect destinations")
}

// TestCredentialedRedirectToScratchpadAllows_225 covers the second blessed
// destination: the harness scratchpad the #193 carve-out designates safe by
// construction, which the ungraded veto rejected just as hard as a sibling repo.
func TestCredentialedRedirectToScratchpadAllows_225(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	ev := bashEvIn(t, root, "issue-developer")

	dst := scratchTarget(os.Getuid(), sessionSlug, sessionUUID, "scratchpad", "pr224.diff")
	wantBucket(t, classifyBash("gh pr diff 224 > "+dst, ev), BucketAllow,
		"redirect into the session scratchpad")
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
	wantBucket(t, classifyBash(`find "$(git log -1 --format=%H)/x" -type f`, ev), BucketAsk,
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
