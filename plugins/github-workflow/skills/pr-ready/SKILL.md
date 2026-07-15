---
name: pr-ready
description: Mark a draft GitHub pull request as ready for review (draft -> ready).
---

Flip a draft GitHub pull request into the ready-for-review state via
`gh pr ready <N>`. This is the transition the `/sdlc:orchestrate`
orchestrator performs in Phase 3, after the human confirms a PR is
good enough to end the review/fix loop — a draft PR cannot be
auto-merged, so keeping PRs draft until this point is what enforces
"the orchestrator never merges."

## Invocation

```text
/pr-ready <pr-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.

## Required repo-config: source-control

This skill only needs to know whether the repo is GitHub-backed — it
does not need the full repo-config reader contract. Read the
`source-control:` field directly from
`.claude/rules/repo-config.md`'s front-matter (a plain YAML
`key: value` line near the top of the file):

- `source-control: GitHub`, or the field is absent/unreadable but
  `gh` is available → proceed.
- `source-control: CodeCommit` → abort cleanly with: "CodeCommit
  source-control selected, but `/pr-ready` is GitHub-only and the
  CodeCommit path is not implemented." (This mirrors how
  `issue-developer` handles the CodeCommit PR-create path today.)

## Execution

1. Read `source-control` per "Required repo-config" above and abort
   if it is not GitHub.

2. Flip the PR to ready:

   ```bash
   gh pr ready <N>
   ```

   `gh` no-ops gracefully if the PR is already ready for review, so
   the command is safe to run more than once.

3. Report back a single line: the PR number and that it is now ready
   for review (e.g. `PR #<N> is ready for review`).
