---
name: regrade-own-verified-and-check-round-narratives
description: A fixer correction that contradicts your own earlier Verified entry is usually right — re-read the source, not your grading; and check any memory's round-history narrative against gh pr view --json reviews plus git show <commit>:<path>
metadata:
  type: reference
---

- **Your own prior-round Verified entry is not evidence.** When a fix
  round corrects more than the finding named and thereby contradicts
  something you graded as accurate in an earlier round, the
  contradiction is usually right: re-read the source fresh and grade
  the fix on that, never on loyalty to your prior grading. The
  recurring root cause is grading a file from `grep -n` hits without
  reading the sentences at those lines — a grep hit list locates text,
  it does not read it, and the sentence at the hit routinely says the
  opposite of the grade.
- **Round-history claims are checkable, so check them.** An agent
  memory narrating "round N found / round M corrected" is verifiable
  from immutable surfaces: `gh pr view <PR> --json reviews` returns
  every posted review body with findings quoted verbatim, and
  `git show <commit>:<path>` proves whether a sentence changed in a
  given round. A memory whose How-to-apply rule is sound can still be
  wrong on every specific of its own PR's history — grade the false
  backstory as its own (usually Low) finding, and say which sibling
  memory, if any, has the history right.

- **A branch can falsify one of YOUR memory entries, and that lands on
  you, not on the scrubber.** When a round's own change makes an entry
  under `sdlc-pr-reviewer/` wrong, the other agents will (rightly)
  route it back rather than editing another agent's memory — #231
  rounds 6 and 7 each did. Correct it in that round's own memory
  commit, in place: fix the falsified sentence, say the branch
  falsified it, keep the parts that survive, and update the `MEMORY.md`
  one-liner when the falsified clause is quoted there too. Do not file
  it as a finding against the PR and do not defer it to
  `agent-memory-scrubber` — an uncorrected entry is loaded verbatim by
  the next run.

**The between-rounds trap:** a fix round runs after review round N and
before round N+1, so "which round is this?" has no answer in the round
vocabulary — SKILL.md defines a round as one `pr-reviewer` run, and the
fixer sits in the unnumbered gap. A fixer trying to follow the
numbering rule still misdates that gap, attributing one event to the
review that posted it in a commit message while dating the same event
a round later in its memory entry. When reviewing (or writing) such
prose, expect events to be attributed to the review that posted them
or to a commit SHA; a bare number for the gap itself is the tell.

**How to apply:** in any follow-up round, before endorsing or flagging
a memory or PR-body sentence about what earlier rounds did, pull the
posted reviews and the per-commit blobs; and whenever your evidence
for a content claim is a grep hit, Read the surrounding sentence
before the claim goes into your review.

Related: [[re-review-the-whole-diff-fresh]],
[[read-branch-tip-via-git-show]],
[[verify-doc-cross-reference-headings]].
