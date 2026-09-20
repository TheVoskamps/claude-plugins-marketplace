---
name: pr-ready
description: Mark a draft GitHub pull request as ready for review (draft -> ready).
---

# PR Ready

Flip a draft GitHub pull request into the ready-for-review state via
`gh pr ready <N>`. A draft PR cannot be auto-merged, so the flip is
the point at which a PR becomes mergeable; keep a PR draft until it
is meant to be.

## Invocation

```text
/pr-ready <pr-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.

## Execution

1. Flip the PR to ready:

   ```bash
   gh pr ready <N>
   ```

   `gh` no-ops gracefully if the PR is already ready for review, so
   the command is safe to run more than once.

2. Report back a single line: the PR number and that it is now ready
   for review (e.g. `PR #<N> is ready for review`).
