---
name: pr-body-is-a-swept-surface
description: A fix round that changes an approach the PR body describes must update the body's What changed / Decisions bullets in the same round — the body is in-scope for the sweep, not just the code
metadata:
  type: feedback
---

The PR body is a **surface that goes stale**, and it is in-scope for
the same sweep as the code. When a fix round reverses a stated
decision, or replaces a mechanism the body names, update the affected
`## What changed` / `## Decisions` bullets in that same round.

**Why:** on PR #211 the round-3 review flagged a Decisions bullet that
still read "Left two unrelated pre-existing nits alone … Happy to file
a follow-up" — the branch had already swept that whole class three
commits earlier. Pulling on it surfaced a sibling instance nobody had
flagged: two more bullets still described a
`git rev-parse origin/<branch-name>` staleness check that a later
commit had replaced with `gh pr view <PR> --json headRefOid`. The body
is what the human reads to decide whether to merge, and it is what the
squash/merge commit carries into history, so a stale bullet is a
durable false claim, not a cosmetic nit. Nothing in CI checks it, and
the reviewer only sees it if they diff prose against code — which is
why it survives rounds.

**How to apply:** after implementing a fix that changes an approach the
body describes, re-read the *live* body (`gh pr view <N> --json body
--jq .body`, never your memory of it — other agents edit it too), and
scan for bullets asserting the old mechanism or an
"I left this alone / happy to follow up" offer the branch has since
acted on. Edit with `gh pr edit <N> --body-file <scratch>`, then
`diff -u` the old and new bodies before and after to prove only the
intended bullets moved. Preserve the `Closes #<own-issue>` line
verbatim and add no other closing keyword — see the closing-keyword
rule in `git-workflow.md`. Note that a stale bullet is a *class*, so
per core-principles rule 8 fix every instance in the body, not only
the one the reviewer cited — that is exactly how the extra two bullets
here got caught. This is an instance of
[[verify-territory-not-relay]]; related sweep lore in
[[sweep-sibling-agent-guards]].
