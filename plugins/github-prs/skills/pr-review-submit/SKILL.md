---
name: pr-review-submit
description: Post a single GitHub PR review carrying both a verdict and a body — supplied inline or as a file — in one call, handling the self-review constraint that leaves an author only a comment.
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
/pr-review-submit <pr-number> --verdict <approve|request_changes|comment> <body>
/pr-review-submit <pr-number> --verdict <approve|request_changes|comment> --body-file <path>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.
- `--verdict <value>` (required, exactly once): one of `approve`,
  `request_changes`, or `comment`. These are GitHub's own review
  actions, in the skill's spelling; nothing else is a verdict here.
  - `approve` — the change is good to merge.
  - `request_changes` — the change needs work before merge.
  - `comment` — a verdict-less note (e.g. only Medium/Low findings, no
    approve/block yet).
- The review text, in **exactly one** of the forms below — supplying
  both, or neither, is an error the skill aborts on rather than
  guessing:
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

Both forms work for every verdict, and map to `gh pr review`'s
own `--body` and `--body-file` flags respectively. They differ only in
how the verdict line reaches the body — see "Execution".

## Repo-config

This skill reads no repo-config. The PR number, verdict, and body are
all supplied by the caller, and `gh` resolves the current repo on its
own. (The `source-control` value a caller would previously have read to
choose between `gh` and CodeCommit is not consulted — this plugin is
GitHub-only, so there is nothing to branch on.)

## Execution

Check the arguments before posting anything. Exactly one `--verdict`
must be present, and exactly one of `<body>` and `--body-file <path>`:

- No `--verdict` — abort with: "No `--verdict` was supplied. Pass
  exactly one of `approve`, `request_changes`, or `comment`."
- More than one `--verdict` — abort with: "`--verdict` was supplied
  more than once, as `<first value>` and `<second value>`. Pass exactly
  one of `approve`, `request_changes`, or `comment`."
- A `--verdict` value outside those — abort with: "`<value>` is
  not a verdict. Pass `approve`, `request_changes`, or `comment`."
- Both body forms supplied — abort with: "Both an inline `<body>` and
  `--body-file <path>` were supplied. Pass exactly one."
- Neither body form supplied — abort with: "No review body was
  supplied. Pass either an inline `<body>` or `--body-file <path>`."

Every abort posts no review, rather than guessing what the caller
meant.

The verdict then decides, at once, the `gh` flag, the line the body
opens with, and the GitHub review state the call creates. The
verdict-line column holds unconditionally; the review
state is what it says here only when the flag goes through, and the
self-review constraint below — the one case that replaces the flag —
lands `commented` instead:

| `--verdict` | Verdict flag | Body's first line | Review state |
| --- | --- | --- | --- |
| `approve` | `--approve` | `APPROVED` | `approved` |
| `request_changes` | `--request-changes` | `CHANGES_REQUESTED` | `changes_requested` |
| `comment` | `--comment` | `COMMENTED` | `commented` |

The verdict line goes at the head of the body on **every** post,
downgraded or not, so a reader of the body never has to work out
whether the self-review constraint below fired. It is the bare verdict
word and nothing else: a reader can already see on the PR whether the
round arrived as a review or as a comment, and a `commented` state
dressed up as meaning `changes_requested` is worse than the plain
word.

Post the review as a single call carrying both verdict and body. The
body form picks whether that call ends in `--body "<body>"` or
`--body-file <path>`:

- **Inline body:**

  ```bash
  gh pr review <PR> <verdict-flag> --body "<verdict-line>

  <body>"
  ```

- **Body file:** compose the posted body as a **new** file rather than
  editing the caller's — the caller may still need what it handed you,
  and the skill has no mandate to rewrite it. Write it under
  `.claude/tmp/<task-slug>/`, where `<task-slug>` is the calling
  agent's own scratch slug, and create that directory first: the
  caller's `<path>` may sit anywhere, so nothing guarantees it already
  exists, and a bare redirect into a missing directory fails.

  ```bash
  mkdir -p .claude/tmp/<task-slug>
  { printf '<verdict-line>\n\n'; cat <path>; } > .claude/tmp/<task-slug>/posted-body.md
  gh pr review <PR> <verdict-flag> --body-file .claude/tmp/<task-slug>/posted-body.md
  ```

### Self-review constraint (an author may post only a comment)

**Both** verdict flags are refused when the reviewer is the PR author.
The refusal is GitHub's, not a client-side check: `gh` sends the
review either way, and the server returns the refusal on the
`addPullRequestReview` mutation, which `gh` surfaces around this text:

```text
Can not approve your own pull request
Can not request changes on your own pull request
```

Only `COMMENT` is open to an author. Settle which case you are in
**before** posting, rather than posting a flag and reading the refusal
back — the failed call leaves nothing on the PR, so a caller that
learns of the block from the error has posted no review at all. Read
the authenticated login and the PR's author:

```bash
gh api user --jq .login
gh pr view <PR> --json author -q .author.login
```

Each returns a bare login string, and the reviewer is the author when
those two strings are equal. The comparison is plain equality and
nothing more: the identity acting here is an ordinary GitHub user
account, so there is no `[bot]` suffix or other App-installation shape
to normalize away.

When they are equal, `approve` and `request_changes` alike post with
`--comment` in place of their own flag — everything else about the
call, the verdict line included, is unchanged, which is what carries
the verdict a blocked flag would have carried. `comment` already uses
that flag and is unaffected.

Handling the downgrade here is why `sdlc:theorem-based-pr-reviewer`
can hand this skill any verdict unconditionally: reviewer and author
are frequently the same identity in the orchestrate flow, so a
blocking verdict has to travel in the comment body.

Report back a single line: the PR number, the verdict requested, the
GitHub review state the call actually created (`approved`,
`changes_requested`, or `commented`), and which body form carried it.
The state is what a caller gating on the platform's view of the PR
needs: a downgraded review carries state `commented`, so GitHub sees
no blocking review whatever the body says.
