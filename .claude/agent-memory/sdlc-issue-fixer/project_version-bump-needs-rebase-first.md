---
name: version-bump-needs-rebase-first
description: Detect branch staleness with git merge-base --is-ancestor before a plugin version bump (git status will not tell you) and execute the rebase with the gate-legal forms; memory-index conflicts resolve as a union except where a Curate commit is replayed
metadata:
  type: project
---

CLAUDE.md requires a rebase onto `origin/main` before any plugin
version bump. This entry is how to detect that you need one, and how to
carry it out here.

**Detection.** `git status` reports "up to date with
`origin/<branch>`", which is true and irrelevant — it compares against
the branch's own remote ref, never against main, and fetching alone
does not tell you either. Only `git merge-base --is-ancestor
origin/main HEAD` answers the question. Staleness bites past the
version line too: main may have edited the very file the round is
fixing, so the fix gets computed against a file that no longer exists
in that form, and `gh pr view --json mergeable` reads `CONFLICTING`.

**How to apply:**

1. `git fetch origin`, then `git merge-base --is-ancestor origin/main
   HEAD`. Non-zero means rebase.
2. `git diff --name-only <merge-base>..origin/main` before rebasing, so
   you know which of your target files main has moved under you.
3. `git rebase origin/main`, resolve, then re-derive the fix from the
   rebased tree — do not carry over a working-tree diff computed
   against the stale files (`git checkout -- .` and redo; the
   re-derivation is cheap and the stale hunks are not).
4. Bump to `main's current version + patch`, then push with an
   explicit-SHA lease:
   `git push --force-with-lease=<branch>:<old-remote-sha> origin
   <branch>`. `git-workflow.md` sanctions `--force-with-lease` exactly
   for "after rebasing a branch onto the default branch's HEAD".
5. Verify with `gh pr view <N> --json mergeable` — it should flip
   `CONFLICTING` → `MERGEABLE`.

Feature-branch commits in this repo are unsigned (`git log
--format=%G?` shows `N` before *and* after), so a rebase strips no
signatures here. Conflicts land almost entirely in
`.claude/agent-memory/*/MEMORY.md` indexes and resolve as a union of
both sides' bullets — except when the branch's own `Curate agent
memory` commit is the one being replayed, where the correct resolution
is to keep main's new bullet and honor the scrubber's deletion.

See [[git-command-form-gate-cd-then-bare-git]] and
[[rebase-continue-editor-gate]] for the command forms the gate allows
while doing this.
