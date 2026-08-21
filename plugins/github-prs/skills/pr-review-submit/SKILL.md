---
name: pr-review-submit
description: Post a single GitHub PR review carrying both a verdict and a body in one call, handling the self-review approve constraint.
---

# PR Review Submit

Post a **single** pull-request review on a GitHub PR, carrying both a
verdict and a review body in one `gh pr review` call. This is the
review-submission the `/sdlc:orchestrate` flow previously performed as
a raw `gh pr review` of its own; the skill now owns it, and
`sdlc:theorem-based-pr-reviewer` is the caller that posts through it.

Posting the verdict and body in a single call is deliberate: a
separate `--comment` followed by an `--approve`/`--request-changes`
would create two notifications for one review. This skill always emits
exactly one review.

This skill is **GitHub-only by design**. It is built directly on
`gh pr review`; there is no CodeCommit (or other source-control)
branch, and none is planned here — CodeCommit is deliberately out of
scope for this plugin.

## Invocation

```text
/pr-review-submit <pr-number> <verdict> <body>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.
- `<verdict>` (required): one of `approve`, `request-changes`, or
  `comment`.
  - `approve` — the change is good to merge.
  - `request-changes` — the change needs work before merge.
  - `comment` — a verdict-less note (e.g. only Medium/Low findings, no
    approve/block yet).
- `<body>` (required): the review text. The caller supplies the full
  review body; this skill does not author findings.

## Repo-config

This skill reads no repo-config. The PR number, verdict, and body are
all supplied by the caller, and `gh` resolves the current repo on its
own. (The `source-control` value a caller would previously have read to
choose between `gh` and CodeCommit is not consulted — this plugin is
GitHub-only, so there is nothing to branch on.)

## Execution

Post the review as a single call carrying both verdict and body:

- **Approve:**

  ```bash
  gh pr review <PR> --approve --body "<body>"
  ```

- **Request changes:**

  ```bash
  gh pr review <PR> --request-changes --body "<body>"
  ```

- **Comment-only:**

  ```bash
  gh pr review <PR> --comment --body "<body>"
  ```

### Self-review constraint (author cannot `--approve`)

`gh` blocks `--approve` when the reviewer is the PR author
(`Can not approve your own pull request`). When the requested verdict
is `approve` **and** the current `gh` user is the PR's author, do not
fail — state the approve verdict **inline** via `--comment` instead:

```bash
gh pr review <PR> --comment --body "APPROVED

<body>"
```

Prefix the body with an explicit `APPROVED` verdict line so the review
still carries the verdict a real approval would have. Handling the
downgrade here is why `sdlc:theorem-based-pr-reviewer` can hand this
skill an
`approve` verdict unconditionally: reviewer and author are frequently
the same identity in the orchestrate flow, so the approve verdict has
to travel in the comment body.

Report back a single line: the PR number, the verdict actually posted
(and, if it was downgraded to an inline `--comment` because of the
self-review constraint, note that).
