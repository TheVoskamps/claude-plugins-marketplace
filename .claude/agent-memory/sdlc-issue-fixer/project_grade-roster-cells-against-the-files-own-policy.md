---
name: grade-roster-cells-against-the-files-own-policy
description: A pointer document that declares "this file never restates" supplies its own grading predicate; sweep every roster cell against that definition, not against the one row the finding names
metadata:
  type: project
---

When a finding says one table cell restates a contract owned elsewhere,
the sweep unit is the CLAUSE TYPE, not the row. A pointer document that
opens with its own non-restatement policy usually also DEFINES what it
means by contract, and that definition is the predicate to grade every
cell with. `plugins/sdlc/README.md` spells it as "what it commits, when
it runs, what it returns" — so the flagged
`agent-memory-scrubber` cell ("as the last agent to touch the branch",
= *when it runs*) had a sibling the review did not name:
`issue-developer`'s "and opens the PR" (= *what it returns*, and
exactly the clause `skills/orchestrate/SKILL.md`'s roster bullets close
with). Fixing only the named row leaves the file's own opening
paragraph false.

The round that fixed those two still shipped a third: `theorem-generator`'s
"Reads a PR and returns disprovable theorems", which a later review round
caught. It survived because the cell OPENS in scope ("Reads a PR") and the
return clause rides on an `and` — so a reader grading the cell as a whole
scores it by its first verb. Grade each conjunct of a cell separately, not
the cell.

**Why:** the finding cites one instance because a reviewer graded the
row it was reading; the file's policy paragraph quantifies over the
whole table, so it is the half that stays falsified.

**How to apply:** before editing the named cell, read the document's
own policy paragraph, extract its definition of the thing it refuses to
restate, and re-read every peer cell against that definition. Cells
that state the work's SCOPE ("implements one batch of issues on one
branch", "applies review findings to an open PR's branch") survive;
cells that state timing or deliverable do not. Related:
[[shared-predicate-list-is-one-claim]],
[[enumerate-completely-derive-from-the-structure]].
