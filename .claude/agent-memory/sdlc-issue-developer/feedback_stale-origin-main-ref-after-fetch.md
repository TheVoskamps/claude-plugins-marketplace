---
name: stale-origin-main-ref-after-fetch
description: git fetch origin main can leave the origin/main ref stale in a freshly-created worktree; verify before switch -c, don't trust the fetch alone
metadata:
  type: feedback
---

`git fetch origin <branch>` updates `FETCH_HEAD` but the local
`origin/<branch>` remote-tracking ref can still lag behind — observed
in a fresh subagent worktree where `git switch -c <name> origin/main`
rooted the new branch 4 commits behind the actual GitHub `main` tip,
even though `git fetch origin main` had just been run with no errors.

**Why:** the harness's worktree creation process and the remote-tracking
ref update are not tightly synchronized in the way `git fetch` normally
guarantees in a plain clone. Trusting "I just fetched, so origin/main
must be current" is exactly the map-vs-territory trap — the fetch
output looked successful but the resulting ref was still stale.

**How to apply:** after `git fetch origin <source-branch>` and before
(or immediately after) `git switch -c <branch-name> origin/<source-branch>`,
verify with `git rev-parse origin/<source-branch>` compared to what you
expect (e.g. cross-check against `gh api repos/<owner>/<repo>/commits/<branch>`
or at minimum eyeball `git log --oneline -5 origin/<source-branch>` for
plausibility). If the new branch's `git log -1 HEAD` doesn't match
`git rev-parse origin/<source-branch>` right after creating it, the
branch was rooted wrong — fix with `git branch -f <name> origin/<source-branch>`
(requires switching off the branch first if the worktree is already on
it, since git refuses to force-update the branch checked out in the
current worktree) followed by `git checkout origin/<source-branch> -- .`
to sync the working tree, since `reset --soft`/`-f` alone does not
touch tracked-file contents. Re-apply any uncommitted edits after
(stash across the fix, or just re-run the Edit if it was a single
small change). This is the practical mechanism behind the "wrong-base
bug" the issue-developer agent definition already warns about — this
memory is the recovery recipe when it happens anyway.
