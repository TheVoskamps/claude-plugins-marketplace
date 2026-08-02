---
name: pr-branch-rebased-under-checkout
description: this repo's PR branches can get force-rebased onto a newer main by automation WHILE a fixer session is running; re-fetch before push, expect rejection, re-derive via format-patch+am rather than force-push
metadata:
  type: project
---

While fixing PR #161 (issue #105) the local checkout of
`issue-105-baked-packages` went stale TWICE in one session — once between
the initial `git fetch && git checkout` and the first `git push` (a plain
push rejection), and again between that recovery and the actual push. Both
times `git log --oneline origin/<branch>` showed the same three logical
commits (matching messages) but different hashes, rooted on a newer `main`
merge each time (`#165` merged in the first jump, `#167` in the second).
This repo has PR-automation (`github-setup:gh-repo-setup-pr-automation` —
scheduled rebase sweep / auto-rebase) that force-rebases open PR branches
onto `main` on some cadence, and it fired mid-session.

**Symptom**: `git status` after a plain `git checkout <branch>` (even
right after `git fetch origin`) shows "have 3 and 6 different commits
each, respectively" diverged — NOT "up to date" — because the remote had
already force-updated by the time of an even-earlier fetch, or updates
again between fetch and push.

**Safe recovery pattern** (a subagent worktree must never `git reset
--hard` or force-push):

1. `git diff > <scratch>/fix.patch` (or, if already committed,
   `git format-patch -1 <sha> --stdout > <scratch>/my-fix.patch`) to save
   the actual delta.
2. `git checkout --detach origin/<branch>` — lands exactly on the new
   remote tip without touching the stale local branch ref.
3. `git branch -D <branch>` then `git switch -c <branch>
   origin/<branch>` — drops the stale local ref and recreates it tracking
   the current remote tip.
4. Reapply: `git apply <scratch>/fix.patch` (uncommitted diff) or `git am
   --3way < <scratch>/my-fix.patch` (already-committed patch).
5. Re-verify the diff content is unchanged (`git diff <file>` / `git show
   --stat HEAD`) before committing/pushing again — confirms no merge
   artifacts snuck in.
6. Push. If rejected again, repeat from step 1 — don't force-push, don't
   assume it won't happen twice.

**How to apply**: in this repo specifically, treat any "diverged" status
message or a rejected plain push on an issue-fixer branch as EXPECTED
background noise from the rebase-sweep automation, not a sign of a real
conflict with another human's work — the recovery above is safe and
routine. Re-fetch immediately before every push on a long-running fixer
session; don't rely on a fetch done at the start of the session still
being current an hour later.
