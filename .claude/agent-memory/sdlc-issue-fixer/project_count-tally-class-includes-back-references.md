---
name: count-tally-class-includes-back-references
description: A core-principles §7 self-counting-list sweep must also catch post-list count words ("In either case"), YAML frontmatter descriptions, and non-Markdown comments — and should grade hits against the adjudicated in/out-of-class boundary restated here rather than instinct
metadata:
  type: project
---

When sweeping a doc for core-principles §7 ("no number-of before a
self-counting list"), the class is not only the count word *introducing*
the list. Every later phrase that encodes the same count is in-class:
`In either case ...` after a two-bullet list, `If either input is
missing` after a two-item Inputs list, `all three of the above`. A
back-reference rots identically to the introducing tally — add another
bullet and the prose is wrong. Fixing the introducing tally while
leaving its trailing back-reference is what burns an extra review
round on this class.

**Scope the grep to the whole PR, not the Markdown.** §7 governs prose
wherever it lives — config comments (a `.jsonc` comment reading "minus
the two below. / Both reflect ..." above a list of disabled rules is
in-class), code comments, the PR body — so sweep every file the PR
touched, not just `*.md`.

**Frontmatter is prose too.** In an agent-memory entry the YAML
`description:` is a swept surface, and so is the entry's `MEMORY.md`
hook. A flagged body line ("Two immutable surfaces settle it:")
routinely has a sibling count a line away in the same file's
`description:` ("the true history is two commands away (cmd-a,
cmd-b)") — a count over a parenthetical enumeration. Fix body,
`description:`, and the index hook in the same pass.

**The "list" need not be a Markdown list.** Two shapes that read as
prose still enumerate, and their introducing tally rots the same way:
an options menu written inside a fenced `text` block (`offer two
paths` above a `1. … 2. …` prompt the skill prints verbatim), and a
run of bold-lead paragraphs (`Two paths, preferred first:` above
`**Preferred — …**` / `**Fallback — …**`). A back-reference *into* a
fenced block's own numbered list is in-class too (`y to do all three`
under a printed `1./2./3.`), while the same triple named inline as a
conjunction in running prose (`commits, pushes, and opens a PR … on
one approval covering all three`) is conjunction emphasis and stays.

**Don't re-derive the boundary — apply the adjudicated one.** The
settled in-class test is: does the number survive deleting the
adjacent list? If it does, it carries independent meaning and stays.
Explicitly out of class: frozen-history narrative counts, counts of
structure a *different* document enumerates, conjunction emphasis, and
quoted examples of the defect pattern. "Only one X:" before a list IS
in class — "only" does not rescue a numeral that is a tally, and the
fix drops the numeral. Grading a §7 sweep against that test instead of
your own instinct is what keeps a sweep from "fixing" a survivor and
churning a round on it.

**How to apply:** after fixing any §7 instance,
`grep -nE '\b(both|either|neither|two|three|four|all (three|four))\b'`
the whole file and judge each hit. Legitimate survivors: a count that
is a *constraint* rather than a tally (`**both** conditions hold: A
**and** B` is conjunction emphasis — one is insufficient — not a list
count). When the phrase sits in a section that sibling agent files also
have, check the siblings for the settled wording before inventing one
(`If any input is missing` is the sdlc-agent convention) — see
[[sweep-sibling-agent-guards]] and [[consistency-is-king]].
