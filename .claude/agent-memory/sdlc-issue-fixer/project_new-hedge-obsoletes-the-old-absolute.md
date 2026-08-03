---
name: new-hedge-obsoletes-the-old-absolute
description: when a change downgrades a fact from "always" to "best-effort/may", the older ABSOLUTE phrasing of that same fact elsewhere in the same file becomes a contradiction your own hunk created — grep the file for the fact, not for the hunk
metadata:
  type: project
---

A behavior change that turns a guarantee into a best-effort usually
lands as a *new, carefully hedged* paragraph. That new paragraph is the
tell: every older sentence in the same file that states the same fact
absolutely is now contradicted, and it was contradicted **by your own
hunk**, not by drift.

**Why:** on PR #228 (issue #226) the bake-time marketplace registration
went from unconditional to per-entry (bake = precondition, boot =
best-effort). The developer added a precise header on
`claude_vm_baked_marketplace_names` saying a boot-declared name
"**may** still need an add at boot". A hundred lines below, in the very
function that header names as the caller, the untouched comments still
said the boot path "**must** ADD it". The reviewer's finding named two
*other* comments in two *other* files; nobody had grepped the fact
inside the file the change already opened. Pre-change, the loose
wording was merely imprecise; post-change it is a flat contradiction
sitting a screen away from its own correction.

**How to apply:** after writing a hedged restatement of a fact, grep
the same file for the fact's vocabulary — not for your hunk's line
range. Modal verbs are the cheapest handle: `grep -n 'must\|always\|
already\|never'` over the file, then read each hit against the new
policy. Distinguish the two directions, because a sweep brief usually
names only one: prose that over-claims what the strict path does ("the
image must register these") **and** prose that over-claims the
consequence of the relaxed path ("the image does not carry it, so it
must be added"). Both are the same defect.

Watch the pre-existing/created boundary honestly. A comment that was
already loose before the change is not automatically in scope — say so
in the report and let the reviewer judge — but "the change added the
sentence that makes it read as a contradiction" is a real, defensible
reason to fix it in the same round rather than eat another cycle.

Sibling shapes: [[shared-predicate-list-is-one-claim]] (a blanket
predicate over a list is one claim),
[[count-tally-class-includes-back-references]] (a tally and its
back-references are one claim), [[sweep-sibling-agent-guards]] (sweep
the exception clause, not just the headline).
