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
[[project_github-setup-docs-locality]]. The repo's `CLAUDE.md` holds
the authoritative version of this locality claim, including the
`plugins/guardrails/rules/scratch-file-location.md` sibling and the
`.claude/agent-memory/` exception; read it there rather than trusting a
copy here. What it does not say is *why* that rule file rots: the
developer never updates it, because the code change is in the gate
while the rule file is prose about agent habits. The memory-tree
exception has a doc-updater-specific rider too — those notes are a
surface you must know about and must not curate.

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

**On a gate PR the residue is never the mechanism paragraph — it is a
JUSTIFICATION sentence.** Six consecutive rounds of #229 (PR #232) each
found the README, the Go comments and even the structural counts
already correct, and each false claim was a sentence saying why
something was left out, narrowed, or safe. The recurring shapes, all
worth one probe before they stand:

- **"Out of scope because the OTHER track already covers it."** That is
  a claim about the other track's code: read it, and probe the exact
  form it names. `gh api -X GET -F q=@/etc/passwd repos/o/r` ALLOWs
  (classifyGhAPI's explicit-GET carve-out falls through to the REST
  allowlist) while the graphql `-F query=@file` form DENIES, so "every
  `gh api` form carrying a body already asks" was false in both
  directions. The same sentence lumped `-f`/`-F` as doing `@file`
  expansion when only `-F`/`--field` and `--input` do.
- **A slash-joined flag pair.** Split it and probe each spelling: the
  shield table and the per-verb spec table name flags in DIFFERENT
  spellings, so a pair copied from one is wrong in the other. On
  `gh pr create`, `--template $X` asks (shielded AND a path flag),
  `-t $X` allows (`-t` is that verb's `--title`) and `-T $X` denies at
  the non-static-argv precondition. A shield claim needs the same
  probe: gh FIELD flags shield a dynamic value only when the `key=` is
  pinned, so `gh pr comment -F $BODY` denies.
- **A blanket predicate over a list of verbs** — "each requires an
  explicit `-` or a filename" — is
  [[feedback_no-blanket-predicate-over-a-list]] again; `gh <verb>
  --help` is the cheap check for any claim about upstream gh grammar.
  But it settles only what gh DOCUMENTS. Round 10 found the in-tree
  prose that came out of this bullet — "`gist edit` takes its file as a
  positional with no stdin spelling of its own" — false: cli/cli
  v2.97.0's `edit.go` binds `opts.SourceFile = args[1]` and switches
  `case src == "-"`, so `gh gist edit <id> - < /etc/passwd` reads the
  file (the gate denies it, the `-` substitution being
  origin-agnostic). Help renders only `[<filename>]`. For a NEGATIVE
  claim about a verb's grammar, read the verb's `RunE` — same rule as
  the implicit-stdin default on `gist create`.
- **A doc comment naming the test that asserts an invariant.** Grep the
  name: `TestGhFileSpecsAreWellFormed` did not exist.
- **"The whole vocabulary / every form gh's help renders."** Settle it
  by dumping help for every pair in the table, INHERITED FLAGS
  included — that block is per-verb too, giving `--help` on all 26
  modelled pairs but `-R`/`--repo` on only 24, since a gist is not a
  repo resource and the gate folds the pair into every spec regardless.
- **A quoted USAGE line.** Each spec's `filePositionalsFrom` is
  justified BY that quote, so an abridged one is a live defect: gh
  2.97.0 renders `[<tag>]` optional and offers a `<pattern>`
  alternative, and dropping either removes exactly the fact a reader
  checks. Dump `gh <noun> <verb> --help | sed -n '/^USAGE/,/^$/p'` per
  verb with a file positional. The behavior was fine — a `<pattern>`
  reaches the gate as one word and containment resolves its escaping
  prefix without expanding it — but nothing said so, which is the gap
  the abridged quote created.

Dump gh help from a scratchpad SCRIPT, not inline: the gate blocks
`gh "$noun" "$verb"` as non-static argv.

**A mechanism-narrowing round leaves a self-contradicting file.** A
fixer greps for the paragraph it remembers writing, not for every
restatement, so expect a file header still asserting "extracts a flag's
value in every spelling" twenty lines above "the one spelling it does
not cover". Grep the changed `.go` for the helper's own name AND for
the phrase the round narrowed ("every spelling", "COMPLETE", "all
three", "taken from") — with a whole-file `perl -0777` slurp rather
than a line-oriented grep, because the phrase wraps across two `//`
lines and a line grep misses exactly the copy that matters. Sites that
reliably survive two consecutive sweeps: the thin WRAPPER above the
callee that was just scoped (`pathFlagValues` over
`pathFlagValueRefs`, and the wrapper is the half with the callers), the
field docs of the maps handed to it (`inRepoWriteSpec.pathValueFlags`),
the README's paragraph for the OLDER track, and a test-table comment.
Grade every hit rather than only the named ones, and pass the ones
already scoped: a claim that names its own parser ("in every spelling
gh accepts") or enumerates the spellings right after itself carries no
defect. Scope such a sentence to its parser (getopt vs pflag) at the
helper itself. Sibling check when a comment states what a loop
established about earlier iterations: list the maps the loop actually
consults — a `continue` on "not in map A" proves nothing about map B.

**When a gate PR grades a NEW CLASS OF PATH, the doc work is one level
up.** Expect the README, the Go comments and the counts to be current;
ask instead which prescriptive rule file tells agents where to put that
path — a body file, a redirect target, an upload operand. A track that
changes which destinations are safe for agent scratch falsifies
`plugins/guardrails/rules/scratch-file-location.md` and `CLAUDE.md`'s
locality claim, and the developer edits neither.

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

**When a round moves verdicts, the residue is in the tier function the
round did NOT touch (#229, PR #232, round 6).** Alias resolution ran
upstream of every tier, and the new file plus the README paragraph were
both accurate. What was false sat in `ghIrreparableDeny`'s own doc
comment, untouched since #64: it billed the function as covering
"release/gist publish" (publish is an ASK in `classifyGh`, not in that
function at all) and claimed "an unrecognized secret/variable/ruleset
subcommand denies (fail closed)" when the `ruleset` arm denies `delete`
alone — `gh ruleset bogus` asks. A summary sentence at the top of a
DENY-tier function is where a tier list rots, because nobody rereads it
when the tier next to it changes. When a round moves rows into or out
of a tier, read that tier's function comment end to end against its own
switch.

**An alias-resolution round is a diagnostic-detail change too.** Every
message downstream quotes the CANONICAL spelling, so `gh secret remove
FOO` is refused as `'gh secret delete'`, `gh pr co 1` asks about
`'gh pr checkout 1'`, and even the fail-closed ask echoes `'gh repo
create foo'` for a typed `gh repo new foo`. Nothing said so on either
doc surface; an agent grepping a deny reason for the words it typed
finds nothing. Same class as
[[feedback_diagnostic-detail-claims]] — check what the message STRING
interpolates after any rewrite of the tokens it is built from.

**A verdict-move COUNT is checkable without reproducing the cross it
was taken over (#229, PR #232, round 9).** The surfaces reported "24
rows move" over a 1,295-row bare `gh <noun> <verb>` cross, and the
cheap check is not to rebuild that cross but to ask which rows the
change can possibly move — for an alias round, `ghCanonicalCommand`
returns its input unchanged unless the noun or verb is an alias, so only
alias-touching rows can move at all — and the moving set is INVARIANT to
how wide the cross is. Extract main and the tip with
`git archive … | tar -x`, drop one `zz_docprobe_test.go` into both that
crosses the tables and writes `cmd<TAB>bucket`, and `paste`/`awk` the
two files. My own 37×34 reconstruction of the same five table families
(alias, read, recoverable-write, file-spec, deny) totals 1,258 rather
than 1,295 — one verb short, never identified — yet reproduced the 24
and every sub-count exactly. So a stated total whose derivation a reader
cannot re-run is worth flagging, and #232 round 11 settled it the right
way round: that round had to re-measure anyway (the total moved 24 → 25),
so it replaced the unreproducible 1,295 with the 1,258 cross AND the
derivation that generates it, then re-ran a deliberately WIDER 39×39 =
1,521 superset which moved exactly the same 25 rows. That is the shape
to ask for — not a swapped number, but a stated derivation plus a
second measurement at a different width. Do not "fix" a total to your
own number in a round that is not re-measuring: the load-bearing figure
is the moving set, and it survives the disagreement.

**Re-derive the "can possibly move" argument every round; it is scoped
to that round's change, not to the sentence (rounds 10 and 11).** The
tier decomposition under that same total is the part that rots. Round 10
made every `gh gist create` an ASK, which moves a BARE row on a
non-alias tier, so the parenthetical "no operands and no flags, so
resolution is the only tier that can move one" went false while the
total stayed 24 (20 ask → allow, 2 deny → allow, 1 ask → deny, 1
allow → ask) and hid it. `gh gist new` is where those two rounds meet:
it stopped moving, so the `new` sub-count went 3 → 2. Round 11 then put
every `gh gist edit` on the same publish tier, and that one DID move the
total: 25 rows, with allow → ask going 1 → 2. When a round changes a
verb the count sentence names anywhere — including inside a sub-count's
parenthetical — replay the cross rather than reasoning that the total
looks unchanged, and equally rather than reasoning that it must have
changed.

**A TIER-WIDENING round falsifies the worked examples of every OTHER
mechanism that shares the verb (#229, PR #232, round 12).** Rounds 10
and 11 put every `gh gist create` and `gh gist edit` on the publish ASK.
Every paragraph *about* those tiers was rewritten correctly, the counts
re-measured correctly, and the residue was sixty lines away in the
`<pattern>`-operand paragraph, which had picked `gist create` as its
worked example of the CONTAINED half back when a secret gist was a
recoverable write: "`gh release create v1 '../sib/*.tgz'` **denies**
while `gh gist create '*.md'` **allows**". The escaping half still held;
only the contained half moved, and it moved to ask. The generalization:
when a verb changes TIER, grep for the verb across the whole file and
grade every example it appears in, not just the paragraphs about the
tier — a verb is a popular example precisely because it is short, so it
gets borrowed by paragraphs about unrelated mechanisms, and those
paragraphs are never in the round's diff. The identical sentence sat in
`classify_gh_files.go`'s `ghFileSpec` doc comment, wrapped so that
`allows` was alone on its own `//` line — a line grep for
"gist create.*allows" finds neither copy. Slurp comment BLOCKS
(join every run of `//` lines, then match) rather than lines.

Cheap settling method for a contained-half claim once a verb is on an
ask tier: there is usually no allow row left to point at. Say what the
verdict is NOT ("is not denied for a path the gate could not expand")
and then where it lands, rather than hunting for a different verb whose
allow survives — swapping the example verb silently changes which
mechanism the sentence demonstrates.

**Grade a whole README mechanically, not by reading (#232, round 12).**
Slurp the file with the newline+indent collapsed, regex every
`` `gh …` `` span, take the nearest verdict word after it, drop the
rows carrying a `<placeholder>`, and replay the rest through the built
binary. That turned ~44 quoted examples into one probe run and found
the one false row without depending on which paragraph caught the eye.
The heuristic's false positives are all the same shape — a verb
fragment quoted mid-sentence picks up an unrelated verdict word — and
are cheap to discard by eye once the concrete rows are settled.

**The count derivation is now re-runnable, so re-run it rather than
trusting the figure.** `37 × 34 = 1,258` reproduces exactly from the
stated union (`isGhReadOnly`'s two literals, `ghRecoverableWriteVerbs`,
`ghFileSpecs`, both alias tables, and the
`delete`/`rename`/`transfer`/`set` verbs), and the wider `39 × 39 =
1,521` from that noun set plus `auth`/`api` and the five auth verbs.
Both moved the same 25 rows against main. Cost: two `git archive |
tar -x` extractions, one throwaway dump test, one `go build` per side,
and a python replay — well under the cost of reasoning about whether a
total "should" have moved.

**The residue in a count-fixing round is the CLOSURE sentence.** When
prose enumerates a set and then says why the set is complete ("the
list is closed at five because `gist create` has exactly two
value-taking flags, in two spellings each"), do the arithmetic against
the list right above it: two flags × two spellings is four, and the
fifth member — an operand after `--` — had no justification at all.
Same sentence carried a mechanism blanket over the same list ("pflag
gives that token to the preceding flag"), false for the `--` member,
which has no preceding flag. Both survived the round that wrote them
because the enumeration itself was measured and correct. Grade a
"closed because" clause member by member, exactly as
[[feedback_no-blanket-predicate-over-a-list]] prescribes.
