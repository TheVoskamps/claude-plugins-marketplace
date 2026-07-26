---
name: re-review-the-whole-diff-fresh
description: on a re-review round, read the entire PR diff fresh rather than only the delta since the last round — prior approvals are information, not coverage
metadata:
  type: feedback
---

On round N of a PR, review the **whole** diff again from scratch. Do
not read only the commits added since your last pass.

**Why:** on a long-running PR, a fresh full-diff pass found four
defects that five successive incremental rounds had walked straight
past. Edwin named that the strongest available evidence about what
works here and now asks for it explicitly on later rounds. The failure
mode incremental reads miss is *accumulated cross-round inconsistency*:
each round's patch is locally correct but contradicts a paragraph a few
sections away, or leaves a stale pointer to text an earlier round moved
or deleted. A delta-only read cannot see that class at all, because
neither side of the contradiction is in the delta.

**How to apply:** re-read every changed file end to end, and
specifically hunt for: successive patches to the same paragraph that
now disagree; a guard or rule duplicated across sibling agent files
that has drifted apart between copies; the same invariant stated
differently in different places; and a new outcome/branch added in one
file that the files enumerating that file's outcomes were not swept to
match. Also weigh the two directions of severity honestly — an
inflated nit forces another fixer cycle, and a softened real defect
ships. See also [[verify-doc-cross-reference-headings]].
