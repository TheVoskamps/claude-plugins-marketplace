---
name: issue-ref-sweep-artifacts
description: How to audit a large mechanical "remove issue refs from comments" sweep — the artifact classes it produces and the scan that actually finds them
metadata:
  type: project
---

A commit that strips `#N` refs from a package's comments (PR #208's
`a81b2f8`: 515 comment lines across 24 files in `permission-gate`)
produces defects a line-based grep cannot see, because the damage
straddles the comment's line wrapping.

**Artifact class 1 — mechanical substitution leaves a hole.** The `#N`
token was a noun-phrase head, and deleting it stranded the article or
duplicated the noun:

- `which #193 designates safe` → `which the / designates safe` (the
  word "designates" starts the next comment line, so
  `grep "the designates"` finds nothing).
- `The under-specified #148/#127 escapes used to leave…` →
  `The under-specified escape / escapes used to leave…`.

**Artifact class 2 — the ref becomes a danglingly vague pointer.**
`per the issue's explicit requirement`, `this issue widens`,
`this issue exists to fix`. These pass the `#\d+` guard while still
making the reader fetch a ticket — worse than the numbered form,
because now the ticket is unnamed. In *test* files this is fine by
design: the enclosing test name carries the number
(`TestHomeVarResolvesLikeTilde_156`), so "the issue's acceptance
criteria" resolves. In *production* code there is no such anchor, so
fix it there and leave the test files alone.

**How to apply:** don't grep line-by-line. Join each contiguous run of
`//` lines into one string per block and scan the joined text; and
separately extract the sweep commit's old→new comment-line pairs
(`git show <sha> -U0`, keeping hunks whose removed side matched
`#\d+`) and read the production-code ones. Both scans are cheap and
each found one artifact the other missed. Everything else in that
sweep was careful and accurate — expect a ~1% defect rate, not a
rewrite.

Related: [[project_guardrails-package-comment-sweep]] (the same
package's habit of duplicating one invariant across call sites),
[[project_guardrails-permgate-docs-locality]].
