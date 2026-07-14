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

Read `skills/lib/repo-config.md` (the reader contract in the `issues`
plugin) for the repo-config read sequence; this skill requires
**schema-version 6** and uses that library's canonical read sequence
and abort messages for `.claude/rules/repo-config.md`.

## Invocation

```text
/pr-ready <pr-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.

## Required repo-config: source-control

Run the canonical read sequence from `skills/lib/repo-config.md` and
read the `source-control` front-matter field. This skill is
**GitHub-only**:

- `source-control == GitHub` → proceed.
- `source-control == CodeCommit` → abort cleanly with: "CodeCommit
  source-control selected, but `/pr-ready` is GitHub-only and the
  CodeCommit path is not implemented." (This mirrors how
  `issue-developer` handles the CodeCommit PR-create path today.)

If the repo-config file is missing, is stale, or has incomplete
front-matter, abort with the corresponding message from the
`skills/lib/repo-config.md` abort catalogue.

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
