---
name: stale-worktree-holds-branch-and-cwd-does-not-persist
description: a prior dead/uncleaned agent worktree can still hold the target branch ref; every way of INSPECTING it from a sibling worktree is now gate-blocked, so compare SHAs against origin and let a plain (non-force) git worktree remove be the dirtiness check
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
...` and `git -C <path> ...` forms are both blocked by the harness gate.

**UPDATE (2026-07-31, issue #193 / PR #208): the `--git-dir` escape
hatch is now blocked too.** `git --git-dir=<other>/.git
--work-tree=<other> status` is refused with *"This agent is isolated in
the worktree …, but this command redirects git to the shared checkout
via --git-dir."* So there is now **no** way to inspect another
worktree's dirtiness from inside a subagent. Don't burn calls hunting
for one. (Same gate also refuses a compound Bash call it can't verify
stays in-worktree — a `for` loop over three input files, or
`cmd && cmd; cmd` chains — with *"too complex to verify"*. Split into
separate plain calls; the refusal is about static verifiability, not
about the commands themselves.)

**How to apply**: when `git checkout <branch>` reports "already used by
worktree at `<path>`", don't fight it by trying `cd`/`-C`/`--git-dir`
tricks or assuming the other agent is still running. Instead, from your
OWN worktree:

1. `git worktree list` — read the other worktree's SHA and confirm it
   prints `[branch-name]` (a real claim) rather than `(detached HEAD)`.
2. `git rev-parse origin/<branch>` — if the SHAs match, the other
   worktree has nothing committed that origin lacks.
3. `git worktree remove <path>` — **plain, never `--force`**. This IS
   the dirtiness check: git refuses a worktree with uncommitted or
   untracked files, so a clean exit 0 proves it was clean, and a refusal
   is your signal to stop and escalate rather than destroy someone
   else's work. See [[never-force-worktree-remove]] in the
   sdlc-orchestrator/global memory for why `--force` is never
   appropriate.

Then proceed with the normal `git fetch && git checkout <branch>` in your
own worktree. Worked first try on PR #208.

**Don't over-trigger on this**: a spawn brief may flag a worktree at the
target branch's old tip SHA as a possible claim to investigate. Check
`git worktree list` output first — it prints `[branch-name]` for a real
checkout of that branch and `(detached HEAD)` for a worktree that merely
sits at some commit (including, coincidentally, the branch's tip prior to
a rebase). A `(detached HEAD)` worktree at the branch's SHA is NOT a
claim on the branch — `git checkout <branch>` from your own worktree
succeeds fine in that case, no removal or escalation needed. Confirmed
during issue #106 PR #174's rebase task: `.claude/worktrees/issue-106-test`
sat `(detached HEAD)` at the branch's pre-rebase tip; `git checkout
issue-106-boot-time-package-install-update` from a separate worktree
succeeded immediately with no conflict.
