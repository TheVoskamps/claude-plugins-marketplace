---
name: stale-worktree-holds-branch-and-cwd-does-not-persist
description: a prior dead/uncleaned agent worktree can still hold the target branch ref; recover with git worktree remove after checking it's clean, using git --git-dir/--work-tree flags (not cd or git -C) to inspect it, since subagent cwd resets between Bash calls
metadata:
  type: project
---

While starting work on PR #161 / issue #105's second fix round, `git
checkout issue-105-baked-packages` failed with `'issue-105-baked-packages'
is already used by worktree at .../agent-a7bb50f0ac43926d8` — a prior
issue-fixer subagent had NOT run its end-of-run cleanup (`git checkout
--detach && git branch -D <branch>`), leaving its worktree still checked
out on the branch.

**Confirms `git-workflow.md` "Subagent context" is accurate, the hard
way**: a `cd /path/to/other/worktree` in one Bash call, followed by `git
status` in the NEXT Bash call, silently ran against MY OWN worktree root
(cwd reset between calls) — not the other worktree. The `cd <path> && git
...` and `git -C <path> ...` forms are both blocked by the harness gate
regardless, so neither shortcut works either. The only way to inspect a
different worktree from inside a subagent is `git --git-dir=<path>/.git
--work-tree=<path> <subcommand>` (not blocked, not a `cd` chain) — a
single Bash call, no chaining.

**How to apply**: when `git checkout <branch>` reports "already used by
worktree at <path>", don't fight it by trying `cd`/`-C` tricks or assuming
the other agent is still running. Check the other worktree's state with
`git --git-dir=<path>/.git --work-tree=<path> status --porcelain=v1
--branch` — if it's clean and matches `origin/<branch>` exactly (no
divergence, nothing uncommitted), it's safe to `git worktree remove
<path>` (no `--force` needed for a clean worktree; see
[[never-force-worktree-remove]] in the sdlc-orchestrator/global memory for
why `--force` itself is never appropriate). Then proceed with the normal
`git fetch && git checkout <branch>` in your own worktree. If the other
worktree is DIRTY or diverged, stop and escalate rather than removing it —
that's someone else's uncommitted work, not routine staleness.
