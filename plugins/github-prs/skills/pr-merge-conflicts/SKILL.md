---
name: pr-merge-conflicts
description: Enumerate a GitHub pull request's actual merge conflicts against its base — the conflicting files and hunks — by trial-merging in a throwaway worktree that is aborted and removed afterwards. Resolves, commits and pushes nothing; in the primary clone it fetches the head and base into the origin/* refs and runs git worktree prune, and leaves its tracked files and index as it found them.
---

# PR Merge Conflicts

Enumerate the conflicts a pull request's branch has with its base
branch, and nothing else. GitHub reports `mergeStateStatus: DIRTY`
without saying which files or hunks conflict; this skill performs the
merge in a throwaway worktree, collects what conflicts, then aborts
the merge and removes the worktree. It resolves nothing, commits
nothing, pushes nothing, and leaves the primary clone's tracked files
and index as it found them; what it does change there is the fetched
`origin/*` refs and the `git worktree prune` described below.

## Invocation

```text
/pr-merge-conflicts <pr-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.

## Execution

Run the bundled script from the repository the PR belongs to, spelled
as a bare name:

```bash
pr-merge-conflicts <pr-number>
```

The script reads the PR's head and base branches, fetches both, and
adds a detached worktree at the head under
`.claude/worktrees/pr-merge-conflicts-<N>`, so no branch claim is taken
and nothing lands in the primary clone's working tree. It trial-merges
the base there without committing, collects the conflicting files and
each one's hunks, then aborts the merge and removes the worktree on
every exit, so a failed run leaves nothing for the next one to trip
on. A worktree an interrupted earlier run left at that path is cleared
before the add, and `git worktree prune` runs there too, dropping every
registration in the clone whose directory is gone — not only this
skill's own.

## Output and exit status

- **Exit 0** — stdout is the whole report. Its first line names the PR,
  its head and its base. Then either a line saying the trial merge is
  clean — the PR is not `DIRTY` against this base at this moment — or
  the conflicting files, one per line, followed by a `=== <file>`
  section per file holding that file's conflicting hunks verbatim.
  Report it back as it stands: what to do about each conflict is the
  caller's to decide, and the resolution is whoever the caller hands it
  to.
- **Exit 2** — a usage error; nothing was read or created.
- **Exit 3** — a `gh` or `git` step failed: the PR could not be read,
  the fetch or the worktree add failed, or the merge failed without
  leaving a conflicted file. Stderr names the step, with the tool's own
  error above it where the tool printed one. Surface it verbatim.
