# Auditing a claim written in prose

A sentence about how the code works is a claim about the
implementation, and no test fails on a false one. This file is the
catalogue of shapes that go false here, and what settles each.

It complements the verification playbooks rather than repeating them:
they say how to *establish* a fact about this repo's code, this file
says which sentences owe you one. The obligation itself is stated in
the agent definitions that write prose — what follows is the list of
places it bites.

The shapes below are ordered by how often they survive a review round,
not by severity. The common thread: each is settled by a grep or a
single run, in seconds, and each survives precisely because the code
beside it is correct.

## A predicate shared by a list is one claim

"A, B and C all have property P" is not three claims that can be
settled one per round. It is one claim needing P checked against every
member, and the wrong grade hides in the member nobody opened. A
finding that names one member therefore obliges re-reading all of them.

The blanket-*negative* form — "never", "only", "not stale-prone" — is
the worst case, because a negative can only be substantiated by full
coverage in the first place.

The list need not be bulleted. A conjoined subject inside one sentence
is the same claim, and it is the easiest to miss: when a new key is
documented next to an older one, the older key's gate gets borrowed
from its neighbour, and the borrowed half tells a reader to expect a
check that does not exist.

When the list is scoped by a **quoted phrase** it asserts a second
thing — that the named files are all the files carrying that phrase.
That half is settled by one `grep -rn` for the phrase, diffed against
the list. Read each new hit before adding it: a near-miss may belong to
a different class, and that exclusion belongs in the prose rather than
being silently dropped.

A **byte-identity** claim over such a list — "in these twin sections
only the gloss bullets are shared copy, the prose around them is
deliberately per-agent" — is a diff result, not a reading. Slice both
sections to scratch files, `diff` them, and let the hunks decide which
sentences the rule calls shared: line wrapping hides identity, so two
paragraphs that look per-agent can still end in the same sentence at a
different wrap, and a later sweep trusting the rule then edits it in
one file only.

A **table row** can carry the same defect in miniature. A disposition
worded "either X's or Y's path" collapses two actors whose outcomes
differ; split it per actor, and re-grade the sentence under the table,
which usually names only one actor's value.

Prefer rewriting so each member carries its own verified description. A
per-member sentence can go stale singly; it cannot hide a wrong member
behind a right one.

## An absolute outlives the case it was written for

Grep the absolute quantifiers — "every", "all", "always", "never",
"any" — rather than the mechanism's name. Recurring sources:

- **A widened enumeration.** The list and its introducing sentence get
  edited; the "except", "only" and "unless" clauses *after* the list
  keep the old narrow scope and silently narrow the widened claim back.
- **A widened guard.** When equality becomes a relation (overlap,
  ancestor, range), the function header and error strings move, and the
  rationale sitting beside each protected *value* still spells the
  narrow case.
- **A new arm in a resolution rule.** A formula used elsewhere as a
  label ("the set you review against") is falsified by an arm that
  substitutes for one of its inputs, and grepping the arm's own
  vocabulary never finds those sites. Grep the formula's symbols, and
  repair by pointing at the step that owns the resolution rather than
  restating the amended rule.
- **A newly hedged paragraph.** A change that turns a guarantee into a
  best-effort lands as a careful new hedge, which contradicts every
  older sentence in the same file stating the fact absolutely — and it
  was your own hunk that contradicted them. Grep the fact's modal verbs
  over the whole file, not your hunk's line range.

One surface of a round is usually written carefully enough to name the
corner where the claim does *not* hold. Import that sibling's
qualifier rather than re-deriving from the code; the careful one is
usually the README or the test comment that had to justify a fixture
choice, and the sloppy ones are the code comment and the playbook.

When a finding concedes the substance and objects only to the
quantifier, skipping the last part of the repair invites the same
finding next round: swap the over-broad verb for the one the argument
needs, name the counterexample inline, and say why it is not a
counterexample to the *narrowed* claim.

## A count rots; the list does not

The global no-count-before-a-self-counting-list rule is the headline,
but a tally's back-references are part of the same claim: prose
downstream of the list ("those three lines", "the fourth"), YAML
`description:` frontmatter, and comments in non-Markdown files, none
of which a Markdown-only sweep reaches.

A count over a set some other process keeps growing is worse than
stale — it is re-falsified every round. A Testing bullet counting the
changed Markdown files is the recurring instance. Name the command
that produces the set and drop the number.

A "N rows move" figure is a property of the **row set**, not of the
change, and rounds that each hand-build their own row list each measure
honestly and each report a different number. State the row set in the
same sentence as the number, build it by crossing the code's own
tables rather than by listing rows you thought of, and publish the
derivation. Do not swap a total to your own reconstruction in a round
that is not re-measuring; do replace it, with its derivation, in one
that is.

## A pointer is a claim about its target

`(see "<Section>")` asserts that the named section carries the thing
being pointed at. The rule half is usually right; the location half
rots, because sections get renamed, split, or moved to another file
while the pointer keeps reading plausibly. Its reader is an agent
following the reference to learn a rule, so a pointer at a section that
lacks it is a dead end that reads as a live one — and the agent invents
the rule instead.

Open the target and grep the heading. When it does not carry the
claim, aim the pointer at the file and heading that does; a cross-file
pointer beats an in-file one that is merely nearer.

A **dangling** pointer, at a file or section that does not exist, is
almost never repaired by inlining the rule. Read each citation's own
surrounding paragraph first: it usually already states the content, so
the repair is deleting the pointer or aiming it at something that
exists. Enumerate every citation with one grep before editing any of
them, and finish with a repo-wide grep for the dangling name.

A returned grep is not the check for a *quoted* heading. A pointer
quoting the readable half of a longer title greps to a hit while
quoting a string that is no heading in that file. Join the quoted
string back across its line breaks — each newline and the following
line's indent collapsing to one space — and compare that against the
heading line. A wrapped pointer and an unwrapped one both pass, so
never reflow surrounding prose just to unwrap one.

## A structural claim is settled by a grep

"Funnelled through a single helper", "the only caller", "all three
tracks", "always routed through X", "cleaned up on exit", "removed by
the trap", "temporary". Each is one grep. The trap is that these
sentences sit next to code that *was* tested, so the verified behavior
lends them unearned credibility.

The lifetime family is the one that reads as a safe default and is
often exactly backwards: a `cleanup()` trap that shreds one directory
and deliberately retains another makes "run state is cleaned up on
exit" false beside code whose every acceptance criterion was observed.

A structural **exemption** is the same shape pointed the other way:
"sits inside a list element, so no prune reaches it", "no consumer
touches that path", "the parent is never empty". That is a claim about
a *recursive* operator's reach, so read the operator's own expression —
a recursive descent crosses the boundary the exemption assumes.

A claim about *reach* is not settled by reading the helper. The helper
usually does what its doc comment says; the falsehood is in the call
sites, so grep the callers first — a single call site is the tell that
a "for every X" claim is scoped — and then run it.

Further members of the family, each settled by opening one file:

- **"X's value always wins."** That is a claim about sourcing and
  assignment *order*, not about who owns the name. Open the consumer
  and compare line numbers. Ownership is not evidence about order, and
  such a rationale is normally copied to a library header, its
  diagnostics, a call-site comment, the README, the example configs
  and the wizards at once — so it can be right for a false reason on
  every surface, with nothing red.
- **"The abort names the path."** A sentence describing what a
  diagnostic says is a claim about literal message strings, and a
  validator with two branches usually names the detail in only one of
  them — the branch that has it. Count the emitting branches and make
  the prose describe the weakest one, or say which detail belongs to
  which case. The same goes for a doc that quotes a command shape:
  copy the real argv from the call site, since a dropped option word
  can be the very thing that makes the quoted position load-bearing.

## A worked example is a claim too

An example asserts that one specific input reaches one specific
outcome, and it rots on a change the example was never about. When a
value changes tier or a mechanism narrows, grep the value across the
whole file and grade every example it appears in, not only the
paragraphs about the mechanism that moved: a short name is a popular
example precisely because it is short, so it gets borrowed by
paragraphs about unrelated mechanisms, and those are never in the
round's diff.

An example wrapped across comment lines is invisible to a line-oriented
grep. Join each contiguous run of comment lines into one string and
match the joined text.

When the example's old outcome no longer exists, say what the verdict
is *not* and then where it lands, rather than swapping in a different
subject — swapping silently changes which mechanism the sentence
demonstrates.

## The verdict can be right and the stated reason false

A true result does not prove the stated cause. The shapes:

- **A test whose doc comment explains why it passes.** Replay its rows
  under the conditions the comment names.
- **A comment justifying why a spelling is unsafe.** Mutate the code
  into the unsafe spelling and confirm the test goes red. If it stays
  green, either the assertion is vacuous or the explanation is wrong —
  find out which.
- **"The old read took X as Y, so it then did Z."** That trailing
  clause is a claim about code you are deleting, so nothing you build
  afterwards can falsify it, and it is usually wrong in one particular
  way: the misparsed value trips an unrelated guard upstream and never
  reaches the consequence you named. Drive the old code with the exact
  input and read what it logs.
- **A negate-check sentence.** "Removing arm A makes test T fail"
  asserts a set — that T fails and the tests you did not name do not.
  Run the mutation over the **whole** package; a `-run` filter cannot
  see the second failure, and a fault-injection test is the shape most
  likely to go vacuous under exactly its own control mutation.

The general move: delete or mutate the mechanism the sentence names,
re-run, and see whether the verdict follows. If it survives, the
sentence is describing something else.

## An enumeration is derived, not transcribed

When a finding says a list dropped a member, appending that member
ships its siblings. Dump the authoritative structure to a file, grade
every surface carrying the list against that dump with a script, and
run the checker *before* editing — that failure is what makes its later
pass mean anything. The surfaces are wider than the source tree: the
PR body carries the same lists.

When successive rounds each hand you "you closed one more instance of
the same class", the enumeration itself is the defect. Stop adding call
site N+1 and make the reach a property of a **traversal**, pinned by a
count equality rather than a row list — a row list only ever pins the
positions someone already thought of. State every deliberate exception
in the test, with its blast radius measured rather than reasoned; an
exception phrased as "covered by some other mechanism" is a reach claim
of its own.

Auditing a large mechanical sweep — "remove token T from every
comment" — is the same problem pointed backwards. The sweep breaks
prose exactly where the removed token was the head of a noun phrase,
so pair the removed and added hunks and read only the ones where the
sweep **added** words; those are where a sentence was rebuilt and can
have been rebuilt wrong. Read the surrounding comment block joined
into one string, since a wrap-split phrase is invisible to a
line-oriented grep.

## A split ruling is a defect in the rule, not in the instances

When one round rules that something satisfies a check and the next
rules that it does not, the finding is about the check's wording: it
admits two readings, so repairing the flagged instances buys one clean
round and the dispute returns on the next diff that reaches it. Pick
the reading that stays satisfiable in the general case, write *that*
into the rule, and only then re-grade the instances against the
settled rule. Reflowing the instances to satisfy an unsatisfiable rule
leaves the rule saying the impossible thing.

## An issue's account of existing behavior is a prediction

An issue body carries two kinds of claim, and only one is
authoritative. The **rule** the change must implement is the issue's
to decide. The author's **prediction** of what verdict that rule
produces for each existing case is a claim about code you can run —
and it is often wrong, because acceptance bullets get written from
memory of the implementation. Measure each predicted row against the
current binary or script before writing code for it, implement the
rule uniformly, and report every divergence with its measurement
rather than bending the code to match the prediction.

The neighbouring case is an issue that specifies something a repo
document already forbids. Ship neither half silently: implement the
issue and settle the contradicted statement in the same change, having
first graded the statement, because the two grades take opposite
repairs. A **capability** claim — what the harness can or cannot do —
is verifiable, and a false one is deleted rather than carved out of;
an exception would preserve the falsehood as the general rule. A
**policy** claim, where both behaviors are possible and the repo
picked one, can take a named exception with its reason inline.
Prescriptive wording ("may only", "never") does not settle which it
is — that is exactly how a false capability claim reads. Say in the PR
body which grade you gave it, and sweep every restatement rather than
the one the issue names.

## A recommendation rests on a premise, and the premise is measurable

A finding's defect is normally measured; the premise underneath its
recommendation usually is not. "This is the only member an operator can
hit", "no other caller touches that path", "the companion PR is still
open". Each is a claim about the rest of the system, falsifiable by one
grep of what the premise quantifies over.

When the premise falls, the fix usually still stands but its *stated
benefit* changes. Reword every surface to the benefit you can prove and
report the correction, rather than shipping the reviewer's sentence
unexamined.

A finding's evidence block covers the tools the reviewer ran, and your
repair's prose usually generalizes past them. Re-run their probe, then
probe every additional tool your own sentence names — the sentence is
the wider claim, so it needs the wider measurement.

The mirror-image premise is a recommendation to "do what the sibling
already does". That assumes the sibling's precondition holds on your
side: a sibling that solely owns its destination can afford an
`rm -rf` there, and copying it into a layer whose destination is a
merge target deletes bytes your layer never wrote.

Premises about **external state** are snapshots taken at review time,
and the world moves between the review and the fix. Re-read both ends —
the tracker state and the deployed artifact — before writing anything
about it; the remedy usually survives with its tense flipped. A finding
whose quoted line range resolves to unrelated code was written against
a revision you are not on, so grade it by grepping the content it
quotes and expect at least one of its halves to be closed already.

## The surfaces that carry a claim run past the code

- **The PR body and title.** Both go stale for the same reason a README
  does, and nothing checks either. The body is what a human reads to
  decide whether to merge and what the squash commit carries into
  history; the title *is* the squash subject, and it is missed because
  it is a different field. Re-read the live body rather than your
  memory of it — other agents edit it too.
- **A sweep rule that says which surfaces carry a clause.** Propagating
  the clause to its siblings is what makes the rule false, and the rule
  is the surface you did not open. Prefer a quantified repair with a
  named exception over an Nth copy of the list. When the choice is
  between de-specifying a restatement and widening the rule's
  exception, de-specifying wins: dropping the restated value ends the
  sweep obligation instead of enlarging it, and the follow-up grep for
  the literal should then return only its owner.
- **The prose that was written to argue for something now dropped.**
  When an owner cuts half of what a change added, deleting the entry
  is the small part: the rationale comment, the README enumeration,
  the tests, the PR title and body were all written to advocate for
  it. Convert them into a documented exclusion with its reason rather
  than deleting the mentions, or the next reader re-proposes the thing
  that was rejected.
- **The gap an issue says it is leaving in place.** A "known gaps" or
  "deliberately not fixed" section is the half a change's own docs
  reliably omit, because the author writes what the change does. But a
  gap is exactly what a later reader cannot recover from the code: an
  absent check reads as an oversight to fix rather than a decision to
  respect. Grep the README for each gap's mechanism before calling it
  covered, and re-read the nearby prose, which by then usually states
  a completeness the gap contradicts.
- **A rule that cites its own violating site as an exemplar.** When a
  finding offers "fix the instance or soften the claim", grep the
  claim's paragraph for the instance's name. A hit means the instance
  is load-bearing for the rule's exposition, and the instance is the
  end to move.

## When the code turns out to be the wrong half

Sometimes the prose is right and the implementation is not. Say so:
fix it if it is in scope, and report it either way. A mismatch between
a sentence and the code is a finding whichever side moved.
