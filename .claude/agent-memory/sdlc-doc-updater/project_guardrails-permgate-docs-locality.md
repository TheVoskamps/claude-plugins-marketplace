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
did; `classifyAcli` gates its read-only allow on `sc.allowEligible()`,
so a redirect there **defers**. (The bucket word has since moved on:
in #262 the credentialed redirect became
`credentialedRedirectVerdict`, which denies a proven escape and returns
no verdict at all for a contained destination, leaving the calling
track's own terminal to govern — but the lumping lesson is the durable
part.)
The lumping is seductive because those
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

**An allowlist add whose new entry is a GENERIC verb is not the
zero-work class (#256, PR #257) — and the doc pass can overturn the
code.** The PR first added `updateIssue` alongside
`updateIssueFieldValue`, with the README paragraph and the map's Go
comment both rewritten as the #209 entry above predicts — but the
prose justified the entry by ENUMERATING what the verb sets ("type,
state, title, body, labels, assignees or milestone"), and that
enumeration is a claim about GitHub's schema, settled in one
non-mutating call:
`gh api graphql -f query='query { __type(name: "UpdateIssueInput") { inputFields { name description } } }'`.
It omitted `projectIds` and, load-bearingly, `agentAssignment` — a
Copilot target repo, base ref, custom instructions and custom agent,
a surface no narrow allow-listed verb reaches and one the
"recoverable, human-visible, reversible" basis does not cover. The
allowlist keys on the mutation FIELD name only
(`allGraphQLMutationFieldsAllowed` never looks at arguments), so the
gate could not tell that arm from a title edit, and probing an
`agentAssignment`-carrying document against the then-current binary
confirmed **allow**. The owner's ruling on that finding was to drop
`updateIssue` from the list entirely and keep only
`updateIssueFieldValue`, so the verb left the allow track again (it
ASKed at the time; #262 rebucketed it to a teaching DENY);
`updateIssueIssueType` covers the type-setting the widening was asked
for. Generalize: when an allowlist gains a verb that takes a single
generic input object, introspect the input type and grade the
justification against every arm — the narrow verbs the list was built
from have no such gap, and the finding is worth raising even though it
lands as a scope cut to the PR rather than a doc fix. Introspection is
capped at two `__Type.inputFields` uses per document; split the query
rather than aliasing three.

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
`gh "$noun" "$verb"` as non-static argv. And exclude the publishing
verbs from any such sweep — the root `CLAUDE.md` forbids invoking them
in any spelling, `--help` included. Their USAGE and flag grammar come
from the command's own registration block via
`gh api "repos/cli/cli/contents/<path>?ref=<tag>"`, which is the
parser's own input and therefore the better source regardless.

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
alone — `gh ruleset bogus` escapes to the unrecognized-`gh` residual
(an ASK when this was written; a DEFER since #262). A summary sentence
at the top of a
DENY-tier function is where a tier list rots, because nobody rereads it
when the tier next to it changes. When a round moves rows into or out
of a tier, read that tier's function comment end to end against its own
switch.

**An alias-resolution round is a diagnostic-detail change too.** Every
message downstream quotes the CANONICAL spelling, so `gh secret remove
FOO` is refused as `'gh secret delete'`, `gh pr co 1` is analysed as
`'gh pr checkout 1'`, and the unrecognized-`gh` residual echoes `'gh
repo create foo'` for a typed `gh repo new foo`. Nothing said so on
either doc surface; an agent grepping a deny reason for the words it
typed finds nothing.

Since #262 that residual DEFERS rather than asking (measured against
the branch binary: `gh pr co 1`, `gh repo new foo` and `gh ruleset
bogus` all return `defer` with operation `gh unrecognized command
(#163)`), and `emitDecision` emits a defer with no reason key at all
(#271) — so the canonical spelling now reaches only the §7 log's
`analysis` field, never the agent. The class is unchanged and the surface moved: after an alias
round, check what the message STRING interpolates *and* which channel
still carries it. The `gh secret` deny above does still show the agent
its canonical spelling; a deny is where that check pays. Same class as
[[feedback_diagnostic-detail-claims]].

**Grade a verdict-move COUNT by its DERIVATION, never by adjudicating
the total.** A gate PR that changes `classifyGh` states "N rows move"
over a `gh <noun> <verb>` cross. Successive rounds on the same PR will
each produce a different N, each honest over its own row set, and
picking the right one is effort the owner has explicitly ruled not worth
spending. What a doc pass owes the reader is only this: the sentence
states the row set AND the union that generates it, so a reader can
re-run it. A bare total with no derivation is the finding; a total that
disagrees with your own reconstruction is not.

The cheap check is not to rebuild the cross but to ask which rows the
change can possibly move — for an alias round, `ghCanonicalCommand`
returns its input unchanged unless the noun or verb is an alias, so only
alias-touching rows can move at all — and the moving set is INVARIANT to
how wide the cross is, so a second measurement at a wider width is
stronger evidence than any single number. When you do need to replay,
extract main and the tip with `git archive … | tar -x`, drop one
`zz_docprobe_test.go` into both that crosses the tables and writes
`cmd<TAB>bucket`, and `paste`/`awk` the two files. Cost: two
extractions, one throwaway dump test, one `go build` per side, and a
python replay.

Do NOT "fix" a total to your own number in a round that is not
re-measuring — the load-bearing figure is the moving SET, and it
survives the disagreement. Do replace it, with its derivation, in a
round that is re-measuring anyway.

**Re-derive the "can possibly move" argument every round; it is scoped
to that round's change, not to the sentence.** The tier decomposition
under the total is the part that rots, and it rots invisibly because the
total can stay put while a sub-count moves. A parenthetical of the form
"these rows carry no operands and no flags, so alias resolution is the
only tier that can move one" goes false the moment any non-alias tier
starts escalating a bare row — which is exactly what a whole-verb
escalation does. When a round changes a verb the count sentence names
anywhere, including inside a sub-count's parenthetical, replay the cross
rather than reasoning that the total looks unchanged, and equally rather
than reasoning that it must have changed.

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

**The gate README's gh bullet is one run-on bullet with no paragraph
breaks, so an appended rationale silently splits subject from verb
(#256, PR #257 second round).** The exclusion paragraphs the owner's
scope cut called for were appended *inside* the pre-existing `(#195 —
…)` parenthetical, which then ran ~30 lines between "a fragment-free
mutation document whose every top-level mutation field is on the
curated issue-metadata allowlist (" and its own verb ") also
**allows**". The whole `gh api` bullet is deliberately unbroken running
prose, so the repair is NOT a new paragraph: close the parenthetical
where it used to close, finish the main clause, and re-emit the
appended sentences after it (capitalising the "any other …" that
followed). Restore any pronoun whose antecedent the move strips —
"Its adjacent spellings" became "The spellings adjacent to
`updateIssueFieldValue`". Zero markdownlint issues before and after,
and no Go file touched, so no binary rebuild
([[project_permgate-go-comment-edits-need-binary-rebuild]]).

**A gh-api/graphql round's real doc gap is in the PLAYBOOK, not the
gate README (#256, PR #257 third round).** By round three the README
paragraph and the `ghGraphQLMutationAllowlist` comment were both
accurate — every claim settled by one command: the four concept pairs
in `UpdateIssueInput` (`state`/`stateInput`, `issueTypeId`/`issueType`,
`assignees`/`assigneeIds`, `labels`/`labelIds`), the
`AgentAssignmentInput` arms, the absence of
`updateIssueIssueFieldValue` from `Mutation`, the 13-member README
enumeration matching the map exactly, `updateIssueIssueType` being what
`plugins/issues/skills/**` templates use, and every verdict replayed
through the branch binary. What no surface carried was the *technique*
that overturned the code two rounds earlier, so
`docs/guardrails-verification-playbook.md` got a new section (schema
introspection as the way to grade an allowlist entry, the verbatim
`INTROSPECTION_LIMIT_EXCEEDED` cap at two `__Type.inputFields` per
document, `__type(name: "Mutation") { fields { name } }` for
existence). **How to apply:** when the gate docs are already correct on
a round, ask which *playbook* technique the round used and whether it
is written down — CLAUDE.md's "Settle a claim with the playbook"
section makes that a first-class doc surface, and a `/docs` edit needs
no plugin version bump. Word any verdict you state there with the
literal words `ask`/`allow`/`deny`/`defer` so CLAUDE.md's
grep-the-playbook-on-a-verdict-change sweep can find it.

**A WIRE-SPELLING round rots the verb the old spelling was described
with, in files nowhere near the diff (#271, PR #272).** When the defer
stopped carrying `permissionDecision` at all, the developer rewrote
every paragraph *about* the emission — the README's stdout section, the
empty-stdout discriminator, `emitDecision`'s and `BucketDefer`'s own
comments, the playbook's probe section — and left three copies of the
old verb "`emitDecision` blanks a defer's reason" standing:
`deferJudgment`'s doc comment in the same file the round edited, plus
`gh_api_gate_test.go` and `gh_publish_files_test.go`, whose comments
justify a test's existence by naming which channel a reason travels on.
Grep the VERB the old mechanism was described with (`blank`, `drops`,
`empties`) package-wide, not the field name — the field name appears
only where the round already looked. Test-file doc comments are the
reliable survivors, same as in
[[project_verdict-rebucketing-comment-vocabulary]].

Second surface on the same round, and it is not a guardrails file:
`docs/hook-event-notes.md` is the per-hook-EVENT lessons log, and a
change forced by the harness's reading of a hook field is exactly its
subject matter — the abstention envelope, the literal `defer` meaning
"pause for later resumption", and the wrapper's empty-stdout
fail-closed all landed there as a new `PreToolUse` section. That file's
existing PreToolUse bullets say a display-only hook must omit
`hookSpecificOutput` entirely, which reads as contradicting the
field-absent envelope; it does not (one hook never decides, the other
decides on some calls), but say so explicitly rather than editing an
unmeasured claim.

A comment-only round here still needs the three binaries rebuilt
([[project_permgate-go-comment-edits-need-binary-rebuild]]), and the
playbook's `go tool nm` pre/post comparison is the cheap proof that the
policy did not move: extract the pre-edit binary with `git show
HEAD:<path> > <scratch>`, dump both, `cmp`. Identical `nm` plus a
changed file settles "comments only" without argument.
