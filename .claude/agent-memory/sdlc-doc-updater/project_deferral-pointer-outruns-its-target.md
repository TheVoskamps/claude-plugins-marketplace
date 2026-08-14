---
name: deferral-pointer-outruns-its-target
description: A round that replaces a restatement with a "see the other file's X section" pointer promises more than the target section says; read the target before accepting the deferral.
metadata:
  type: project
---

When a fixer round de-duplicates prose by turning a restatement into a
pointer ("what that tally enumerates, and **which of its counts never
reach severity**, is the pipeline skill's own 'Report back' section"),
grade the pointer against the target section's actual text. The
pointer is written from the author's mental model of the target, not
from a re-read of it.

**Why:** on #259 both callers (`skills/git-review-pr/SKILL.md` and
`skills/orchestrate/SKILL.md`) deferred to
`pr-review-pipeline/SKILL.md` → "Report back" for which tally counts
never reach severity. That section named surviving and refuted only,
while the disposition table and review-body section 7 both give the
unsettled row "no severity" — so the deferral pointed at an
enumeration missing a third of its subject. Nothing was wrong; the
target was just narrower than the pointer claimed.

**How to apply:** on any round whose commit message says "defers to X
rather than restating", open X and check it covers every noun the
pointer names. Repair on the TARGET side when the omitted fact is
already established elsewhere in that file — that keeps the single
source of truth single. Same shape as
[[no-blanket-predicate-over-a-list]]: a pointer is one claim per thing
it promises. Related: [[fan-out-doc-surfaces]] on two-sided contracts.

**Prefix-quoted headings are the cheap sibling of this.** A round that
renames a heading and adds pointers to it in the same commit tends to
quote the *readable half* of the new title, not the title — #265 gave
`theorem-generation` the heading "The emission bar: falsifiability,
then stakes" and pointed at it from `orchestrate` and
`pr-review-pipeline` as → "The emission bar". A grep for the pointer
string finds the heading, so it looks resolved — but the string the
pointer quotes is no heading in that file. Neither source states a
general verbatim rule to lean on:
`theorem-generation`'s cross-reference-pointer bullet asks only that
"every `→ "Section"` pointer at the touched files resolves to a real
heading", and CLAUDE.md's `verbatim` wording covers the
`### After each ...` headings generically — all of them, and
`orchestrate/SKILL.md` carries more than one — rather than quoted
pointers at large. So the check is the resolution itself, run
strictly: on any round that renames or adds a heading, grep the new
title's words and compare each pointer to the heading line character
for character, not by whether the grep returned a hit.

**A line wrap inside the quotes is not a mismatch.** These files wrap
their prose, so a quoted title longer than the room left on the line
has to break somewhere, and a rule forbidding that would be
unsatisfiable for a title near the column limit. Join the pointer's
quoted string back across its line breaks — collapsing each newline
and the following line's leading whitespace to the single space the
wrap replaced — and compare *that* against the heading text. What the
comparison catches is a pointer whose words differ from the
heading's: a truncation like "The emission bar", a reordering, a
dropped subtitle. A wrapped pointer and an unwrapped one to the same
heading both pass, so do not reflow surrounding prose just to unwrap
one.
