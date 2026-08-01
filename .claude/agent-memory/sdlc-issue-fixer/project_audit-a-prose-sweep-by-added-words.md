---
name: audit-a-prose-sweep-by-added-words
description: a "delete X from every comment" sweep breaks prose exactly where the removed token was the head of a noun phrase; find those by pairing removed/added hunks and keeping only the ones where the sweep ADDED words, then re-read comment blocks JOINED
metadata:
  type: project
---

A mechanical sweep over prose ("remove every issue reference from the
Go comments") produces two very different kinds of hunk, and only one
of them can be wrong:

- **Pure deletion** — `foo (#125). Bar` → `foo. Bar`. Safe by
  construction; there are hundreds of these and reading them is waste.
- **Substitution** — the removed token was load-bearing (the head of a
  noun phrase, the subject of the sentence, the thing closing a
  parenthetical), so the sweeper had to put *something* in its place.
  Every artifact lives here.

**Why:** on PR #208 (issue #193) the sweep touched 604 ref-bearing
comment lines across 24 files. Two separate audits — a doc-updater's
and a pr-reviewer's — each found artifacts the other missed, and a
third round still found five more. Reading all 470 ref-bearing hunks
is unaffordable; reading the ~212 where words were *added* is not, and
it is where 100% of the artifacts were.

**How to apply:** two passes, both cheap, both scriptable (I kept the
scripts under `.claude/tmp/`; rewrite them, they are ~40 lines each):

1. `git show -U0 <sweep-sha> -- <dir>` and pair each run of `-` lines
   with the `+` lines that replaced it. Join each side into one string
   (the hunks are wrapped prose, so a phrase spans lines). Keep the
   pair only if the removed side matched `#\d+` **and** the added side
   contains a word absent from the removed side. Read those.
2. Independently, re-extract every comment block in the current tree,
   join it with the wraps closed up, and grep the joined text for
   dangling-reference shapes: `\bFix \d`, `\bdecision \d`, `\brow \d`,
   `\bcase \(\w\)`, `, prefix\)`, `\bbefore it\b`, a `which` with no
   verb after it. Both passes must come back clean.

The five artifacts this found all had the same shape — the removed
`#N` was the head of its phrase. `"the former isGitConfigPath <ref>
rule"` became `"…check, which / rule to the whole .git/ tree"`;
`"…bundled-skills tree, <ref>)"` became `"…tree, / prefix)"`;
`"before <ref> allowlisted it"` became `"before it / allowlisted it"`;
and `"<ref> Fix 2"` became a bare `"Fix 2"` naming a fix list that
nothing identifies.

**Corollary for the regression guard.** A line-based `#\d+` guard
structurally cannot see a reference the wrap splits. Join the comment
block with the line breaks *closed up* (not space-joined) before
matching: that strictly subsumes the per-line scan and adds no false
positives, because the pattern needs a digit immediately after the `#`.

See also [[sweep-sibling-agent-guards]] for the other half of this
lesson — sweeping a rule's exception clause, not just its headline.
