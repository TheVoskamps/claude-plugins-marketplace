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
directory, which lives under one **host-scoped runs root** shared by
every repo:

```text
<runs-root>/<runid>/run.meta
```

`run.meta` records `run_id`, `repo_src`, `repo_mount`, `worktree`, and
`copy_back`, plus the run's process/endpoint keys. The run directory
persists after the guest exits (clone mode) precisely so this skill can
find it.

**Never spell the runs root here.** It is composed in exactly one place
— `payload/lib/runsroot.sh` — so ask that file for it rather than
writing the path into these instructions:

```bash
RUNS_ROOT="$(. "$CLAUDE_PLUGIN_ROOT/payload/lib/runsroot.sh" && claude_vm_runs_root)"
```

Because the root is shared across repos, "this repo's runs" is a
**filter on `run.meta`'s `repo_src`**, not a property of the directory's
location. That is the whole reason `repo_src` is recorded.

## Inputs

- **`<runid>`** (optional): the run to inspect. When omitted, use the
  most recent run **for this repo** — see the filter in step 1.
- **`<repo>`** (optional): the source repo root. Defaults to the
  current repo.

## Steps

1. Resolve the run dir. Resolve `<runs-root>` as above first.
   - If `<runid>` is given, use `<runs-root>/<runid>/`. Confirm its
     `run.meta` records a `repo_src` matching `<repo>`; if it names a
     different repo, say so and stop rather than diffing one repo's
     worktree against another's source.
   - Otherwise, pick the most recent `<runs-root>/*/` that contains a
     `run.meta` **whose `repo_src` is `<repo>`** — highest-sorting
     `run_id`, which is timestamp-prefixed. Skip any run dir belonging
     to another repo. If none exists, report that there are no recorded
     runs for this repo and stop.

   A run dir may belong to a **live** VM. This skill is read-only, so
   inspecting one is harmless, but its worktree is being written to as
   you read it — mention that if the run you resolved is the current
   session's.
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
- Run dirs are reaped by `claude-vm-cleanup`, which removes the
  **dead** ones across all repos. If a run you expected is missing,
  that command (or a manual cleanup) is the likely reason; it never
  removes a live run.
- The default copy-back (`repo.copy_back: local`) may already have
  mirrored the guest's changes onto the source. If so, a working-tree
  diff against the source shows nothing — diff the worktree's git
  history instead (the `git log`/`git diff` form above).
