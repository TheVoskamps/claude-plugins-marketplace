---
name: claude-vm-apply-remote
description: Push a claude-vm guest worktree's committed changes to the remote, for a given run id (or the most recent run). Pushes only with explicit approval; never force-pushes.
---

# claude-vm-apply-remote

Push the changes a `claude-vm` guest committed (in its persistent
worktree) to the **remote**. Use this when you want the guest's work to
land on a remote branch directly, without first mirroring it onto the
local source.

This skill pushes to the remote. Per the repo's git-workflow rules,
**pushing requires explicit approval** — show the commits and target
branch, ask, and wait for a clear yes before pushing. Never
force-push.

## How runs are located

Same as `/claude-vm-diff`: each run writes
`<repo>/.claude/tmp/<runid>/run.meta` recording `run_id`, `repo_src`,
`repo_mount`, `worktree`, and `copy_back`. The run dir persists after
the guest exits (clone mode).

## Inputs

- **`<runid>`** (optional): the run to push. Defaults to the most
  recent run under `<repo>/.claude/tmp/`.
- **`<repo>`** (optional): the source repo root. Defaults to the
  current repo.
- **`<branch>`** (optional): the remote branch to push to. When
  omitted, derive a descriptive branch name (e.g.
  `claude-vm/<runid>`); do **not** push to the default branch
  implicitly.

## Steps

1. Resolve the run dir and read `run.meta` (see `/claude-vm-diff`). If
   no recorded run exists, report and stop.
2. Confirm `repo_mount` is `clone` — the worktree (a `--no-hardlinks`
   clone of the source) carries the guest's commits and its own
   `origin` pointing at the source. For a `live` run there is no
   separate worktree; report and stop.
3. Show what would be pushed:

   ```bash
   git -C "<worktree>" --no-pager log --oneline "<base>..HEAD"
   git -C "<worktree>" --no-pager diff --stat "<base>..HEAD"
   ```

   If the worktree has uncommitted changes, the guest's work was not
   committed — report that and stop (there is nothing to push). The
   user can commit inside the worktree, or apply locally and commit
   there.
4. **Get explicit approval** for the push, naming the target remote and
   branch. Wait for a clear "yes" / "push".
5. Push the worktree's branch to the remote. The worktree's `origin` is
   the local source; to reach the true upstream, add/resolve the source
   repo's `origin` remote URL and push there, e.g.:

   ```bash
   upstream="$(git -C "<repo_src>" remote get-url origin)"
   git -C "<worktree>" push "$upstream" "HEAD:<branch>"
   ```

   Use a normal (non-force) push. If the remote rejects it
   (non-fast-forward), report the rejection and stop — do not
   force-push.
6. Report the pushed branch and, if applicable, suggest opening a PR.

## Notes

- This skill only pushes **committed** work. If the guest's changes are
  uncommitted in the worktree, commit them (inside the worktree) or use
  `/claude-vm-apply-local` first.
- Never force-push. A rejected push is surfaced to the user, who
  decides how to reconcile.
