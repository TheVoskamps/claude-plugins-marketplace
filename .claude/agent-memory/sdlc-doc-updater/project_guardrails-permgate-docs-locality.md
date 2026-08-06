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
relevant paragraph already rewritten before doc-updater ran). Almost no
other markdown in the repo describes gate *behavior* —
`plugins/block-background-agents/README.md` and the top-level
`README.md` reference the gate only by name/existence, same pattern as
[[project_github-setup-docs-locality]]. The real sibling is
`plugins/guardrails/rules/scratch-file-location.md`, which carries
verdicts wherever they decide WHERE an agent should park a scratch file
(the containment/`.git/` denies and their prescriptive wording, plus
the #225 redirect and the #229 publish read). It is the surface the
developer
never updates, because the code change is in the gate and the rule file
is prose about agent habits.

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
claims. Round 4 then closed the `$(…)` rows too (`descendCmdSubsts` takes
a NODE and runs per statement beside `descendProcSubsts`), so those rows
now DENY; the one row still ALLOWing is the PROCESS substitution inside a
parameter expansion, `for f in ${Q:-<(cmd)}`, which has no parser node to
hang a descent off. The lesson about POSITION outlives the fix — reach for
it before writing "inexact, so it cannot ride the allow track" again.

**Round 5 shape: the false claim rode a WORKED EXAMPLE, not a
quantifier (#225, PR #227).** The flag-value round's README prose was
accurate everywhere it generalized ("in every spelling", "appended,
never substituted" — both hold against `pathFlagValues`/`operands`),
and false in a parenthetical example: "a per-program operand grammar
consumed the value in both (right for `grep -e`'s pattern or `diff
-U`'s number …)". `diff` has NO `operandsFn` — only `valueFlags`/
`pathValueFlags` — so its non-path flag values fall to `pathOperands`
and ARE walked as operands; probing gives `diff -U 3 a b` allow (the
`3` contains as a relative in-repo path, not because a grammar ate it)
and `diff -I '/re/' a b` / `diff -L '/label/' a b` DENY as cross-repo
reads. **How to apply:** for every program named in a mechanism
sentence, check the table entry actually declares that mechanism —
a program can appear in the same paragraph as a grammar it does not
have. Same round, same method on the gh side: the doc comment was
stricter than the README ("the only single-dash tokens that pass are
the exact `-a` and `-h`"), and probing showed `gh auth status
-hgithub.com` asks with the SHOW-TOKEN message because the glued
value's `github.com` contains a `t`. When a Go comment and the README
describe one screen at different strictness, the comment is usually the
measured one — probe, then bring the README up to it.

**Round 6 shape: the false claim was the SCOPE JUSTIFICATION
(#229, PR #232).** A new track (grading the local files a `gh` publish
verb sends to GitHub) shipped with an accurate mechanism paragraph and
one false sentence explaining what it deliberately left out: "every
`gh api` form carrying a request body already asks for method reasons,
so there is no allow to close".
Probing refutes it — `gh api -X GET -F q=@/etc/passwd
repos/o/r` ALLOWs (classifyGhAPI's explicit-GET carve-out falls through
to the REST allowlist), and the graphql `-F query=@file` form DENIES
rather than asking. The same sentence also lumped `-f`/`-F` as doing
`@file` expansion when only `-F`/`--field` and `--input` do — the
slash-joined-list defect again, in a sentence whose whole job was to say
why the omission was safe. **How to apply:** an "out of scope because X
already covers it" sentence is a claim about the OTHER track; go read
that track's code and probe the exact form it names, exactly as for a
reach claim. Two more per-round finds worth the same reflex: a doc
comment that names the test asserting an invariant
(`TestGhFileSpecsAreWellFormed` — no such test; it is
`TestGhFileSpecsPathFlagsAreValueFlags_229`, so grep the name), and a
"reaches here rather than the precondition deny because `-F` is
shielded" claim that probing flips (`gh pr comment -F $BODY` denies —
gh FIELD flags shield a dynamic value only when the `key=` is pinned;
what reaches the new ask is `-t`/`--template`).

**Round 7 shape: the SHORT/LONG spelling of a slash-joined flag pair
(#229, PR #232, fix round).** The fixer's comment said a dynamic value
on `-t`/`--template` reaches the new publish-file ask "and on
`gh pr create` that flag names a local template FILE". Probing splits
the pair three ways: `--template $X` asks (shielded AND a path flag),
`-t $X` allows (`-t` is that verb's `--title`), `-T $X` denies at the
non-static-argv precondition (`-T` is the path flag but is absent from
`ghShieldingFlags`). The shield table and the per-verb spec table name
flags in DIFFERENT spellings, so a pair copied from one is wrong in the
other — split the pair and probe each spelling. Same round, the
"only gist create reads stdin implicitly" contrast enumerated
`pr comment`, `gist edit` and `release create` as "each require an
explicit `-` or a filename": `gh <verb> --help` settles it, and
`gist edit` documents no `-` at all (its file is the positional). That
one is [[feedback_no-blanket-predicate-over-a-list]] again, and gh's
own `--help` is the cheap check for any claim about upstream gh
grammar.

**Round 8 shape: the docs were right and the SURFACE was missing
(#229, PR #232, pflag round).** Modelling gh's pflag-only spellings
(`-F=FILE`, the unrendered `-h`, the `=` stop in both gh-local cluster
walks) landed with the README paragraph, the Go comments and even the
"26 modelled pairs" count already correct — every structural claim
checked out (`grep -c 'ghSpec('` minus the func definition = 26; `-p=f`
really would have eaten `gh gist create -p=f /etc/passwd`'s operand).
The doc work was one level up: a track that grades a NEW CLASS OF PATH
changes which destinations are safe for agent scratch, so
`scratch-file-location.md` needed the publish-read note and `CLAUDE.md`
needed its locality claim amended. **How to apply:** when a gate PR
extends grading to a path an agent chooses (a body file, a redirect
target, an upload operand), ask which prescriptive rule file tells
agents where to put that path — the README will be current and that
file will not.

**Round 9 shape: a PARTIAL prose sweep by the fixer (#229, PR #232).**
The pflag round amended two of three sibling statements about the same
helper and left the file header asserting "extracts a flag's value in
every spelling" twenty lines above "the one spelling it does not
cover". A fixer that changes a mechanism greps for the paragraph it
remembers writing, not for every restatement, so a *self-contradicting
file* is the expected residue of a mechanism-narrowing round — grep the
changed `.go` file for the helper's own name AND for the phrase the
round narrowed ("every spelling", "COMPLETE", "all three", "taken
from") and read every hit. Two neighbours carried the same residue: a
docstring calling `gh <noun> <verb> --help` the source of a flag table
that `-h` is now hand-added to, and a justification comment saying
"every character before j was a modelled bool" for a loop that consults
`valueFlags` only (an unmodelled character reaches the same branch).
The generalizable check for that last one: when a comment says what a
loop already established about earlier iterations, list the maps the
loop actually consults — a `continue` on "not in map A" proves nothing
about map B. Also worth carrying forward: a shared helper's doc comment
that says "every spelling the utility accepts" gains a NEW caller with
a different parser and becomes the belief the hole came from — scope
such a sentence to its parser (getopt vs pflag) at the helper itself.

Scoping that sentence at ONE helper is not the sweep. Round 4 of #229
found the same unqualified claim still standing on the thin WRAPPER
(`pathFlagValues`) thirty lines above the callee that had just been
scoped (`pathFlagValueRefs`) — and the wrapper is the half with the
callers, so it is the sentence every other track reads. Two more copies
sat on the field docs of the maps handed to it
(`inRepoWriteSpec.pathValueFlags`) and in the gate README's read-track
paragraph, plus one in a test-table comment. Two consecutive sweeps
each stopped at the sites they were handed. What made them stoppable: a
line-oriented `grep "every spelling"` MISSES the wrapper, because the
phrase wraps across two `//` lines — use a whole-file perl slurp
(`perl -0777` over `(every|all|any|each) ... spelling`) so wrapped
copies show up, and grade every hit rather than only the named ones.
Not every hit is a defect: a claim that names its own parser ("in every
spelling gh accepts", on the gh walk) or that enumerates the spellings
right after itself is already scoped.

**Round 10 shape: the INHERITED FLAGS block is per-verb too (#229,
PR #232).** A round that derived every enumeration mechanically from
`ghFileSpecs` still left two claims about *gh itself* wrong, because
both were checked against the verbs' own FLAGS blocks only. `gh <noun>
<verb> --help` renders a second block, and it is NOT uniform: dumping
it for all 26 modelled pairs gives `--help` on 26 and
`-R, --repo [HOST/]OWNER/REPO` on 24 — `gist create` and `gist edit`
answer both spellings with `unknown flag` (a gist is not a repo
resource), while the gate folds the pair into every spec regardless.
The same omission falsified the sibling claim that the non-`file`
annotation list was "the whole vocabulary the value-taking flags of
this table's verbs are annotated with": it dropped `file` itself and
`[HOST/]OWNER/REPO`. **How to apply:** any claim of the form "the whole
X gh's help renders" must be settled by dumping the help for every pair
in the table (a scratchpad script — the gate blocks
`gh "$noun" "$verb"` as non-static argv, so run it from a file, not
inline), and the dump must include the INHERITED FLAGS block, not just
FLAGS.

**Round 11 shape: the USAGE line is a claim surface the FLAGS sweep
misses (issue #229, PR #232).** Round 10 derived every enumeration from
the verbs' FLAGS and INHERITED FLAGS blocks and left the *positional*
grammar unaudited — yet that grammar is quoted verbatim to justify each
spec's `filePositionalsFrom`. Two of four quotes were abridged:
`gh gist create <filename>...` and `gh release create <tag>
[<filename>...]` both drop the `<pattern>` alternative gh 2.97.0
renders, and the latter promotes an optional `[<tag>]` to a required
one — exactly the optionality a reader checks when asking why index 0
is skipped. The sites had drifted apart from each other too: the
`release create` spec's own inline comment spelled `[<tag>]` right
while the type-level doc twenty lines above did not. Settle it by
dumping `gh <noun> <verb> --help | sed -n '/^USAGE/,/^$/p'` for every
verb with a file positional, from a scratchpad script (the gate blocks
`gh "$noun" "$verb"` as non-static argv). The behavior was fine — a
`<pattern>` operand reaches the gate as one word and containment
resolves its escaping prefix without expanding it, so
`gh release create v1 '../sib/*.tgz'` denies and `gh gist create
'*.md'` allows — but nothing said so, which is the doc gap the
abridged quote created.

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
never name guardrails — so the wizard-lag sweep the repo's `CLAUDE.md`
requires on a claude-vm schema or validation change does not extend to
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
