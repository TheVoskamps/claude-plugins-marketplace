---
name: regrade-own-verified-and-check-round-narratives
description: A fixer correction that contradicts your own earlier Verified entry is usually right — re-read the source, not your grading; and check any memory's round-history narrative against gh pr view --json reviews plus git show <commit>:<path>
metadata:
  type: reference
---

Habits from PR #220 round 3, one incident:

- **Your own prior-round Verified entry is not evidence.** When a fix
  round corrects more than the finding named and thereby contradicts
  something you graded as accurate in an earlier round, the
  contradiction is usually right: re-read the source fresh and grade
  the fix on that, never on loyalty to your prior grading. Root cause
  in round 2: I graded a file "list-only" from `grep -n` line-number
  hits without reading the sentences at those lines —
  `lib/repo-config.md:257` was a hit, and the sentence there stated
  agent *behavior*. A grep hit list locates text; it does not read it.
- **Round-history claims are checkable, so check them.** An agent
  memory narrating "round N found / round M corrected" is verifiable
  from immutable surfaces: `gh pr view <PR> --json reviews`
  returns every posted review body (findings quoted verbatim), and
  `git show <commit>:<path>` proves whether a sentence changed in a
  given round. On #220 a fixer memory got its own PR's history wrong
  on all three specifics while its How-to-apply rule was correct —
  grade the false backstory as its own (usually Low) finding and say
  which sibling memory, if any, has the history right.

**How to apply:** in any follow-up round, before endorsing or flagging
a memory/PR-body sentence about what earlier rounds did, pull the
posted reviews and the per-commit blobs; and whenever your evidence
for a content claim is a grep hit, Read the surrounding sentence
before the claim goes in your review.

Related: [[re-review-the-whole-diff-fresh]],
[[read-branch-tip-via-git-show]],
[[verify-doc-cross-reference-headings]].
