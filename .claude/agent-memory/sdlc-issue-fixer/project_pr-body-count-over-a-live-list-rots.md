---
name: pr-body-count-over-a-live-list-rots
description: A PR-body Testing claim that states a COUNT of a git-derived file list is re-falsified every fix round; state the coverage, never the number
metadata:
  type: project
---

A PR-body claim of the shape "lint ran on all N changed Markdown
files" is falsified by the next round, because every fixer and
doc-updater round commits agent-memory files that join
`git diff --name-only origin/main...HEAD -- '*.md'`. Issue #259's PR
was pulled up on the same sentence twice: 13 at one head, 17 at the
next.

**Why:** the number quantifies over a list the branch itself keeps
growing, so re-running the lint fixes the verdict but not the tally.
Only deleting the number makes the sentence stable — "on every changed
Markdown file at head (the full `git diff --name-only
origin/main...HEAD -- '*.md'` list)".

**How to apply:** when a Testing bullet you write or inherit counts a
git-derived set, drop the count and name the command that produces the
set. Re-run the check over the current list in the same round. This is
the PR-body instance of the global no-count-before-a-self-counting-list
rule, and it is why [[pr-body-is-a-swept-surface]] covers the Testing
section too, not only What changed / Decisions.
