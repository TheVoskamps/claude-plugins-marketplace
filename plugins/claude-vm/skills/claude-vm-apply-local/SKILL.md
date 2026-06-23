---
name: claude-vm-apply-local
description: Apply a claude-vm guest worktree's changes onto the local source repo working tree, for a given run id (or the most recent run). Writes to the local source only; never pushes.
---

# claude-vm-apply-local

Apply the changes a `claude-vm` guest made (in its persistent worktree)
onto the **local source** repo's working tree. This is the explicit,
opt-in equivalent of the launcher's default copy-back — use it when
`repo.copy_back: none` was set, or to re-apply / apply a specific run's
changes after reviewing them with `/claude-vm-diff`.

This skill writes to the **local source only**. It never pushes to the
remote — that is `/claude-vm-apply-remote`.

## How runs are located

Same as `/claude-vm-diff`: each run writes
`<repo>/.claude/tmp/<runid>/run.meta` recording `run_id`, `repo_src`,
`repo_mount`, `worktree`, and `copy_back`. The run dir persists after
the guest exits (clone mode).

## Inputs

- **`<runid>`** (optional): the run to apply. Defaults to the most
  recent run under `<repo>/.claude/tmp/`.
- **`<repo>`** (optional): the source repo root. Defaults to the
  current repo.

## Steps

1. Resolve the run dir and read `run.meta` (see `/claude-vm-diff`). If
   no recorded run exists, report and stop.
2. Confirm `repo_mount` is `clone`. For a `live` run the guest already
   wrote to the source in place; there is nothing to apply, so report
   and stop.
3. **Show the changes first** and get confirmation before writing.
   Reuse the diff from `/claude-vm-diff` (working-tree diff, plus the
   worktree's git log/diff). Present:
   - which files would change in the local source,
   - whether the local source has **uncommitted changes** that the
     apply could overwrite.
   If the local source working tree is dirty, warn explicitly and let
   the user decide whether to proceed.
4. Apply the worktree's content onto the source working tree, excluding
   `.git` so local history and branch state are untouched:

   ```bash
   rsync -a --exclude='.git' "<worktree>"/ "<repo_src>"/
   ```

   The user then reviews `git status` / `git diff` in the source and
   commits as they see fit. This skill does **not** commit on the
   user's behalf — staging and commit decisions stay with the user, per
   the repo's git-workflow rules.
5. Report what changed (`git -C "<repo_src>" status --short`).

## Notes

- Applying is destructive to the source working tree where files
  overlap. Always run `/claude-vm-diff` (or step 3's preview) first.
- This skill never touches the remote. Push explicitly with
  `/claude-vm-apply-remote` or your normal git workflow once you have
  reviewed and committed.
- The launcher's default on-exit copy-back (`claude-vm.sh`, the
  `copy_back` function) mirrors this skill's safety contract: it checks
  whether the local source tree is dirty, previews what would change
  with `rsync --dry-run --itemize-changes`, and requires explicit
  confirmation before overwriting a dirty tree (skipping otherwise).
  Keep the two in sync — the launcher copy-back and this skill are the
  automatic and explicit halves of the same safe apply path. When the
  launcher skips a copy-back over a dirty tree, this skill is how you
  apply that run's changes after reviewing them.
