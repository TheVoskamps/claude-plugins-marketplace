---
name: claude-vm-diff
description: Read-only — show what changed inside a claude-vm guest worktree versus the local source repo, for a given run id (or the most recent run). Makes no changes.
---

# claude-vm-diff

Show what a `claude-vm` guest changed, by diffing the persistent guest
**worktree** against the **local source** repo. This skill is
**read-only**: it never writes to the source, the worktree, or the
remote.

Use it after a `claude-vm` run (clone mode) to review the guest's work
before deciding whether to apply it locally (`/claude-vm-apply-local`)
or push it to the remote (`/claude-vm-apply-remote`).

## How runs are located

Each `claude-vm` run writes a `run.meta` file into its persistent run
directory, under the runs root every repo on the host shares:

```text
$CLAUDE_VM_RUNS_DIR/<runid>/run.meta
```

`run.meta` records `run_id`, `repo_src`, `repo_mount`, `worktree`, and
`copy_back`. The run directory persists after the guest exits (clone
mode) precisely so this skill can find it. `repo_src` is what tells this
repo's runs apart from every other repo's.

Resolve the runs root through the plugin's own config library rather
than spelling the path:

```bash
RUNS_DIR="$(. "$CLAUDE_PLUGIN_ROOT/payload/lib/config.sh" && printf '%s' "$CLAUDE_VM_RUNS_DIR")"
```

## Inputs

- **`<runid>`** (optional): the run to inspect. When omitted, use the
  most recent run of this repo: among the run dirs under `$RUNS_DIR`
  whose `run.meta` `repo_src` is `<repo>`, the highest-sorting `run_id`,
  which is timestamp-prefixed.
- **`<repo>`** (optional): the source repo root. Defaults to the
  current repo.

## Steps

1. Resolve the run dir:
   - If `<runid>` is given, use `$RUNS_DIR/<runid>/`.
   - Otherwise, pick the most recent run whose `run.meta` names this
     repo:

     ```bash
     find "$RUNS_DIR" -mindepth 2 -maxdepth 2 -name run.meta \
       -exec grep -lxF "repo_src=<repo>" {} + 2>/dev/null | sort | tail -n 1
     ```

     `<repo>` is spelled the way the launcher records it: the output of
     `git rev-parse --show-toplevel`. The run dir is the printed file's
     directory. If nothing matches, report that this repo has no
     recorded runs and stop.
2. Read `run.meta`. Confirm `repo_mount` is `clone`. For a `live` run
   there is no separate worktree — the guest wrote to the source in
   place — so report that a diff against a separate worktree does not
   apply and stop.
3. Diff the worktree's tracked content against the local source.
   Because the worktree is a `--no-hardlinks` clone of the source, a
   structural diff of the two working trees (excluding `.git`) shows
   exactly what the guest changed:

   ```bash
   diff -ruN \
     --exclude='.git' \
     "<repo_src>" "<worktree>"
   ```

   For a git-aware view of changes the guest committed inside the
   worktree, run (read-only):

   ```bash
   git -C "<worktree>" --no-pager log --oneline "<base>..HEAD"
   git -C "<worktree>" --no-pager diff "<base>..HEAD"
   ```

   where `<base>` is the commit the source was on at clone time
   (`git -C "<worktree>" merge-base HEAD origin/HEAD` is a reasonable
   default when the source's branch tip is unchanged).
4. Print the diff. Make **no** changes.

## Notes

- This skill is strictly read-only. To apply the changes, use
  `/claude-vm-apply-local` (to the local source) or
  `/claude-vm-apply-remote` (to the remote).
- The default copy-back (`repo.copy_back: local`) may already have
  mirrored the guest's changes onto the source. If so, a working-tree
  diff against the source shows nothing — diff the worktree's git
  history instead (the `git log`/`git diff` form above).
