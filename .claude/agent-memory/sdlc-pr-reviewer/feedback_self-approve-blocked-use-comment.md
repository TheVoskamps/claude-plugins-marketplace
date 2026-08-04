---
name: self-approve-blocked-use-comment
description: Check gh api user vs the PR author first — the bot identity (claude-for-evoskamp) CAN --approve; only when identity == author fall back to --comment with the verdict in the body.
metadata:
  type: feedback
---

**Check identity before assuming the fallback.** Run
`gh api user --jq .login` and compare against the PR's `author.login`.
This repo's credential is now the per-user Claude App bot
(`claude-for-evoskamp`), which is NOT the author (`evoskamp`), so a
real `gh pr review <n> --approve --body-file <f>` posts cleanly —
verified on #227 round 4. The fallback below applies only when the two
logins match.

When posting a PR review, `gh pr review <n> --approve` (and
`--request-changes`) fails if the authenticated `gh` user is the PR's
own author:

```text
failed to create review: GraphQL: Review Can not approve your own
pull request (addPullRequestReview)
```

The `--request-changes` variant is blocked the same way but the message
differs, so match on the shape (`Can not ... on your own pull request`)
rather than one literal string:

```text
failed to create review: GraphQL: Review Can not request changes on
your own pull request (addPullRequestReview)
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

The `github-prs:pr-review-submit` skill documents this fallback only
for the `approve` verdict ("Self-review constraint (author cannot
`--approve`)"), so applying it to `request-changes` is on you — the
skill will not tell you to.

**Pass the body as a file, not a `--body` string.** A real review body
runs to hundreds of lines of Markdown full of backticks, quotes, and
`!`, and inlining it in `gh pr review --body "..."` invites shell
mangling. Write it with the Write tool to the repo's own
`.claude/tmp/review-<PR>.md` (which keeps the body with the worktree;
the harness scratchpad is allowed too — see
[[git-sandbox-via-script-file]]) and post with
`gh pr review <n> --comment --body-file <path>`. For the self-review
fallback, `printf 'APPROVED\n\n' > final.md && cat body.md >> final.md`
prepends the verdict line without re-quoting anything.
