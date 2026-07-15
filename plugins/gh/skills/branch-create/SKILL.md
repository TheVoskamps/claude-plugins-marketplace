---
name: branch-create
description: Create the correctly-named issue branch (issue-<N>-<slug>) off the configured source branch, reading branch conventions from repo-config internally.
---

Create the feature branch for an issue: resolve the branch name from
the issue number and the repo's branch-naming convention, and create it
rooted at the configured source branch. This is the branch-create the
`/sdlc:orchestrate` flow's `issue-developer` previously performed as a
raw `git switch -c`; the skill now owns it, including the config read.

Rooting the branch at the **explicit** source branch is the
wrong-base guard: without an explicit start point, `git switch -c`
roots the new branch at whatever commit the worktree happened to be on,
not at the source branch's tip.

## Invocation

```text
/branch-create <issue-number>
```

- `<issue-number>` (required): the issue this branch is for, with or
  without a leading `#`.

## Repo-config

This skill reads two values from `.claude/rules/repo-config.md`
**internally** — the caller does not pass them. Follow the read
contract in the `issues` plugin's `skills/lib/repo-config.md`; this
reader requires **schema-version 6** and uses that library's canonical
read sequence and abort messages verbatim (`File missing`,
`Schema-version absent`, `Schema-version stale`, `Front-matter
incomplete`). The `branch-create requires it.` reader-specific prefix
is permitted ahead of the canonical `Run /repo-config to create one.`
tail on the File-missing abort.

The two values consumed:

- **`default-issue-source-branch`** — the branch the new branch is
  rooted at (e.g. `main` or `integ`).
- **`issue-branch-naming-prefix`** — the branch-name shape, one of:
  - `none`     -> `issue-<N>-<slug>`
  - `initials` -> `<initials>/issue-<N>-<slug>`
  - `name`     -> `<name>/issue-<N>-<slug>`

  When the prefix is `initials` or `name`, the `<initials>`/`<name>`
  value comes from the human owner; if the invocation context does not
  supply it, ask before proceeding.

Re-read the file every run; do not cache across invocations.

## Execution

1. **Resolve a slug from the issue title.** Fetch the title:

   ```bash
   gh issue view <N> --json title
   ```

   Derive a short slug from the title: lowercase, kebab-case, at most
   five words (e.g. `Orchestrator manages PR draft/ready state` ->
   `orchestrator-manages-pr-draft-ready`).

2. **Form the branch name** by combining `<N>`, the slug, and
   `issue-branch-naming-prefix`:
   - `none`     -> `issue-<N>-<slug>`
   - `initials` -> `<initials>/issue-<N>-<slug>`
   - `name`     -> `<name>/issue-<N>-<slug>`

3. **Create the branch rooted at the configured source branch.**
   Fetch the source branch first, then switch onto the new branch with
   `origin/<default-issue-source-branch>` as the explicit start point.
   Use the defensive form so a leftover branch from a prior aborted run
   doesn't error the new run:

   ```bash
   git fetch origin <default-issue-source-branch>
   git switch -c <branch-name> origin/<default-issue-source-branch> \
      || git switch <branch-name>
   ```

4. Report back a single line: the branch name created, and the source
   branch it was rooted at.
