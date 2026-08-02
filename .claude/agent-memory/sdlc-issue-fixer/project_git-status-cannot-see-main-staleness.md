---
name: git-status-cannot-see-main-staleness
description: git status compares against the branch's own remote ref and never against main, so only git merge-base --is-ancestor origin/main HEAD detects that a branch is behind; if a real conflict makes a rebase necessary, re-derive from the rebased tree, push with an explicit-SHA lease, and resolve MEMORY.md as a union that honors a Curate commit's deletions
metadata:
  type: project
---

**Detection.** `git status` reporting "up to date with
`origin/<branch>`" says nothing about main: it compares against the
branch's own remote ref, and `git fetch` alone does not surface the
gap either. Only `git merge-base --is-ancestor origin/main HEAD`
answers whether the branch is behind main; non-zero means it is. When
that matters — a PR reading `CONFLICTING`, or a fix being computed
against a file main has since rewritten — `git diff --name-only
<merge-base>..origin/main` names which of the target files moved.

Being behind main is not by itself something to act on. A rebase is a
response to an actual conflict, not a precondition for editing a file.

**If a rebase is warranted:**

1. `git rebase origin/main`, resolve, then re-derive the change from
   the rebased tree — do not carry over a working-tree diff computed
   against the stale files (`git checkout -- .` and redo; the
   re-derivation is cheap and the stale hunks are not).
2. Push with an explicit-SHA lease:
   `git push --force-with-lease=<branch>:<old-remote-sha> origin
   <branch>`. `git-workflow.md` sanctions `--force-with-lease` exactly
   for "after rebasing a branch onto the default branch's HEAD".
3. Verify with `gh pr view <N> --json mergeable` — it should flip
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
