---
name: only-one-before-list-is-in-class
description: Adjudicated on PR #211 round 2 — "You need only one field:" before a one-bullet list is in-class under core-principles §7; the fix keeps "only"/"just" and drops the numeral.
metadata:
  type: project
---

PR #211 round 2 adjudicated whether "You need only one field from the
file:" (pr-reviewer.md:52, immediately before a one-bullet list) falls
under core-principles §7's no-count-before-a-self-counting-list rule or
its constraint carve-out. Ruling: in-class, Low.

**Why:** the numeral is a tally of the adjacent list and rots exactly
like one (a second field makes the list self-correct while the prose
lies); the minimality meaning lives entirely in "only"/"just", which
survives the fix. The carve-out protects counts that are behavioral
constraints *not* adjacent to an enumerating list ("retry up to 3
times") — here the real constraint is *which* field, not how many. The
PR itself set the precedent: "only ever needed two things out of the
old six-field contract:" -> "only ever needed these things ..." kept
the contrast, dropped the tally.

**How to apply:** when grading §7 candidates, test whether the number
survives deleting the adjacent list. If the sentence's point still
needs the number without the list in view, it is a constraint
(carve-out); if the point is carried by "only"/"just"/"these", the
numeral is a tally — flag it, and recommend the keep-only-drop-numeral
rewrite. Sweep both wordings ("only one X:" and "just the one X
below") in the same file.
