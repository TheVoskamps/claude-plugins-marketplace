# Prose claim shapes that go false quietly

**Who reads this and when:** any agent grading prose — a reviewer, a
doc-updater, an author re-reading their own diff. Read it before the
grade, and add to it when a round turns up a new shape that fits the
scope test in the next paragraph.

A sentence in a README, a code comment or a skill file is a claim, and
no test fails when one rots. The shapes below are the ones that rot
without looking wrong, collected from rounds where the behavior was
right and only its description was false. Each names the tell and the
check that settles it.

The verification playbooks own *how to establish a fact*; this file
owns *which sentences to distrust*.

## One predicate over a list is one claim per member

`<these files> all <predicate>` reads as verified because it is one
sentence, but its evidence is usually one member opened and the rest
assumed. Write per-member clauses instead, each with the trigger that
makes it go stale — and when *reading* such a sentence, treat it as a
weaker warrant than a per-member one and re-verify the member you are
about to act on.

Siblings of the same shape:

- **"Each of these is handled the same way."** A sentence covering
  several members with one mechanism usually survives as a *point*
  while its mechanism has to be split — three shares described as
  "copied into `$HOME/.claude/`" turned out to be two files copied
  there, one copied elsewhere under a different name, and one never
  copied at all, only read in place.
- **"X is in the list."** A denylist entry that *covers* a path is not
  the claim that the path is *in* it. A guard that is an ancestor
  relation catches children of its members, so "is in" and "is covered
  by" fail differently the day the guard becomes a membership test.
  Read the guard, not just the constant.

## The clause after a widened list keeps the old scope

A round that widens an enumeration edits the list and the sentence
introducing it. The "except", "only" and "unless" qualifiers
*downstream* of the list were written against the narrow set and
silently narrow the widened claim back — and every assertion around
them stays true, which is why they survive review.

After any list-widening edit, read to the end of the paragraph and
grep the old narrow token in the same file.

## A qualifier patched onto a blanket statement readmits the exception

When a PR introduces the first exception to a blanket rule, the
author typically patches the rule with a vague hedge and writes the
real exception in the *next* paragraph. Read the two together: the
hedge routinely fails to exclude the new case, so the pair
contradicts itself while the diff looks like the fix.

Name the exception in the statement itself rather than hedging around
it. Grep the statement's vocabulary and read every hit *with* the
paragraph after it, asking whether the qualifier's own words exclude
the new member.

## An absolute is false in the corner its careful sibling names

A round that fixes a defect writes the defect's story onto several
surfaces at once. One of them is written carefully enough to name the
corner where the defect does *not* bite; the others state the same
fact as an unqualified absolute, and the absolute is false exactly in
the corner its sibling already spells out. The careful one is usually
the README or the test comment that had to justify a fixture choice;
the sloppy ones are the code comment and the playbook.

Grep the absolute quantifiers — "every", "all", "always", "never",
"any" — and check each against the most careful sibling statement of
the same fact rather than against the code alone. Fix by importing the
sibling's qualifier, and say that the behavior was right and only the
claim's scope was wrong.

## A widened guard leaves narrow prose beside each protected item

Widening a check — equality to an overlap or ancestor relation, a
value to a range — updates the function header, the error strings and
the doc surfaces. What survives is the prose beside each *item the
guard protects*, explaining why that item is in the guarded set in the
pre-widening vocabulary. Nothing tests a comment, and the narrow
spelling reads as deliberate scoping rather than a leftover.

Grep the narrow relation's vocabulary — "equal to", "the same as",
"lands on", "or above" — near every member of the guarded set, then
run the predicate against a case in the newly-covered direction rather
than reasoning it out.

## A carve-out leaves absolute attributions in sibling files

When a round carves an exception into a rule, the exception is written
where the rule is defined and nowhere else. Sibling files restate the
rule as an *attribution* — naming who assigns a value — and go
silently false. The rule's *point* stays intact, which is why previous
rounds read past it: the falsehood sits in the incidental clause, not
the imperative.

Grep the **actor** named in the new exception, not the rule's
vocabulary, because the stale sentences name the actor and never name
the exception. Include the rule's own file in that grep — a header
sentence two paragraphs above the exception is the classic survivor.
Repair by widening the attribution and letting a pointer do the work,
rather than restating the carve-out at the pointer site.

While you are there, read the round's own new prose for definite
singulars: "on the one entry where …" states a per-entry rule as if at
most one such entry can occur. Write "on any entry for which".

## "Only X is shared copy" is a diff result

A sweep rule of the form "in these twin sections only X must stay
byte-identical; the prose around it is deliberately per-file" is a
claim about the whole section. Line wrapping hides identity, so slice
both sections to scratch files and `diff` them, letting the hunk
boundaries decide which sentences are shared and which are not. A
"per-file" paragraph that happens to *end* in one identical sentence
at a different wrap is exactly the drift such a rule exists to
prevent.

Drop any count from the claim: if adding a member edits these files,
the tally rots on the next member.

## Token locality is not gloss locality

When a rule says a vocabulary "lives in these files", grep the token
**and** grep a distinctive phrase from its definition. The two answers
differ whenever a consumer restates the definitions against its own
names — tokens to severities, classes to labels, codes to messages. A
token grep returns zero hits at that translation layer, so the
locality claim reads as verified while the surface silently keeping an
old meaning is precisely the one it missed.

## A pointer promises more than its target delivers

"Defers to X's own section rather than restating" is a claim about
what X says, written from the author's memory of X rather than a
re-read. Open X and check it covers every noun the pointer names.
Repair on the *target* side when the omitted fact is established
elsewhere in that file — that keeps the single source of truth single.

A quoted heading is the cheap sibling: a `→ "Section"` pointer that
quotes only the readable half of a longer title greps to a hit while
naming no heading that exists. Compare against the heading line
itself, joining a wrapped quote back across its line breaks first.

## Each half of a seam warns about its own failure only

Prose for a feature spanning a producer and a consumer tends to
collapse both warnings into one sentence — "warned about loudly, on
the host and again in the guest log". Grep confirms two warning
strings exist, and the sentence still misreads: each side warns only
about *its own* failure. If the producing side drops a partial
artifact on failure, the consumer never sees it and says nothing.

"And again" asserts that one failure produces two reports, which is a
claim about the failing side's recovery path, not about how many
warning statements exist. Read what the failing half does with the
artifact — drop it, pass it on partial, or abort — then attribute each
warning to the side that emits it.

## "This one always wins" is a claim about read order

A sentence of the form "the launcher's value always wins, so a config
fighting it can never take effect" is settled by *where* each
assignment is read, not by who owns the name. Open the consumer and
compare line numbers. Ownership of a name is not evidence about order.

Such a rationale is typically restated on a library header, its
diagnostics, a call-site comment, a README, both example configs and
the wizards — and a test matching only a diagnostic's first line never
touches the rationale. A reword sweep is half the fix: the
*enumeration* the rationale ranges over sits in the same sentence on
those surfaces, so naming an exception on one or two of them leaves
the rest asserting a set that is short by one. Fix the list and the
reason together.

## Probe the sibling the prose declares safe

A round that fixes one gate almost always leaves a sentence declaring
its sibling safe, with a structural reason — "sits inside a list
element", "no consumer reaches it", "the parent is never empty". The
round measured the gate it changed. Probe the other one.

A structural exemption is a claim about a *recursive* operator's
reach, so read the operator's actual expression: descent operators and
whole-tree walks cross the boundary such an exemption assumes. The
probe is cheaper than the reading — drive the real function through
the real merge, one row per spelling per layer.

The other half of a seam is the same shape. When a fix hardens the
guest side of a producer/consumer pair, read the host side's commands
before letting an unqualified "nothing here aborts" survive.

## Examples inside policy prose are the falsifiable part

A "principle" section reads as pure policy, so the reflex is to leave
it alone — but each principle is sold with an illustrative example,
and those are ordinary claims about other files, written by the same
author as the rule. The classes that go wrong:

- **A cited scope grant the named agent does not have.** Open that
  agent's definition and grep for the surface the example claims it
  owns or is denied.
- **A destination that only partly receives what the prose says.**
  "Its result goes into `<artifact>`" needs the artifact's template
  matched field by field.
- **A widened enumeration colliding with the absolute right after
  it.** Loosening prose to match an example is safe only if you
  re-read the sentence the enumeration governs.
- **A provenance sentence crediting the wrong producer.** Open the
  named producer's own report section and match it field by field; a
  cell the caller computes itself is easily miscategorised as
  second-hand.

## A mechanical ref-stripping sweep breaks grammar across line wraps

Stripping issue references from a package's comments produces defects
a line-based grep cannot see, because the damage straddles the
comment's wrapping. The classes:

- **The substitution leaves a hole.** The reference was a noun-phrase
  head, so deleting it strands an article or duplicates the noun, with
  the giveaway word sitting on the next comment line where no
  single-line grep finds it.
- **The reference becomes a vague pointer.** "Per the issue's explicit
  requirement", "this issue widens" — these pass a numeric guard while
  making the reader fetch a ticket that is now unnamed, which is worse
  than the numbered form. In test files this is fine, because the
  enclosing test name carries the number; in production code it is
  not.

Join each contiguous run of comment lines into one string and scan the
joined text, and separately read the sweep commit's old-to-new pairs.
Both scans are cheap and each finds artifacts the other misses. Expect
a low defect rate, not a rewrite.

## A "now in exactly one place" round leaves two residues

A round whose point is that a value now lives in a single file leaves
behind:

- **Ragged wrapping**, because the replacement text differs in length
  from what it replaced and the paragraph keeps the old line breaks.
  Where the line-length rule is off, nothing catches it but a read —
  reflow the whole paragraph, not the changed line.
- **Its own headline claim**, which is one grep away and usually
  unmeasured. Run the grep across the tree and read each hit before
  the prose asserts the value appears nowhere else.

A third surface no such round touches: consumer-attribution prose in
*other* plugins, which tends to attribute a fanned-out agent to the
flow that usually runs a skill rather than to the skill that spawns
it. When a component has two callers, name the caller that actually
spawns it.

## A count in front of a list that enumerates itself

A number that tallies the document's own structure — "the three
traps", "two surfaces" — is an editorial choice, and it rots the
moment a member is added, while the list beside it stays correct. A
brand-new section is where such a tally is born, so grep new prose for
number words.

A number carrying independent meaning is not this shape: "retry up to
3 times" or "exactly one parent per issue" is a constraint, not a
tally of something already in view. The test is what would falsify the
number — if adding a member to the list does it, the number goes.

Lowercase spellings survive a capital-letter grep, and a quoted title
naming a count rots with the thing it counts.

## History sentences survive a rename sweep

A rename sweep matches on the old *name*, so what survives are claims
whose *subject* moved: "previously performed", "mirrors what X already
does", "this is the Y that Z used to do". The retired thing did those
things and its replacement never did — and the replacement usually
delegates the behavior to something whose doc now claims to mirror it.

Read every "previously", "mirrors what" and "already does" sentence in
a consumer doc that a rename touched. No grep for the old name
surfaces these, because the predicate is what is false, not the name.

## Concede the point, then repair the quantifier fully

A finding that concedes your substance and objects only to your
*quantifier* — "no scope grant stands, but 'neither file mentions it'
does not" — takes a three-part repair, and skipping the third invites
the same finding next round: swap the over-broad verb for the one the
argument actually needs, name the counterexample inline so a later
reader who finds it does not read the claim as false, and say why the
counterexample is not one for the *narrowed* claim.

## A merged table row hides two rules

A table row that quantifies over actors — "either agent's own path" —
asserts the two share an outcome, and a derivation table is the surface
a reader trusts over prose, so a merged row is what actually ships the
wrong behavior. Two things help it survive review: the merged wording
usually originates in the issue's own table, so it was transcribed
faithfully, and the paragraph under the table names one actor's value,
which splitting the row silently falsifies.

Resolve toward the rule the prose states repeatedly, not the table the
issue drew, and re-grade the sentence under the table in the same edit.

## A new arm falsifies the formula's appositions

Adding an arm to a rule that several passages restate leaves the
*formula* behind as an apposition — "every member of `C ∩ B`, the set
you review against". Those read as harmless restatements and go false
the moment the arm exists, and they are unreachable by grepping the new
arm's vocabulary.

Grep the formula symbol itself, and replace each apposition with a
pointer at the step that owns the resolution rather than restating the
amended formula in a second place.

## A carefully hedged new paragraph indicts the old absolutes

When a guarantee becomes best-effort, the change lands as a new,
precisely hedged paragraph — and that paragraph is the tell. Every
older sentence in the same file stating the same fact absolutely is now
contradicted by your own hunk, not by drift. Pre-change the loose
wording was merely imprecise; post-change it is a flat contradiction
sitting a screen away from its own correction.

Grep the fact's modals inside the file the change already opened, not
only the files a reviewer names.

## "The old code then did Z" is unfalsifiable by construction

When you fix a misparse, the natural comment is "the old read took X as
Y, so it then did Z". That trailing clause describes code you are
deleting, so nothing you build afterwards can falsify it — and it is
the half most likely to be false. A wrong value rarely travels far: it
lands in a slot some *other* validator already guards, so the real
observable is a confident diagnostic about a thing that does not exist,
not the downstream action you predicted.

Drive the old code with the exact input before describing what it did.

## Repair a dangling pointer by reading what each site loses

A repeated pointer at a file or heading that does not exist is repaired
by reading each call site's own paragraph first — the rule is usually
already spelled out inline around it, and the pointer was decoration.
Inlining the rule at every site is the wrong repair: it duplicates
instructions the sites already carry.

Enumerate every citation with one grep before editing any of them,
establish the target's absence by listing the directory rather than by
failing to read it, and finish with a repo-wide grep for the dangling
name — the fix is done when it returns nothing.

## Propagating a clause falsifies the rule that describes it

When a finding says to propagate a clause to its siblings, the sweep
rule describing that clause's distribution becomes false the moment you
finish. The rule is part of the class, and it is the surface you did
not open.

Prefer a quantified repair over a re-enumeration — "every one of them
that also asserts the mode, today all but the header that describes the
directory" is cheaper to keep true than a per-surface list — and verify
the named exception by reading it.

## Prefer de-specifying to widening an exception

A finding of the shape "these lines restate value V, contradicting the
file's own claim to restate nothing of the kind" offers a choice of
repairs: drop V from the prose, or widen the claim to name the
exception. Prefer dropping it whenever the sentence survives without
V, because widening buys a permanent obligation — every future change
to V must find and update the exempted sites — where de-specifying
ends the obligation.

The value's owner keeps spelling it; every describer points there. Then
grep the literal repo-wide and expect exactly the owner back. Sibling
sites matter even when no standing claim covers them: nothing sweeps
them either.

## When the rule cites the violating site as its exemplar

A mismatch between a stated absolute and a site that violates it offers
"fix the instance" or "soften the claim", and the two are not symmetric
when the rule quotes the violating site *as its own illustrative
example*. Softening then leaves the paragraph asserting a weaker rule
while citing, as its model of compliance, a site that no longer models
it.

Grep the claim's own paragraph for the instance's name. A hit means the
instance is load-bearing for the rule's exposition, so the instance is
the end to move.

## A scope cut leaves its advocacy prose behind

An owner ruling that cuts scope reads like a one-line revert, but every
surface the change touched was authored to *justify* the dropped thing.
Deleting only its mentions leaves the change looking like an oversight
and invites the next agent to re-add it. The class: the data entry, its
rationale comment, the doc enumeration restating that rationale, the
tests whose passing rows flip, the PR title and body.

Write the exclusion as a decision with its reason, in the code and the
doc both, and pair it with where the need actually goes — so the
exclusion is not read as a capability gap. Keep any *separate* reason a
neighbour is absent distinct; flattening two reasons into one paragraph
loses both.

## A split ruling indicts the rule, not the instances

When rounds rule opposite ways on one check, the finding is about the
rule, not the flagged instances: the rule admits two readings, so
fixing the instances buys one clean round and the dispute returns on
the next diff. Pick the reading that stays satisfiable in the general
case, write it into the rule, then re-check the instances against the
settled rule.

## A guarantee is scoped to what enforces it

When a doc justifies skipping a check by asserting a precondition — "X
always runs fresh", "Y is never dirty" — verify the precondition is
enforced by that component's own logic. If it is actually a property of
one current caller, say so by name, because a claim phrased as an
intrinsic property reads as durable long after the call site that made
it true is gone.

## A finding's exclusivity premise is measurable

Under a recommendation there is usually a premise — "this is the only
member the operator can hit", "no other caller touches that path". The
finding's defect is normally measured; its premise usually is not, and
it is a claim about the rest of the system, so it falls to one grep of
the sites that consume the value.

## Probe every tool your own sentence names

A finding reporting an empirical result hands you a mechanism and
evidence that look like one thing. The evidence covers only the tools
the reviewer actually ran. Before writing a sentence that names three
tools on the strength of one observation of a fourth, probe each one,
plus the contrasting case the sentence implies — the contrast is what
makes a "unlike X" clause true rather than assumed. Quote the real
error strings: a string a reader can grep for is falsifiable, a
paraphrase is not.

## "Several paths reach this" is an enumeration to run

A finding that says a summary names only one of several causes is not a
prose task. It hands you the list, and driving every path is where the
real defect turns up — one of them routinely does something the summary
never contemplated, and no amount of reading finds it.

## A per-entry index counts the structure the validator walks

A diagnostic emitting `entry #N` counts through whatever it iterates,
which is almost never the file the operator has open: it is the merged,
normalized, defaulted document the loader built. Prose about such a
diagnostic gets written next to the key it describes, in one tier's
example file, so "its position in this list" reads as obviously true
while being wrong for every operator whose other tier is non-empty. It
is also unfalsifiable by a suite that drives a single merged fixture.

## When a guarantee cannot be pinned, soften it and say why

A finding of the shape "you ship guarantee G as settled fact while G is
unpinned" offers pinning or softening. When pinning needs a surface the
codebase cannot reach — a live harness, a running product — take the
softening and say why the pin is out of reach. The claim is usually not
wrong, it is unmeasured, and the defect is selling it as measured.

## Define a derived list against the resolved value

A spec with a resolved set plus derived lists tends to define them
against the *inputs* — "branch members not claimed" as `B \ C`. That is
wrong wherever an arm of the resolution *replaces* one input: a
stand-in arm makes `B \ C` report members that the resolved set
contains. Define against the resolved value instead, which collapses to
the obvious form on the ordinary arm.

## The class is the set of uses, not the set of bad values

A finding like "this value walks out of its directory" invites hunting
for more bad strings. The productive sweep is the other axis — every
*position* the value is consumed in — because a validator's charset
check is written against the positions its author had in mind, and the
hole is always a position nobody listed. Grep the variable and grade
each use position's own grammar; then do the same grep for the sibling
fields.

## An acceptance bullet mixes rules with predictions

Issue bodies mix the **rule** a change must implement with the author's
**prediction** of what verdict that rule produces per case. The rule is
authoritative; a prediction is a claim about existing code and is often
wrong. Measure each predicted row before implementing it — implementing
predictions can require special-casing that the rule never asked for.

## "Mirror the sibling" carries the sibling's precondition

When a remedy is "do what the other side already does", that code
carries an unstated precondition, most commonly *sole ownership of the
destination*. A verbatim mirror into a destination that is an additive
merge target can ship a worse defect than the one it fixes — and the
suite stays green, because nothing asserts the pre-existing content
survives.

## A permission's whole surface is not its caller's surface

Prose justifying a permission scope earns the scope by enumerating
every API surface it unlocks, then predicts the failure the code hits
without it. The enumeration is about the scope; the failure is about
the one call the code actually makes. Collapsing the two yields "it
fails in two different shapes", where one shape belongs to an endpoint
nothing here calls. The tell is a failure sentence whose shape count
matches the endpoint count in the sentence above it. Grep the callers
for each endpoint named, attribute the failure to the ones that
survive, and demote the rest to what a different caller would get.

## A "restated in these places" list is graded by the diff

A doc section enumerating where a value is restated, each site a
separate edit, reads complete because no bullet in it looks wrong. Its
evidence is the change sitting in front of you: every hunk that edited
a restatement of the value is an edit point by construction, so a site
the list omits is where the next change to that value goes stale. Grep
the changed token — a permission scope, a config key, a verdict
spelling — across the plugin and match every hit to a bullet; the hits
with no bullet are the gap. Widen the list before committing, and
describe each site by its role ("the per-scope rationale paragraphs
under it") rather than by quoting the value, or the list itself rots on
the next change.

## A right remedy carries its mechanism unchecked

"Always pass X, because the tool does Y" is two claims, and only the
first gets tested. The remedy is what a reader acts on and what every
restating site copies, so a wrong Y survives every round: the advice
still works, nobody's run disagrees, and each restatement inherits the
error verbatim. The tell is a mechanism sentence with no measurement
beside it, stated in the same commit as the remedy it justifies —
self-graded by the author of both.

`git worktree remove` was documented as *not* resolving its argument
against the cwd, matching a unique path suffix instead. Measured, it
tries the cwd-relative path **first**, and only falls back to the
suffix match — so a short argument can silently remove a different
worktree rather than merely failing. "Use the absolute path" was right
throughout. Run the mechanism, including the case the sentence says
cannot happen.

## An invariant restated as a reject rule loses its exception

A property stated abstractly — "ids are never reused", "every entry is
unique", "the key is always present" — reads the same whether or not
the design carves an exception out of it. It goes false when a later
round writes the *same words* as an operational check: "if X, send it
back as malformed". The abstract form tolerated the exception because
nothing acted on it; the reject rule now refuses exactly what another
file mandates. Nothing greps as inconsistent, because both sentences
say the invariant correctly.

The tell is an imperative — reject, abort, re-emit, treat as
malformed — whose condition is quoted from a general statement rather
than derived from the case list the design actually has. A theorem
generator was told to give a regenerated acceptance-criterion theorem
its existing id, while the reviewer receiving that report was told to
send back any record reusing a carried id. The check that settles it
is to walk the design's own exceptions and ask, for each, what the
reject rule does to it — not to re-read the invariant, which is true.

## A cited precedent claims the environment it is cited for

"This constraint is nothing new — X and Y already work under it" is a
claim about X and Y, not about the new code, and it is the half nobody
runs. The tell is a precedent list of two or more sites gathered by
grepping for the *technology* (a `python3 -c`, a `jq` call, a `curl`)
rather than for the environment the constraint is about, in a sentence
whose point is that the constraint is already survivable.

`auto-mode-tools`' sink documented stdlib-only, Python-3.9 syntax as
matching what `plugins/claude-vm/payload/`'s inline `python3 -c`
scripts already target, naming `lib/credential.sh` and
`provisioners/podman-mkosi.sh`. Only the first runs on the host's
stock `/usr/bin/python3`; the mkosi provisioner's blocks run inside
the Debian build container, on an interpreter that image installs, so
they are evidence for no constraint macOS imposes. Read each cited
site for *where it executes*, not for the call it makes.

## A new option steals the word the old prose already used

Adding a second way to do something often needs a name, and the
obvious name is frequently one the surrounding prose already spends on
a different axis. Every sentence carrying the old sense then reads
against the new one, and each is graded true by its author because
under the old sense it still is.

The tell is a word appearing twice in one document with two referents,
where the diff introduced only the second. `/pr-review-submit` used
"inline" for where the *verdict* travels — an `APPROVED` line in the
body, because GitHub refuses a self-`--approve` — and the `--body-file`
round gave "inline" a second job naming where the *body* travels. "It
was downgraded to an inline `--comment`" then described the one path
that posts from a composed file. The check is to grep the new term
across every file the feature touches and read each pre-existing hit
under the new sense; the repair is to re-word the older sense, which
has somewhere else to go, and leave the new axis the term.

## A platform refusal is scoped to the case that surfaced it

A constraint met while exercising one member of a fixed option set
gets written against that member, and everything downstream inherits
the scope: the section heading names it, the handling covers it alone,
and the caller is told the one case is handled. Nothing reads as
wrong, because the platform does refuse that member — the siblings it
refuses on the same grounds simply have no prose, and the code path
they take fails where the documented one does not.

The tell is a constraint named after one *value* of an enumeration the
same file lists in full a few lines above.
`/pr-review-submit` documented "the self-review approve constraint"
and downgraded an `approve` verdict to a `--comment`, while GitHub
refuses `request_changes` from a PR's own author on the same grounds
and the skill had nothing to say about it. The check is to take the
constraint back to its source — the platform's rule, not the case that
surfaced it — and ask it of every member of the enumeration, then
scope the prose to whatever that answers rather than to the value in
front of you.
