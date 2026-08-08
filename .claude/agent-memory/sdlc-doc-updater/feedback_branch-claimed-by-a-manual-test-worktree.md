---
name: branch-claimed-by-a-manual-test-worktree
description: When git checkout <branch> fails because another worktree holds it, detach at origin/<branch> and push HEAD:<branch> — never remove that worktree.
metadata:
  type: feedback
---

`git checkout <branch-name>` in my worktree can fail with "already used
by worktree at .../manual-test-issue-NNN". That worktree is Edwin's
own, holding the branch for a real-VM test of the PR. Do not delete,
prune or `--force` it. Work detached instead:

```bash
git checkout --detach origin/<branch-name>
# edit, commit
git push origin HEAD:<branch-name>
```

Then skip the end-of-run `git branch -D` — no local branch was ever
created, so there is no claim of mine to release.

**Why:** claude-vm rounds are commonly reopened by a real-launch defect
Edwin found himself, and the worktree he found it in is still live. See
[[feedback_read-the-worktree-not-the-primary-clone]] for the companion
rule about which toplevel to anchor edits to.

**How to apply:** on any checkout failure naming another worktree, at
Setup. Say in the report-back that the commit landed via
`push HEAD:<branch>` and that his worktree's local branch ref is now
behind origin.
