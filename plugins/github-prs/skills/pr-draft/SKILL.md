---
name: pr-draft
description: Convert a ready-for-review GitHub pull request back to a draft (ready -> draft).
---

# PR Draft

Convert a ready-for-review GitHub pull request back into a draft via
`gh pr ready <N> --undo`. Use this manually when a PR that was flipped
to ready turns out to still need work (e.g. it looks untested), to
re-arm the draft safety gate: the repo's auto-merge workflow filters
`isDraft == false`, so a draft PR cannot be auto-merged.

## Invocation

```text
/pr-draft <pr-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.

## Execution

1. Convert the PR back to a draft:

   ```bash
   gh pr ready <N> --undo
   ```

   `gh` no-ops gracefully if the PR is already a draft, so the
   command is safe to run more than once.

2. Report back a single line: the PR number and that it is now a
   draft (e.g. `PR #<N> is now a draft`).
