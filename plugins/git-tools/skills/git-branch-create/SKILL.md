---
name: git-branch-create
description: Create the correctly-named issue branch (issue-<N>-<slug>, or issue-<N1>-<N2>-...-<compound-slug> for a batch of issues) off the configured source branch, naming it with the git-issue-branch script.
---

# Git Branch Create

Create the feature branch for an issue — or for a **batch** of issues
implemented together on one branch and delivered as one PR — named by
`git-issue-branch encode` and rooted at the configured source branch.
A batch of one is the ordinary single-issue case.

The inverse operation — recovering the issue set back out of a
finished branch name — is `git-tools:git-issues-from-branch`.

Rooting the branch at the **explicit** source branch is the
wrong-base guard: without an explicit start point, `git switch -c`
roots the new branch at whatever commit the worktree happened to be on,
not at the source branch's tip.

## Invocation

```text
/git-tools:git-branch-create <issue>… [<compound-slug>]
```

- `<issue>…` (required): one or more issues in this repository, each
  as `N` or `#N`, space-separated, in **implementation order** —
  dependency order within the batch.
- `<compound-slug>` (optional for one issue, **required** for two or
  more): the slug the branch name ends with, as the last argument. For
  a single issue with none supplied, the skill derives it from the
  issue title. For two or more, a mechanical merge of k titles produces
  garbage, so the caller supplies it — with two or more issues and no
  slug, **ask** rather than inventing one.

The last argument is the slug when it is not of the form `N` or `#N`;
every other argument is an issue.

## The script

`git-issue-branch`, which this plugin puts on `PATH`, owns the name:
the grammar, the issue-argument forms, the prefix, and every
validation. `encode` takes the prefix from the `issues` plugin's
`issue-branch-prefix`, so this skill neither reads the prefix nor asks
the human for one.

```bash
git-issue-branch encode <issue>… [--slug <slug>]
```

On exit 0 its stdout is the branch name. Exit 4 is the one-issue,
no-slug case, and a rejected slug step 2 derived is step 2's to
adjust. On any other non-zero exit, relay its stderr verbatim and
stop: it names the offending value, and nothing has been created.

## Repo-config

The source branch is the one value this skill reads from
`.issues/repo-config.md` itself, with a lightweight inline parse of the
`default-issue-source-branch` front-matter line. If the file is
missing, abort with: "This repo has no `.issues/repo-config.md`. Run
`/repo-config` to create one." Re-read the file every run.

## Execution

1. **Name the branch.** Run `encode` with the issues in the order
   given, and `--slug <compound-slug>` when one was supplied.

2. **Derive a single issue's slug**, only when step 1 exited 4. Take
   the issue title from the first line of `/issues:issue-view <N>`'s
   output, after the `#<N>` and before the `(<state>)`:

   ```text
   /issues:issue-view <N>
   ```

   Lowercase it and make it kebab-case, at most five words (e.g.
   `Orchestrator manages PR draft/ready state` ->
   `orchestrator-manages-pr-draft-ready`), and run `encode` again with
   `--slug <derived-slug>`. When `encode` rejects the derived slug,
   adjust it as the message says and run it again.

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

4. Report back a single line: the branch name created, the issue set
   it encodes, and the source branch it was rooted at.
