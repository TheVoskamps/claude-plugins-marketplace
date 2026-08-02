---
name: only-one-before-list-is-in-class
description: '"You need only one field:" before a one-bullet list is in-class under core-principles §7; the fix keeps "only"/"just" and drops the numeral. Frozen-history and external-structure counts are out of class.'
metadata:
  type: project
---

"You need only one field from the file:" immediately before a
one-bullet list falls under core-principles §7's
no-count-before-a-self-counting-list rule, not its constraint
carve-out. Grade it in-class, Low.

**Why:** the numeral is a tally of the adjacent list and rots exactly
like one (a second field makes the list self-correct while the prose
lies); the minimality meaning lives entirely in "only"/"just", which
survives the fix. The carve-out protects counts that are behavioral
constraints *not* adjacent to an enumerating list ("retry up to 3
times") — here the real constraint is *which* field, not how many. The
canonical fix keeps the contrast and drops the tally: "only ever needed
two things out of the old six-field contract:" becomes "only ever
needed these things ...".

**How to apply:** when grading §7 candidates, test whether the number
survives deleting the adjacent list. If the sentence's point still
needs the number without the list in view, it is a constraint
(carve-out); if the point is carried by "only"/"just"/"these", the
numeral is a tally — flag it, and recommend the keep-only-drop-numeral
rewrite. Sweep both wordings ("only one X:" and "just the one X
below") in the same file.

**Out-of-class boundary.** In-class requires the count to introduce or
encode an enumeration adjacent in the *same document*. Out of class:

- frozen-history counts inside a narrative ("the other two accurate",
  "wrong on all three specifics") — the counted set is a past artifact
  that cannot grow, so the count is a fact, not a rot-prone tally;
- counts of external or assembled structure that no adjacent list
  enumerates ("falsify all three sites at once", counting sites in
  another file; "correct all three sites together", counting entry
  body + `description:` + index hook) — territory claims to *verify*,
  not tallies to delete;
- conjunction emphasis ("X and Y both apply") and quoted examples of
  the defect pattern.

**A false count can be born false rather than rotted.** This agent's
own `git-sandbox-via-script-file` entry was created saying "Two harness
constraints" above a three-bullet list. When a PR edits a list, check
the count that introduces it even when that line is untouched context;
and before narrating a false count as "rotted" rather than "born
false", pull the creating commit — the histories read identically in
the working tree.
