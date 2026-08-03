---
name: fix-round-patches-named-files-not-the-class
description: A fixer round adds the new case arm only to the files the finding named; on round N enumerate every consumer of the same shared rule (repo CLAUDE.md sweep sections list them) and check the arm landed in each
metadata:
  type: reference
---

When a round-1 finding about a shared rule names specific files, the
fixer adds the remedy to exactly those files — not to every consumer
of the rule. The unnamed consumer is the one nobody re-opens on the
next round.

**Why:** on PR #224 round 1, the empty-intersection finding named
`pr-create` and `pr-link-issue`; the fixer added a case split there
including a "`B` empty — branch doesn't match the convention: use
`C`" arm. `pr-reviewer.md` step 2 parses the very same branch-name
grammar into the very same `B`, and got no such arm — a literal
execution on a non-convention branch (human-named, `dependabot/...`)
yields review set `C ∩ ∅ = ∅` and grades every legitimate closing
line as a rogue-line High. Round 2 caught it only by re-reading the
whole diff fresh and asking "who else parses this input?".

**How to apply:** when a fix adds a case/arm to some restatements of
a shared rule, enumerate ALL sites that parse or restate the same
input before grading the fix complete. A CLAUDE.md sweep section, when
one exists for that rule, is the enumeration; absent one, grep the
rule's wrap-proof needle. Where the shared rule has been extracted
into a skill the consumers invoke, there is only one site and the
question dissolves — check that the extraction is complete instead.
Related:
[[feedback_re-review-the-whole-diff-fresh]] and
[[reference_sweep-stale-behavior-comments-in-sibling-files]].
