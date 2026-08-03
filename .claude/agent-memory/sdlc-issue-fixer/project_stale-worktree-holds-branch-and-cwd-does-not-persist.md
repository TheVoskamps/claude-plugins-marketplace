---
name: stale-worktree-holds-branch-and-cwd-does-not-persist
description: another worktree can hold the target branch ref so `git checkout <branch>` fails; every way of INSPECTING it from a sibling worktree is now gate-blocked, so work detached from origin/<branch> and push with an explicit refspec instead of trying to take or remove the branch
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
(cwd reset between calls) — not the other worktree.

**Every cross-worktree git form is now gated (#193/PR #208, re-verified
on #216/PR #217).** The `cd <path> && git ...` and `git -C <path> ...`
forms were already blocked; `git --git-dir=<path>/.git
--work-tree=<path> <subcommand>` — which an older version of this memory
recommended — is now blocked too, refused with *"This agent is isolated
in the worktree …, but this command redirects git to the shared checkout
via --git-dir"* / "a worktree-isolated agent's git operations must
target its own worktree". So there is now **no** way to inspect another
worktree's git state from inside a subagent, and therefore no way to
establish it is clean enough to remove. Don't burn calls hunting for
one. `git reset --hard` is separately blocked in subagents, and its
refusal message names the replacement: `git checkout --detach
origin/<branch>`. (Same gate also refuses a compound Bash call it can't
verify stays in-worktree — a `for` loop over three input files, or
`cmd && cmd; cmd` chains — with *"too complex to verify"*. Split into
separate plain calls; the refusal is about static verifiability, not
about the commands themselves.)

**How to apply**: when `git checkout <branch>` reports "already used by
worktree at `<path>`", don't fight it by trying `cd`/`-C`/`--git-dir`
tricks or assuming the other agent is still running. Stop trying to take
the branch and work without it:

1. `git fetch origin` then `git checkout --detach origin/<branch>` in your
   own worktree. Commit on the detached HEAD as normal.
2. Push with an explicit refspec: `git push origin
   HEAD:refs/heads/<branch>`. The PR picks the commits up; the other
   worktree's local branch ref just ends up behind origin, which is
   harmless.
3. There is no branch to delete at cleanup — you were never on one, so
   the end-of-run `git branch -D` step is a no-op.

Do not try to remove the other worktree. On PR #217 the holding worktree
turned out to contain an untracked `.claude-vm/` config pair the human had
copied in for a live guest verification — `ls -la <path>` (a plain
filesystem read, not gated) is enough to see that kind of thing, and it
is exactly the work `git worktree remove` would have destroyed. When you
*do* have a reason to reclaim a dead worktree (PR #208 did, and it worked
first try), the ladder is `git worktree list` to confirm it prints
`[branch-name]` rather than `(detached HEAD)`, `git rev-parse
origin/<branch>` to confirm the SHAs match so nothing committed is
origin-only, then `git worktree remove <path>` — **plain, never
`--force`**. That plain remove IS the dirtiness check: git refuses a
worktree with uncommitted or untracked files, so a clean exit 0 proves it
was clean and a refusal is your signal to stop and escalate rather than
destroy someone else's work. See [[never-force-worktree-remove]] in the
sdlc-orchestrator/global memory for why `--force` is never appropriate.

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
