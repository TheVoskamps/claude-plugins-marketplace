---
name: pr-merge-conflicts
description: Enumerate a GitHub pull request's actual merge conflicts against its base — the conflicting files and hunks — by trial-merging in a throwaway worktree that is aborted and removed afterwards. Read-only; resolves nothing and leaves the primary clone untouched.
---

# PR Merge Conflicts

Enumerate the conflicts a pull request's branch has with its base
branch, and nothing else. GitHub reports `mergeStateStatus: DIRTY`
without saying which files or hunks conflict; this skill performs the
merge in a throwaway worktree, collects what conflicts, then aborts
the merge and removes the worktree. It resolves nothing, commits
nothing, pushes nothing, and leaves the primary clone's `git status`
exactly as it found it.

## Invocation

```text
/pr-merge-conflicts <pr-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.

## Execution

1. **Resolve the head and base branches**, and fetch both:

   ```bash
   gh pr view <N> --json headRefName,baseRefName
   git fetch origin <base> <head>
   ```

2. **Add a throwaway worktree at the PR's head.** Every path this
   skill creates lives under `.claude/worktrees/`, so nothing lands in
   the primary clone's working tree. Detach, so no branch claim is
   taken that another worktree would then be refused:

   ```bash
   git worktree add --detach .claude/worktrees/pr-merge-conflicts-<N> \
     origin/<head>
   ```

3. **Trial-merge the base, without committing**, inside that worktree.
   Every git command below runs through `-C <worktree>` rather than a
   `cd`, which does not persist between Bash calls:

   ```bash
   git -C .claude/worktrees/pr-merge-conflicts-<N> \
     merge --no-commit --no-ff origin/<base>
   ```

   A non-zero exit with conflicts is the expected outcome, not an
   error to stop on. A clean merge here means the PR is not `DIRTY`
   against this base at this moment — report that and continue to
   cleanup.

4. **Collect the conflicts.** The conflicting files first, then each
   file's conflicting hunks — the regions between `<<<<<<<` and
   `>>>>>>>` markers, which `git diff` renders as combined diff on an
   unmerged path:

   ```bash
   git -C .claude/worktrees/pr-merge-conflicts-<N> \
     diff --name-only --diff-filter=U
   git -C .claude/worktrees/pr-merge-conflicts-<N> \
     diff -- <file>
   ```

5. **Abort the merge and remove the worktree**, whatever step 3 and 4
   produced. Run both even when a collection step failed, so a failed
   run leaves nothing behind for the next one to trip on:

   ```bash
   git -C .claude/worktrees/pr-merge-conflicts-<N> merge --abort
   git worktree remove .claude/worktrees/pr-merge-conflicts-<N>
   ```

   `merge --abort` exits non-zero with `There is no merge to abort`
   when step 3 found the head already up to date with the base — there
   was no merge in progress, so that exit is not a failure. The abort
   is what leaves the tree clean enough for a plain `remove`; run it
   first, without exception.

6. **Confirm the primary clone is untouched.** `git status --porcelain`
   in the primary clone reads the same as before the run; the trial
   merge happened in the worktree, and the `.claude/` tree is
   gitignored.

7. **Report back** one block: the PR, its head and base, the
   conflicting files, and per file each conflicting hunk verbatim.
   When the trial merge was clean, say so instead. The report is the
   whole output: what to do about each conflict is the caller's to
   decide, and the resolution is whoever the caller hands it to.
