---
name: pr-review-submit
description: Post a single GitHub PR review carrying both a verdict and a body — supplied inline or as a file — in one call, handling the self-review approve constraint.
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
/pr-review-submit <pr-number> <verdict> --body-file <path>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.
- `<verdict>` (required): one of `approve`, `request-changes`, or
  `comment`.
  - `approve` — the change is good to merge.
  - `request-changes` — the change needs work before merge.
  - `comment` — a verdict-less note (e.g. only Medium/Low findings, no
    approve/block yet).
- The review text, in **exactly one** of two forms — supplying both,
  or neither, is an error the skill aborts on rather than guessing:
  - `<body>` — the text inline. The caller supplies the full review
    body; this skill does not author findings.
  - `--body-file <path>` — a file holding that same text. This is the
    form a caller uses when the body would not survive the inline
    form's double-quoted `--body "<body>"`, which hands every backtick
    and `$` in it to the shell:
    `sdlc:theorem-based-pr-reviewer` stages its review under
    `.claude/tmp/<task-slug>/` and posts it by path, and a real
    round's body runs to tens of kilobytes of Markdown that quotes
    code throughout. GitHub caps a review body at 64 KB, which bounds
    what either form can carry.

Both forms work for all three verdicts, and map to `gh pr review`'s
own `--body` and `--body-file` flags respectively. Nothing else about
the skill's behavior differs between them.

## Repo-config

This skill reads no repo-config. The PR number, verdict, and body are
all supplied by the caller, and `gh` resolves the current repo on its
own. (The `source-control` value a caller would previously have read to
choose between `gh` and CodeCommit is not consulted — this plugin is
GitHub-only, so there is nothing to branch on.)

## Execution

Check the body form before posting anything. Exactly one of `<body>`
and `--body-file <path>` must be present:

- Both supplied — abort with: "Both an inline `<body>` and
  `--body-file <path>` were supplied. Pass exactly one."
- Neither supplied — abort with: "No review body was supplied. Pass
  either an inline `<body>` or `--body-file <path>`."

Either abort posts no review, rather than guessing which form the
caller meant.

Then post the review as a single call carrying both verdict and body.
The verdict picks the flag; the body form picks whether that call ends
in `--body "<body>"` or `--body-file <path>`:

| Verdict | Verdict flag |
| --- | --- |
| `approve` | `--approve` |
| `request-changes` | `--request-changes` |
| `comment` | `--comment` |

- **Inline body:**

  ```bash
  gh pr review <PR> <verdict-flag> --body "<body>"
  ```

- **Body file:**

  ```bash
  gh pr review <PR> <verdict-flag> --body-file <path>
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

In the `--body-file` form, compose the downgraded body as a **new**
file rather than editing the caller's — the caller may still need what
it handed you, and the skill has no mandate to rewrite it:

```bash
{ printf 'APPROVED\n\n'; cat <path>; } > .claude/tmp/<task-slug>/approved-body.md
gh pr review <PR> --comment --body-file .claude/tmp/<task-slug>/approved-body.md
```

Prefix the body with an explicit `APPROVED` verdict line so the review
still carries the verdict a real approval would have. Handling the
downgrade here is why `sdlc:theorem-based-pr-reviewer` can hand this
skill an
`approve` verdict unconditionally: reviewer and author are frequently
the same identity in the orchestrate flow, so the approve verdict has
to travel in the comment body.

Report back a single line: the PR number, the verdict actually posted,
and which body form carried it (and, if it was downgraded to an inline
`--comment` because of the self-review constraint, note that).
