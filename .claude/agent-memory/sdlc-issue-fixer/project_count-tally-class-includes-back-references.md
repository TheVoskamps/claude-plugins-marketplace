---
name: count-tally-class-includes-back-references
description: A core-principles §7 self-counting-list sweep must also catch post-list count words ("In either case"), YAML frontmatter descriptions, and non-Markdown comments — and should grade hits against the pr-reviewer's adjudicated in/out-of-class boundary rather than instinct
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

**Scope the grep to the whole PR, not the Markdown.** A later round of
the same PR found the identical shape in a `.jsonc` comment ("minus the
**two** below. / **Both** reflect …" above the list of disabled rules).
§7 governs prose wherever it lives — config comments, code comments,
the PR body — so sweep every file the PR touched, not just `*.md`.

**Frontmatter is prose too.** In an agent-memory entry the YAML
`description:` is a swept surface: on PR #220 round 5 the flagged body
line ("Two immutable surfaces settle it:") had a sibling in the same
file's `description:` ("the true history is **two** commands away
(cmd-a, cmd-b)") — a count over a parenthetical enumeration one line
from the one the reviewer named. Fix body, `description:`, and the
`MEMORY.md` hook in the same pass.

**Don't re-derive the boundary — read the adjudicated one.** The
`sdlc-pr-reviewer` sibling memory
`project_only-one-before-list-is-in-class.md` carries the settled
in-class test (does the number survive deleting the adjacent list?)
plus the explicit out-of-class list: frozen-history narrative counts,
counts of structure a *different* document enumerates, conjunction
emphasis, and quoted examples of the defect pattern. Grading a §7 sweep
against that file instead of your own instinct is what keeps a sweep
from "fixing" a survivor and churning a round on it.

**How to apply:** after fixing any §7 instance,
`grep -nE '\b(both|either|neither|two|three|four|all (three|four))\b'`
the whole file and judge each hit. Legitimate survivors: a count that
is a *constraint* rather than a tally (`**both** conditions hold: A
**and** B` is conjunction emphasis — one is insufficient — not a list
count). When the phrase sits in a section that sibling agent files also
have, check the siblings for the settled wording before inventing one
(`If any input is missing` is the sdlc-agent convention) — see
[[sweep-sibling-agent-guards]] and [[consistency-is-king]].
