---
name: read-branch-tip-via-git-show
description: Read a PR's branch-tip file content with `git show <ref>:<path>` into .claude/tmp/ instead of `git checkout <ref> -- .`, which stages the whole diff into the review worktree
metadata:
  type: reference
---

To inspect a PR's file content without claiming the branch, extract it
with `git show <ref>:<path> > .claude/tmp/<slug>/<name>` and read the
copies. Do **not** use `git checkout <ref> -- .` for this.

`git checkout <ref> -- .` writes the entire branch tree into the review
worktree **and stages it** (`git status` then shows the whole PR diff
as `M`/`A` against the worktree's own branch). The review worktree is
now dirty, and `git reset --hard` — the obvious undo — is forbidden to
subagents by the harness, so there is no cheap way back. The escape
that works is to check out the PR branch properly
(`git checkout <branch>`), because the worktree content already equals
that tree so the checkout succeeds and lands clean; but that claims the
branch and obliges the `git checkout --detach` + `git branch -D`
release at end of run.

Prefer `git show` when only reading. Check out the branch deliberately,
per [[checkout-pr-branch-before-exercising]], when the change actually
has to be exercised or when memory has to be committed onto it.

Note that `grep`/`sed` are blocked from reading paths outside the
worktree, so the extraction target must be inside the repo
(`.claude/tmp/`), not `/tmp`.
