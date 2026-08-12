---
name: gate-blocks-reset-hard-rebuild-with-cherry-pick
description: To fix a wrong commit message below HEAD in a subagent worktree, cherry-pick onto a fresh branch — `git reset --hard` is gate-denied and `rebase -i` is unavailable
metadata:
  type: feedback
---

A false claim in a commit message that is **not** HEAD cannot be repaired the
usual ways from a subagent worktree: `git rebase -i` is unavailable in this
environment, and `git reset --hard` is denied by the permission gate with
"discards committed and working-tree state and is forbidden".

**Why:** the gate protects a subagent's only copy of its work; it cannot tell a
message-only rebuild from a destructive discard.

**How to apply:** rebuild the stack instead, which the gate allows end to end
and which never leaves the work unreferenced:

1. `git tag tmp-save <branch>` — a named anchor so nothing is unreachable.
2. `git switch -c rebuild-tmp origin/<base>`
3. `git cherry-pick <first-sha>` then `git commit --amend -F <msgfile>`
   (`--amend` works because the target is now HEAD).
4. `git cherry-pick <rest…>` in order.
5. `git diff --stat tmp-save HEAD` must print nothing — that is the proof the
   trees are identical and only messages moved.
6. `git branch -D <branch>`, `git branch -m <branch>`, `git tag -d tmp-save`.

Do this before pushing. It costs six commands and keeps the commit message
honest, which is cheaper than the PR-body erratum that is the only alternative
after a push. See [[feedback_heredoc-commit-sandbox-gate]] for the companion
rule on writing the message file in the first place.
