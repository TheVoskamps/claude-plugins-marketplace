---
name: version-bump-needs-rebase-first
description: A CLAUDE.md-mandated plugin version bump on a branch whose base is older than origin/main is an unavoidable merge conflict on the version line; check main-is-ancestor before bumping and rebase onto origin/main first
metadata:
  type: project
---

Before editing any `plugins/<name>/.claude-plugin/plugin.json` version,
run `git merge-base --is-ancestor origin/main HEAD` (after a
`git fetch`). If it returns non-zero, the branch is behind and you must
rebase onto `origin/main` **before** bumping.

**Why:** the repo's CLAUDE.md forces a version bump for every plugin a
PR touches, and a version is a single line. If main has bumped that
same plugin since the branch's merge-base, *every* value you can write
conflicts — base `0.16.7`, main `0.17.0`, branch anything — so there is
no bump that merges cleanly. On PR #211 this showed up as
`gh pr view --json mergeable` reading `CONFLICTING`, which blocks the
PR outright. The staleness bites twice: main had also edited the very
`SKILL.md` table the round was fixing, so the fix was being computed
against a file that no longer existed in that form. Fetching alone does
not tell you this — `git status` says "up to date with
`origin/<branch>`", which is true and irrelevant.

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
