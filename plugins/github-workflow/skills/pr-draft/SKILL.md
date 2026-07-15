---
name: pr-draft
description: Convert a ready-for-review GitHub pull request back to a draft (ready -> draft).
---

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

## Required repo-config: source-control

This skill only needs to know whether the repo is GitHub-backed — it
does not need the full repo-config reader contract. Read the
`source-control:` field directly from
`.claude/rules/repo-config.md`'s front-matter (a plain YAML
`key: value` line near the top of the file):

- `source-control: GitHub`, or the field is absent/unreadable but
  `gh` is available → proceed.
- `source-control: CodeCommit` → abort cleanly with: "CodeCommit
  source-control selected, but `/pr-draft` is GitHub-only and the
  CodeCommit path is not implemented." (This mirrors how
  `issue-developer` handles the CodeCommit PR-create path today.)

## Execution

1. Read `source-control` per "Required repo-config" above and abort
   if it is not GitHub.

2. Convert the PR back to a draft:

   ```bash
   gh pr ready <N> --undo
   ```

   `gh` no-ops gracefully if the PR is already a draft, so the
   command is safe to run more than once.

3. Report back a single line: the PR number and that it is now a
   draft (e.g. `PR #<N> is now a draft`).
