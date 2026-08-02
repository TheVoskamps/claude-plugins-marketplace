---
name: round-history-is-verifiable-not-recalled
description: never write "round N found / round M fixed" from session recollection — a fixer sees only its own round, and the true history is two commands away (gh pr view --json reviews, git show <commit>:<path>)
metadata:
  type: project
---

A memory or PR-body sentence narrating what earlier rounds of a PR did
is a checkable claim, not colour. Two immutable surfaces settle it:

- `gh pr view <PR> --json reviews --jq '.reviews[] | ...'` returns every
  posted review body verbatim, so "which member did round N name?" and
  "did round N flag this at all?" are answerable exactly.
- `git show <commit>:<path>` proves whether a given sentence actually
  changed in a given round; `git log --oneline --all -- <path>` lists
  the only commits that could have changed it.

**Why:** a fixer is spawned per round and sees one review brief, so its
sense of "rounds 1 and 2 each did X" is inference, not observation. On
PR #220 I wrote a backstory that was wrong on every specific — it said
three fix rounds when there had been one, and credited round 1 with a
finding whose Verified list had endorsed the sentence — and it cost a
whole extra round to correct. `~/.claude/rules/label-uncertainty.md`
already covers this: PR history is a volatile surface with other
writers, so re-read the territory rather than asserting the map.

**How to apply:** before any sentence of the form "round N found /
round M corrected" goes into a memory, a commit message, or a PR body,
pull the reviews and the per-commit blobs and match each specific.
Cheapest correct move is usually to drop the round numbering entirely
and describe the defect and its fixing commit — a claim that stays true
however the rounds are counted. When you do keep the narrative, name
the commit SHAs so the next reader can check it in one command. The
false-backstory class also propagates: the frontmatter `description`
and the `MEMORY.md` hook restate the same claim, so correct all three
sites together (same shape as
[[count-tally-class-includes-back-references]]).

Related: [[shared-predicate-list-is-one-claim]] (the entry whose
backstory this rule came out of),
[[staleness-check-both-ends-same-source]].
