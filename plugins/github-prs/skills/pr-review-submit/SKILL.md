---
name: pr-review-submit
description: Post a single GitHub PR review carrying both a verdict and a body — supplied inline or as a file — in one call, handling the self-review constraint that leaves an author only a comment.
---

# PR Review Submit

Post a **single** pull-request review on a GitHub PR, carrying both a
verdict and a review body in one call. This is the review-submission
the `/sdlc:orchestrate` flow previously performed as a raw review call
of its own; the skill now owns it, and
`sdlc:theorem-based-pr-reviewer` is the caller that posts through it.

Posting the verdict and body in a single call is deliberate: a
separate comment followed by an approval or a change request would
create two notifications for one review. This skill always emits
exactly one review.

This skill is **GitHub-only by design**. Its script posts through
`gh`; there is no CodeCommit (or other source-control) branch, and
none is planned here — CodeCommit is deliberately out of scope for
this plugin.

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
    form a caller uses when the body would not survive being spelled
    inline on a command line, where the shell reads every backtick and
    `$` in it: `sdlc:theorem-based-pr-reviewer` stages the review
    summary it posts under `.claude/tmp/<task-slug>/` and posts it by
    path, and that summary carries a backticked state-relative detail
    path on every theorem and finding line, under the
    `${XDG_STATE_HOME:-$HOME/.local/state}` root it names once. GitHub
    caps a review body at 64 KB, which bounds what either form can
    carry.

Both forms work for every verdict.

## Repo-config

This skill reads no repo-config. The PR number, verdict, and body are
all supplied by the caller, and the current repo is resolved on its
own. (The `source-control` value a caller would previously have read to
choose between `gh` and CodeCommit is not consulted — this plugin is
GitHub-only, so there is nothing to branch on.)

## Execution

Run the bundled script, spelled as a bare name, with the arguments you
were given. Pass an inline body as a single-quoted argument, or — when
it holds a single quote, a backtick or a `$` — write it to a file with
the Write tool and pass that path instead:

```bash
pr-review-submit <pr-number> --verdict <verdict> '<body>'
pr-review-submit <pr-number> --verdict <verdict> --body-file <path>
```

The script checks its arguments before posting anything, and every
refusal posts no review rather than guessing what the caller meant.
Each is a usage error, and stderr names which of these it is:

- No `--verdict`.
- More than one `--verdict`; the message names the first two values.
- A `--verdict` value other than `approve`, `request_changes`, or
  `comment`; the message names the value.
- Both body forms supplied.
- Neither body form supplied.

The verdict then decides, at once, the review action, the line the body
opens with, and the GitHub review state the call creates. The
verdict-line column holds unconditionally; the review state is what it
says here only when the action goes through, and the self-review
constraint below — the one case that replaces the action — lands
`commented` instead:

| `--verdict` | Review action | Body's first line | Review state |
| --- | --- | --- | --- |
| `approve` | approve | `APPROVED` | `approved` |
| `request_changes` | request changes | `CHANGES_REQUESTED` | `changes_requested` |
| `comment` | comment | `COMMENTED` | `commented` |

The verdict line goes at the head of the body on **every** post,
downgraded or not, followed by a blank line and the caller's text, so a
reader of the body never has to work out whether the self-review
constraint below fired. It is the bare verdict word and nothing else: a
reader can already see on the PR whether the round arrived as a review
or as a comment, and a `commented` state dressed up as meaning
`changes_requested` is worse than the plain word. In the file form the
script composes the posted body itself and leaves the caller's file
untouched.

### Self-review constraint (an author may post only a comment)

**Both** verdict actions are refused when the reviewer is the PR
author. The refusal is GitHub's, not a client-side check: the server
returns it on the `addPullRequestReview` mutation, and `gh` prints it
as, for example:

```text
GraphQL: Review Can not approve your own pull request (addPullRequestReview)
```

The script reads no login to predict this. It posts with the verdict's
own action, and only when that call fails with the refusal for **that**
action — `Can not approve your own pull request` for `approve`,
`Can not request changes on your own pull request` for
`request_changes` — does it post again as a comment. The refused call
leaves nothing on the PR, so the comment is the only review. Everything
else about the second call, the verdict line included, is unchanged,
which is what carries the verdict the refused action would have
carried. `comment` is never refused this way. Any other failure of the
first call stays a failure: nothing is reposted, and it exits 3.

Handling the downgrade here is why `sdlc:theorem-based-pr-reviewer`
can hand this skill any verdict unconditionally: reviewer and author
are frequently the same identity in the orchestrate flow, so a
blocking verdict has to travel in the comment body.

## Output and exit status

After posting, the script re-reads the newest review on the PR,
whoever left it, and checks it is not the one that was newest before
the post, and that it carries the expected state and the body it
posted. A review someone else leaves in between fails that check.

- **Exit 0** — stdout is one line: the PR number, the verdict
  requested, the GitHub review state the call actually created
  (`approved`, `changes_requested`, or `commented`), and which body
  form carried it. Report it back. The state is what a caller gating on
  the platform's view of the PR needs: a downgraded review carries
  state `commented`, so GitHub sees no blocking review whatever the
  body says.
- **Exit 1** — the review did not land as posted: no new review
  appeared, or it carries another state or another body. Stderr says
  which. Report the failure rather than posting again.
- **Exit 2** — a usage error, one of the refusals above; nothing was
  posted.
- **Exit 3** — a `gh` call failed, and gh's own error is on stderr
  above the script's line. Surface it verbatim.
