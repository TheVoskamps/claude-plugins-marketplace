---
name: pr-diff
description: Fetch the full unified diff of a GitHub pull request (`gh pr diff <PR>`).
---

# PR Diff

Fetch the full unified diff of a GitHub pull request via
`gh pr diff <PR>`. This is the diff-fetch that PR consumers run before
reading a PR's changes: the `theorem-generator` and `theorem-disprover`
agents `sdlc:pr-review-pipeline` spawns, and `/sdlc:orchestrate`'s own
`issue-fixer` and `doc-updater`. Each declares this skill in its
`skills:` frontmatter rather than writing out a raw `gh pr diff` of its
own.

This skill is **GitHub-only by design**. It is a thin wrapper around
`gh pr diff`; there is no CodeCommit (or other source-control) branch,
and none is planned here — CodeCommit is deliberately out of scope for
this plugin.

## Invocation

```text
/pr-diff <pr-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.

## Repo-config

This skill reads no repo-config. `gh pr diff` needs only the PR number
and the current repo, both of which `gh` resolves on its own. (The
`source-control` value that a caller would previously have read to
choose between `gh` and CodeCommit is not consulted — this plugin is
GitHub-only, so there is nothing to branch on.)

## Execution

1. Fetch the diff:

   ```bash
   gh pr diff <PR>
   ```

   Emit the diff verbatim for the caller to read. Do not summarize or
   truncate it — the caller decides what to do with the full diff.

2. If `gh pr diff` errors (e.g. the PR number does not exist in this
   repo), surface the `gh` error verbatim rather than inventing a
   replacement message.
