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

**The same shape when a GUARD is widened, and the leftovers are
comments in `.sh` files.** On PR #231 round 2 the fixer widened a
reserved-mountpoint check from equality to an overlap relation and then
swept the narrow vocabulary ("lands on it or above it") out of the two
constants' comments and every `.md` surface — but the launcher's
*call-site* comment summarizing the same validator kept "lands on a
reserved … mountpoint" one file away. A doc sweep naturally visits
prose surfaces and the guard itself; the stragglers are the summary
comments elsewhere in the *code* (a call site, an emitted script's
header step list). Grep the narrow relation's vocabulary across the
whole plugin, `.sh` included, and grade what survives as a Low — the
code is right, only the sentence is narrow.

**Why:** on PR #224 round 1, the empty-intersection finding named
`pr-create` and `pr-link-issue`; the fixer added a case split there
including a "`B` empty — branch doesn't match the convention: use
`C`" arm. `pr-reviewer.md` step 2 parses the very same branch-name
grammar into the very same `B`, and got no such arm — a literal
execution on a non-convention branch (human-named, `dependabot/...`)
yields review set `C ∩ ∅ = ∅` and grades every legitimate closing
line as a rogue-line High. Round 2 caught it only by re-reading the
whole diff fresh and asking "who else parses this input?".

**A closed gap invites a stronger completeness claim than was
earned.** When a fix round closes the position a finding named, it
tends to rewrite the mechanism's own reach sentence from the call
sites it just wired — "covers both positions", "descends into every
X" — rather than from the grammar. Re-probe the OTHER positions the
same token can occupy before letting such phrasing stand; a reach
claim is refutable only by running the classifier, never by reading
the helper, whose doc comment is usually accurate about itself and
silent about its scoping. Two successive rounds each finding one more
uncovered position is the tell that the enumeration itself is the
defect and the reach needs to become a traversal with a
count-equality test.

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
