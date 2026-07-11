---
name: self-approve-blocked-use-comment
description: When the gh identity is the PR author, --approve/--request-changes are blocked by GitHub; fall back to --comment and report the verdict in the body.
metadata:
  type: feedback
---

When posting a PR review, `gh pr review <n> --approve` (and
`--request-changes`) fails if the authenticated `gh` user is the PR's
own author:

```
failed to create review: GraphQL: Review Can not approve your own
pull request (addPullRequestReview)
```

**Why:** In this repo the human (`evoskamp`) both opens issue PRs and
runs the review flow under the same `gh` credential, so the reviewer
identity == author identity. GitHub forbids self-approval as a policy,
independent of review content.

**How to apply:** When `--approve`/`--request-changes` fails with that
exact GraphQL error, do NOT treat it as a review failure or retry.
Re-post the identical review body with `--comment` and put the verdict
line at the top of the body (e.g. "Review verdict: APPROVED (posted as
a comment because GitHub blocks the PR author from approving their own
PR)."). Still report the true verdict (APPROVED / NEEDS_CHANGES) plus
severity counts back to the orchestrator — the comment-only post is a
mechanical fallback, not a downgrade of the verdict.
