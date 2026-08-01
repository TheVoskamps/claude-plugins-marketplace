---
name: count-tally-class-includes-back-references
description: A core-principles §7 self-counting-list sweep must also catch post-list count words ("In either case", "If either input is missing"), not just the tally before the list
metadata:
  type: project
---

When sweeping a doc for core-principles §7 ("no number-of before a
self-counting list"), the class is not only the count word *introducing*
the list. Every later phrase that encodes the same count is in-class:
`In either case ...` after a two-bullet list, `If either input is
missing` after a two-item Inputs list, `all three of the above`.

**Why:** PR #211 (issue #207) burned an extra review round on exactly
this. An earlier round fixed the introducing tallies but left "These
failure shapes **both** fail it:" plus its trailing "In **either**
case", so a later round had to name it again. The back-reference rots
identically — add a third bullet and the prose is wrong.

**How to apply:** after fixing any §7 instance,
`grep -nE '\b(both|either|neither|two|three|four|all (three|four))\b'`
the whole file and judge each hit. Legitimate survivors: a count that
is a *constraint* rather than a tally (`**both** conditions hold: A
**and** B` is conjunction emphasis — one is insufficient — not a list
count). When the phrase sits in a section that sibling agent files also
have, check the siblings for the settled wording before inventing one
(`If any input is missing` is the sdlc-agent convention) — see
[[sweep-sibling-agent-guards]] and [[consistency-is-king]].
