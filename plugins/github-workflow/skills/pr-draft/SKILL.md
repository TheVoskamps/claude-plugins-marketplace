---
name: pr-draft
description: Convert a ready-for-review GitHub pull request back to a draft (ready -> draft).
---

Convert a ready-for-review GitHub pull request back into a draft via
`gh pr ready <N> --undo`. Use this manually when a PR that was flipped
to ready turns out to still need work (e.g. it looks untested), to
re-arm the draft safety gate: the repo's auto-merge workflow filters
`isDraft == false`, so a draft PR cannot be auto-merged.

Read `skills/lib/repo-config.md` (the reader contract in the `issues`
plugin) for the repo-config read sequence; this skill requires
**schema-version 6** and uses that library's canonical read sequence
and abort messages for `.claude/rules/repo-config.md`.

## Invocation

```text
/pr-draft <pr-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.

## Required repo-config: source-control

Run the canonical read sequence from `skills/lib/repo-config.md` and
read the `source-control` front-matter field. This skill is
**GitHub-only**:

- `source-control == GitHub` → proceed.
- `source-control == CodeCommit` → abort cleanly with: "CodeCommit
  source-control selected, but `/pr-draft` is GitHub-only and the
  CodeCommit path is not implemented." (This mirrors how
  `issue-developer` handles the CodeCommit PR-create path today.)

If the repo-config file is missing, is stale, or has incomplete
front-matter, abort with the corresponding message from the
`skills/lib/repo-config.md` abort catalogue.

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
