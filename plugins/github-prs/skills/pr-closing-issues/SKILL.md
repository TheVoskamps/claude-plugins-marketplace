---
name: pr-closing-issues
description: Report the set of issues a GitHub pull request's body closes, by applying the closing-keyword syntax to the fetched body. The one closing-line parser in this marketplace.
---

# PR Closing Issues

Answer one question: **which issues does this PR close?** Fetch the
pull request's body and report every issue a closing keyword in it is
aimed at.

This skill is the only parser of closing lines in this marketplace.
Its consumers — `github-prs:pr-link-issue` for its idempotency check,
`sdlc:pr-review-pipeline` for its claim when run standalone on a bare PR
number, and `/sdlc:orchestrate` for the member list its end-of-loop
status flip acts on — invoke it rather than each describing the scan
again. Skill invocation crosses the plugin sandbox boundary that a
`Read` cannot (see `docs/plugin-authoring-constraints.md` → "Skill
invocation is global and namespaced"). Each consumer keeps its own
action on the result; none re-derives the result itself.

`github-prs:pr-create` is not a consumer: it *writes* closing lines
from a set it was given, and never reads them back.

This skill is **GitHub-only by design**. It is built directly on
`gh pr view`, and the syntax below is GitHub's; there is no CodeCommit
(or other source-control) branch, and none is planned here.

## Invocation

```text
/pr-closing-issues <pr-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.

A single-PR primitive. A caller holding several PR numbers invokes it
once per PR.

## Repo-config

This skill reads no repo-config. `gh pr view` needs only the PR number
and the current repo, both of which `gh` resolves on its own, and the
closing-keyword syntax below is GitHub's rather than anything the repo
configures.

## The syntax

`rules/git-workflow.md` → "Issue References" is the normative
statement and this skill's authority. It is applied here, once, so
that no consumer applies it again.

A **closing keyword** — `close`, `closes`, `closed`, `fix`, `fixes`,
`fixed`, `resolve`, `resolves`, `resolved`, case-insensitive —
**immediately followed by** an issue reference closes that issue when
the PR merges into the repository's default branch. The reference
forms are `#N`, `owner/repo#N`, `GH-N`, and a full issue URL
(`https://github.com/<owner>/<repo>/issues/N`).

"Immediately followed by" is the whole rule, and the whole trap:

- **Each reference needs its own keyword.** `Closes #196, #201` closes
  `#196` and leaves `#201` unlinked, so report `196` alone. This is
  why the writers in this plugin emit one line per issue.
- **The parser allows nothing meaningful in between.** `Closes
  Dependabot alert #88` discards the intervening words and closes
  issue `88` — report `88`. Words that look like they scope the
  reference do not.
- **A keyword with no adjacent issue reference closes nothing.** "This
  closes a long-standing gap", `fix_bug.py`, `def resolve_path()` —
  report nothing for any of them.
- **A reference with no keyword before it closes nothing.**
  `References: #42` is the canonical non-closing form and is never
  part of the answer.

## Execution

1. Fetch the PR body:

   ```bash
   gh pr view <PR> --json number,body
   ```

2. Scan the body for every keyword-then-reference occurrence per "The
   syntax" above, and collect the issue numbers as a **set** — a body
   that closes the same issue on two lines closes it once, so report
   it once.

3. Report per "Output" below. Report nothing else: this skill makes no
   decision about whether the set is the right one. A caller that
   needs the set checked against the branch's own issue set gets that
   from `/git-tools:git-issues-from-branch`, which owns the
   reconciliation rule.

4. If `gh pr view` errors (e.g. the PR number does not exist in this
   repo), surface the `gh` error verbatim rather than inventing a
   replacement message.

## Output

One line, naming the PR and the set in ascending numeric order:

```text
PR #224 closes issues 196, 201, 206
```

A body with no closing line at all is a normal outcome, not an error:

```text
PR #224 closes no issues
```
