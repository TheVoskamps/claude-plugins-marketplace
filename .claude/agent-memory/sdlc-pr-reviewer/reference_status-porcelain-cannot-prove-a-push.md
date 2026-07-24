---
name: status-porcelain-cannot-prove-a-push
description: In sdlc agent definitions, a "verify the work landed" step built on git log -1 plus git status --porcelain proves only a local commit; it reads clean when the push failed, and the end-of-run git branch -D then discards it
metadata:
  type: reference
---

Every `sdlc` agent ends with commit → push → `git checkout --detach` →
`git branch -D <branch>`. When an agent definition adds a "confirm it
landed" step, check what the proposed commands actually observe.

`git log --oneline -1` shows the local tip and `git status --porcelain`
(no `-b`) prints the branch header not at all — so with a committed but
**unpushed** commit the tip shows the expected message and status is
empty. Verified in a throwaway clone: after `git commit -qm "Curate
agent memory"` with no push, `git log --oneline -1` printed
`37ac293 Curate agent memory` and `git status --porcelain` printed
nothing. The force-`-D` in cleanup then throws the commit away.

**How to apply:** when reviewing an agent definition (or a skill) whose
verification step is meant to prove work reached the PR, require a
command that compares against the remote — `git status -sb` (shows
`[ahead N]`), `git rev-parse HEAD` vs `git rev-parse origin/<branch>`,
or `git ls-remote`. This environment makes the failure realistic: a
push can stall or fail on the biometric SSH-agent prompt. Related:
[[verify-territory-not-relay]].
