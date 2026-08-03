---
name: guardrails-permgate-docs-locality
description: Where permission-gate classifier behavior is documented, and the two recurring stale-count defects found there (PR #114 sweep)
metadata:
  type: project
---

The `permission-gate` hook's classification behavior (Engine A command
classifier, dangerous git/gh/aws tiers, Engine B containment) lives
almost entirely in its own
`plugins/guardrails/hooks/permission-gate/README.md`. That README is
long, prose-dense, and kept current by the developer/fixer as part of
each classifier PR (e.g. #64, #113 both landed with the README's
relevant paragraph already rewritten before doc-updater ran). No other
markdown in the repo describes gate *behavior* — sibling docs
(`plugins/block-background-agents/README.md`,
`plugins/guardrails/rules/scratch-file-location.md`, top-level
`README.md`) reference the gate only by name/existence, same pattern as
[[project_github-setup-docs-locality]].

The in-code Go doc comments (`rules.go`, `gh_api_gate.go`) are also
kept meticulously current by the developer — dense, accurate,
cross-referenced to issue numbers. By the time doc-updater runs, expect
the substantive doc work to already be done; the value-add pass is
verifying accuracy (read the doc comment against the actual function
body) and a writing-style sweep, not drafting new prose.

**Two "N-before-list" defects found and fixed during the #113 sweep**
(pre-existing, not introduced by #113, but this file was already open
for editing so the sweep rule applied): "Four bypass gates fire BEFORE
per-command logic" immediately before a `(1)(2)(3)(4)` list, and "Two
refinements (#247): (1) ... (2) ..." same pattern. Both fixed by
dropping the leading count word ("Bypass gates fire...", "Refinements
(#247): (1)..."). Distinguish from the *acceptable* "the two
owner-decision deviations" phrase a few paragraphs later in the same
file — that one refers back to a pair of named, already-stated ASK
outcomes as a parenthetical aside, not introducing a fresh adjacent
list, so it stayed.

**How to apply:** on a future guardrails/permission-gate PR, don't
assume the README needs new prose — check first whether the developer
already rewrote the relevant paragraph (grep the PR diff for the
README path). Do re-grep the whole README for `\(1\)|(Two|Three|Four)[ ]`
style count-before-list patterns while the file is open, since this
class of defect keeps surfacing and the sweep-the-class rule applies to
the whole file once you're editing it, not just the touched paragraph.

**Lowercase count defects survive the capital-letter grep:** the
`(Two|Three|Four)[ ]` grep in "How to apply" only catches
sentence-initial forms; the ones that keep surviving are mid-sentence
and lowercase, shaped like "closed allowlist of **five**
process-environment-derived variables — `$HOME`, `$USER`, …",
"EXACTLY one of **three** command substitutions — `$(git rev-parse
…)`, …", and "for the **three** tools whose remote operations
…(`git`/`gh`)…(`aws`)". Grep case-insensitively
(`grep -inE "\b(two|three|four|five) [a-z-]+"`) and fix each by
dropping the numeral. The case-insensitive grep also surfaces the
recorded exception above — "the two owner-decision deviations" is
deliberate and must stay, so re-read this entry before removing a hit
that refers back to already-stated items instead of introducing a
list.

**The README's own opening line was a surviving defect (#193, PR #208):**
"Two engines feed the allow/deny/ask (plus defer) decision…"
sits immediately above the Engine A / Engine B bullet list — line 11,
the first prose in the file, and it survived every earlier sweep
because the `\b(two|three|…) [a-z-]+` grep hits it and the eye reads it
as a definitional statement rather than a list intro. It is one
(fixed to "The gate's engines feed…"). Treat a grep hit on line 11 as a
real defect, not the recorded "the two owner-decision deviations"
exception. Same class shows up in Go comments the developer writes for
carve-out switch arms ("Two carve-outs that both DEFER…" above
`case claudeConfig, harnessScratch:`); sweep the changed `.go` files'
comments for it too, not just the Markdown.

**Slash-joined classifier lists are a claim class of their own (#193,
PR #208):** the fixer wrote "The `git`/`gh`/`aws`/`acli` classifiers
keep their own unconditional redirect-to-file `ask`". Three of the four
do; `classifyAcli` gates its read-only allow on `sc.allowEligible()`,
so a redirect there **defers**. The lumping is seductive because those
four are always named together elsewhere in the file (the classifier
dispatch, the bypass-gate paragraph), so the habit of writing them as
one slash-joined group survives into a sentence where they diverge.
Verify each name in a slash-joined list against its own classifier
function, not against the group. Same round: when a helper stops being
the gate on a track (`allowEligible()` is no longer called by
`classifyReadOnlyUtility` / `classifyInRepoWrite`, which now ask
`redirectVetoesAllow`), the helper's own doc comment still describes
the old universality — grep the helper's remaining production callers
(`grep -n 'helperName()' *.go | grep -v _test`) and make the comment
say which tracks still use it.

**Allowlist-extension PRs are the "already current" class
(#209, PR #222):** adding entries to `ghGraphQLMutationAllowlist` (the clear verbs
`deleteIssueFieldValue` / `clearProjectV2ItemFieldValue`) landed with the
README's #195 allowlist paragraph and the map's own Go doc comment both
already rewritten, and nothing else in the repo enumerates the allowlist
— `rules.go`'s references say "curated issue-metadata allowlist" without
listing members, and the issues plugin's SKILL.md /
`skills/lib/issue.md` mentions of `setIssueFieldValue` /
`updateProjectV2ItemFieldValue` are that plugin's own GraphQL templates,
untouched by gate policy. So a pure allowlist add has zero doc-updater
work: verify the README paragraph and the map comment, grep the verb
names repo-wide to confirm no second enumeration exists, run the
count-before-list sweep, and stop. Contrast the #156/#132 counterexamples
below — Engine A *static-resolution* changes do reliably need new README
prose.

**A big README pass by the developer is the HIGH-risk case, not the
low-risk one (#225, PR #227).** The developer rewrote ~150 README lines
across eight classifier changes, and the prose was authored in the same
commit as the code by the agent grading its own claims. What survived
was a false *reach* claim ("the walk descends into every process
substitution") covering a genuine widening; probe such claims rather
than reading the walk — see
[[feedback_probe-the-gate-binary-not-the-walk]]. Second recurring shape
in the same pass: a scoping mechanism spelled in the code as an
ALLOWLIST, described in the README as an *enumeration of the positions
it does not cover*. Those read as equivalent and are not — the allowlist
is closed and the enumeration invites "my flag isn't listed, so it's
safe". Reword to match the code's polarity.

**The fix round re-wrote the same false reach claim one notch
narrower (#225, PR #227, round 2).** Closing the redirect-position gap,
the fixer replaced "descends into every process substitution" with "the
descent covers both positions bash accepts a substitution in" — still
false: a substitution in a `for`/`select` item list or a `case` word
reaches neither call site, so `for f in <(cat ../sibling/.env)` ALLOWs.
The pattern to expect: a completeness claim written from the two call
sites the author just wired, not from the grammar. When a gap is closed,
re-probe the OTHER positions the same token can occupy before letting
any "covers both/all" phrasing stand — a closed gap invites a stronger
claim than was earned. Round 3 ended the loop by making the claim
structural rather than enumerated: the descent takes a NODE and finds
substitutions with `syntax.Walk`, so those `for`/`select`/`case` rows
now DENY and the README's reach sentence is checkable against one
mechanism instead of a call-site list.

**Round 3's replacement claim was the SAME defect one class over
(#225, PR #227, round 3).** Having closed the `<(…)` reach, both the
README and the `descendProcSubsts` doc comment justified the two
constructs still unreached — an unquoted `${Q:-<(cmd)}`, and a `$(…)`
body outside a declaration clause's assignment RHS — with "not an
allow-track hole, the word is inexact". Probing refutes it: inexactness
stops the allow track only where the inexact word rides a command the
walk EMITS. A `for`/`select` item list, a `case` subject word or
pattern, and a `VAR=… cmd` prefix emit no command of their own, so
nothing carries the inexactness and the line allows on its remaining
parts — `for f in $(cat ../sib/.env); do echo x; done`,
`case $(…) in`, `FOO=$(…) echo hi`,
`for f in ${Q:-<(cat ../sib/.env)}; do echo x; done`, and even the
substitution-free `for f in ${UNSET}x` all ALLOW, identically at the
merge base (pre-existing, not this PR's widening). Generalize the
lesson: **"inexact, so it cannot ride the allow track" is a claim about
a word's POSITION, not about the word.** Probe it in a non-emitting
position before letting it stand, exactly as
[[feedback_probe-the-gate-binary-not-the-walk]] prescribes for reach
claims. The `sdlc-pr-reviewer` reference note on this PR still carries
the false version — memory is the scrubber's to fix, not doc-updater's,
so report it rather than editing it.

Also, the classifier-behavior locality claim in the repo's `CLAUDE.md`
has one real exception: `.claude/agent-memory/` notes teach agents to
route around gate verdicts and are silently falsified when a verdict
changes (#225 had to delete two). doc-updater must not curate them, but
must know they exist as a surface.

**Gate PACKAGING facts are the exception to the locality rule above.**
The `CLAUDE.md` trigger for that sweep was narrowed in PR #227: it used
to fire on any touch of `plugins/guardrails/hooks/bin/`, which every
classifier PR does. It now fires on a change to the packaging *shape*
(which `<goos>-<goarch>` dirs exist, `hooks.json` selection/fail-closed
logic, the build recipe); a plain in-place rebuild mirrors nothing and
needs no claude-vm edit or version bump.

The "no other markdown describes gate behavior" claim holds for
*classifier* behavior only; how the gate is *shipped* is mirrored in
claude-vm's docs, and the cross-plugin sweep obligation that creates
lives in the repo's `CLAUDE.md`. The claude-vm config-WIZARD skills
(`claude-vm-config-global`/`-repo`) are not among those mirroring
surfaces — they describe `claude.plugins.bake` mechanics generically and
never name guardrails — so the lag warned about in
[[project_claude-vm-config-wizard-skills-lag]] does not extend to
gate-packaging facts.

**Counterexample (#156, PR #159):** the developer landed exhaustive Go
doc comments on `engine_a_bash.go` (resolveVar, isResolvableParamExp,
literalWord, varResolver) but did NOT touch the README, even though #156
widened literalWord's variable-resolution semantics (adding a
closed $HOME/$USER/$TMPDIR/$PWD/$OLDPWD allowlist) in a way that made
an existing README sentence — "an undefined / environment variable...
stays inexact" — actively false. So the "usually already current"
pattern holds for git/gh/aws classifier tiers but not reliably for
literalWord/resolveVar-level semantics changes; always diff the
README's variable-resolution paragraph against the actual `literalWord`
doc comment when a PR touches that function, don't just grep for
whether the README path appears in the PR diff.

**Same counterexample class again (#132, PR #164):** the developer
added a command-substitution anchor allowlist (`resolveAnchorCmdSubst`,
`anchorCommands` — recognizes exact `$(git rev-parse --show-toplevel)`
/ `$(git rev-parse --git-common-dir)` / `$(pwd)`/`` `pwd` `` as an
assignment RHS) with dense, accurate Go doc comments on every new
function, but again did NOT touch the README. This is a sibling
mechanism to the #156 five-variable allowlist, not a variant of it — the
README needed a new paragraph distinguishing "resolves bare variable
references" (#156) from "resolves specific command-substitution forms"
(#132), inserted right after the #156 paragraph it sits beside. Confirms
the rule from the #156 entry above generalizes: any PR that adds a new
*recognized form* to Engine A's static-resolution machinery (variable
allowlist, anchor allowlist, whatever comes next) needs its own README
paragraph even when the Go comments are already complete — check by
grepping the README's variable/anchor-resolution paragraph for the new
mechanism's name, not just whether the README path is in the PR diff.
