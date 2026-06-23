---
name: git-cleanup-branches-and-worktrees
description: Clean up merged local branches and remove stale subagent worktrees from `.claude/worktrees/`.
---

# git-cleanup-branches-and-worktrees

Please clean up merged local branches (regardless of naming convention)
and their worktrees, plus the throwaway worktrees that
`isolation: worktree` subagents leave behind.

## Protected branch (referenced from Steps 2, 5, and 9)

This skill protects exactly **one** branch: the repo's default
branch, detected dynamically at runtime. That branch is **never**
deleted by this skill and is always excluded from the merged-branch
scan in Step 2. Step 5's orphan-branch reachability check (Pass 2)
uses it as the "fully landed" yardstick. It is also the branch Step 9
pulls forward at the end of the run.

Do **not** hardcode branch names. Detect the default branch once at
the start of the run and reuse it everywhere below as
`$DEFAULT_BRANCH`:

```bash
# authoritative — the repo's configured default branch
DEFAULT_BRANCH=$(gh repo view \
  --json defaultBranchRef --jq '.defaultBranchRef.name')

# fallback if gh is unavailable / non-GitHub: the remote's HEAD symref
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git symbolic-ref --quiet refs/remotes/origin/HEAD \
    | sed 's@^refs/remotes/origin/@@')
fi
```

If neither form yields a non-empty branch name, **stop and report** —
without a known protected branch the skill cannot safely decide what
to delete. Everything other than `$DEFAULT_BRANCH` is a candidate
subject to the existing gates (merged-PR + remote-gone for Step 3;
reachability for Step 5b). Because the protected set is a single,
guaranteed-to-exist ref, the previous failure mode — a hardcoded list
naming branches the repo doesn't have, causing `git rev-list` to abort
with `fatal: bad revision` — cannot occur.

1. Run `git fetch --all --prune` to refresh tracking branches and
   remove stale remote refs.
2. List all local branches **except** `$DEFAULT_BRANCH`:

   ```bash
   git for-each-ref --format='%(refname:short)' refs/heads/ \
     | grep -v -x "$DEFAULT_BRANCH"
   ```

   Filter out the protected branch. The remaining branches are
   candidates for the gate in Step 3 — this deliberately includes
   branches that don't match `issue-NNN-*` (e.g. `add-foo-skill`,
   `fix-bar-allowlist`, `update-settings-permissions`), because the
   gate (merged PR + remote gone) is the real safety signal, not the
   name pattern. Note: `worktree-*` branches that appear in this
   enumeration fail Step 3's gate (they have no merged PR) and are
   handled by Step 5 instead.
3. For each candidate branch, determine whether it is safe to delete.
   The check is **PR merged AND remote branch is gone** — both must hold.
   "Issue closed and assigned to me" is **not** a sufficient signal: an
   issue can be closed without its PR ever merging, and an unmerged
   branch may still hold work that hasn't landed on the default branch.

   ```bash
   gh pr list --state merged --head <branch> --json number,mergedAt
   git ls-remote --exit-code origin <branch>   # exit 2 = branch is gone
   ```

   Both conditions must be true:
   - `gh pr list` returns a non-empty result for a merged PR on this branch
   - `git ls-remote --exit-code origin <branch>` exits 2 (branch absent on origin)

   A branch with no merged PR (e.g. a local-only branch you never
   pushed, or a remote-tracking branch for in-progress work) fails
   the gate and is left alone. The gate is the safety net; the
   broadened enumeration in Step 2 just stops the skill from
   ignoring merged branches that don't happen to start with
   `issue-`.

   **Note on the name-based PR match.** `gh pr list --head <branch>`
   matches by branch *name*, not by SHA. Edge case: a branch was deleted,
   then later recreated with the same name and a different commit lineage,
   and that new instance has its own merged PR. The name-based gate would
   pass even though the local SHA points at the *first* (now-gone) remote
   tip. The secondary safety check in step 4a handles this — the local
   branch's `@{upstream}` is gone in that scenario, so
   `git rev-list @{upstream}..HEAD` fails loudly and the worktree is
   skipped rather than silently removed.

   Closed-but-not-merged PRs are correctly excluded by `--state merged`.
   Force-pushed branches are also handled correctly: the gate requires
   the *branch* to be gone, not the local SHA to match the remote tip.

4. For branches where both conditions hold:
   a. Remove any git worktree under `.claude/worktrees/` that uses the
      branch. **Use plain `git worktree remove`, not `--force`** — the
      safety check matters; if it trips, we want to know.

      Before calling `git worktree remove <path>`, verify the worktree
      is in a known-safe state:
      - no uncommitted changes (`git status --porcelain` empty)
      - no unpushed commits relative to the branch's remote tracking
        ref (`git rev-list @{upstream}..HEAD` empty)

      If either check fails, **skip the worktree** and report the
      reason. Do not force-remove.

      If `git worktree remove` fails with `fatal: cannot remove a
      locked working tree`, inspect the lock reason via
      `git worktree list --porcelain`. If it matches the standard
      harness shape `claude agent agent-<hash> (pid NNNN)` AND (the
      PID is no longer alive (`kill -0 <pid>` fails) OR the branch
      passed step 3's "merged + remote gone" gate (which is the case
      here, since we're inside step 4)), this is a stale end-state
      lock from a returned or crashed subagent — run
      `git worktree unlock <path>` then re-run
      `git worktree remove <path>` (no `--force`). See
      `~/.claude/rules/worktree-cleanup.md`. If the lock reason does
      not match the harness shape, or the uncommitted/unpushed check
      above failed, skip and report — do not unlock and do not
      force-remove.
   b. Delete the local branch (`git branch -D`).
      (Safe because step 3 already confirmed the PR was merged AND the
      remote branch is gone; `git branch -d` gives false negatives when
      worktree checkouts are stale.)
   c. Delete the remote branch only if step 3's `git ls-remote` shows
      it still exists (defensive — usually it's already gone, which
      was part of the gate).

5. Clean up `isolation: worktree` subagent worktrees and their
   leftover branch refs. Claude Code's `isolation: worktree`
   produces branch names matching `worktree-*` (e.g.
   `worktree-agent-a39b0297dc3421b9e`).

   Enumerate candidates in two passes:

   a. **Pass 1 — worktrees that still exist.** List all worktrees
      under `.claude/worktrees/` whose checked-out branch matches
      `worktree-*`. For each, run the safety check:
      - no uncommitted changes
      - no unpushed commits relative to `@{upstream}` (the branch's
        own remote tracking ref). Do **not** compare against the default
        branch — feature/worktree branches are expected to diverge from it;
        what matters is whether the branch is fully pushed to its own
        remote.

      If both checks pass: remove the worktree (`git worktree remove`,
      no `--force`) and delete the local branch (`git branch -d`).
      If either check fails: skip and report the reason.

      If `git worktree remove` fails with `fatal: cannot remove a
      locked working tree`, inspect the lock reason via
      `git worktree list --porcelain`. If the lock reason matches the
      standard harness shape `claude agent agent-<hash> (pid NNNN)`
      AND the PID in the lock reason is no longer alive
      (`kill -0 <pid>` fails — the harness exited uncleanly or the
      subagent has already returned), this is a stale end-state lock
      and the canonical cleanup is `git worktree unlock <path>`
      followed by `git worktree remove <path>` (no `--force`). See
      `~/.claude/rules/worktree-cleanup.md`. If the lock reason does
      not match the harness shape, or the PID is still alive (the
      subagent may be mid-run), **skip and report** — do not unlock
      a live subagent's worktree and do not force-remove. `--force`
      remains reserved for the data-loss carve-out (uncommitted work
      or unpushed commits the user has explicitly approved
      discarding), not for bypassing a lock.

   b. **Pass 2 — orphan branch refs with no worktree.** Some
      `worktree-*` branches are left behind as local refs after their
      worktree was already removed (the harness can leak these).
      Enumerate all local branches matching `worktree-*` that are
      **not** checked out in any worktree under `.claude/worktrees/`.
      For each, apply this decision tree:

      - **Branch has an upstream configured** (`git rev-parse
        --abbrev-ref --symbolic-full-name <branch>@{upstream}` succeeds
        and the upstream still exists on origin): use the same
        `@{upstream}..HEAD` empty check as Pass 1. If empty, delete the
        branch with `git branch -d`. If non-empty, skip and report
        (the branch holds unpushed work).
      - **Branch has no upstream configured, or the upstream is gone**
        (the harness creates these refs but never pushes them, so
        `@{upstream}..HEAD` fails loudly rather than giving a clean
        answer): fall back to a reachability check against
        `$DEFAULT_BRANCH` (detected at the top of this file).
        Concretely:

        ```bash
        if count=$(git rev-list "<branch>" ^"$DEFAULT_BRANCH" --count); then
          # rev-list succeeded; $count is trustworthy
          :
        else
          # rev-list errored (bad revision, etc.) — cannot verify
          count=""
        fi
        ```

        **Treat the `rev-list` exit status as authoritative.** Only act
        on `$count` when the command exited `0`. A non-zero exit (bad
        revision, etc.) must be read as "cannot verify — skip and
        report," never as an empty-string-that-looks-like-zero count.
        An errored `git rev-list` must NOT be allowed to read as "safe
        to delete."

        If `rev-list` succeeded and the count is `0`, every commit on
        `<branch>` is already reachable from `$DEFAULT_BRANCH` — the ref
        is a stale starting point with no unique history, so deleting it
        loses nothing. Delete with `git branch -D` (the `-D` form is
        required because the no-upstream state makes `git branch -d`
        refuse with "not fully merged" even though the commits are in
        fact reachable from the default branch).

        If `rev-list` succeeded and the count is non-zero, the branch
        has commits not on the default branch — skip and report so the
        human can investigate before any history is dropped.

6. Do **not** auto-clean nested worktrees
   (`.claude/worktrees/*/.claude/worktrees/`). If any are detected,
   report them with a note that nested worktrees indicate
   [Anthropic issue #47548](https://github.com/anthropics/claude-code/issues/47548)
   (`isolation: worktree` spawned from inside a worktree) and need
   human inspection. Auto-removing them risks data loss.
7. Run `git worktree prune` to clean up any stale worktree references.
8. Run `git fetch --all --prune` again to refresh tracking branches and
   remove stale remote refs.
9. Pull `$DEFAULT_BRANCH` (detected at the top of this file) forward:
   a. Check `git worktree list` first. If `$DEFAULT_BRANCH` is
      currently checked out in another worktree (the harness sometimes
      keeps a worktree on the default branch), do **not** `git switch`
      to it from the primary clone — git refuses to check out a branch
      claimed by another worktree. Instead, update the existing
      checkout in place: `git -C <that-path> pull --ff-only`.
      (Note: this `git -C` use is in *this script*, not in a subagent
      Bash call, so the subagent forbidden-form rule doesn't apply.)
   b. If `$DEFAULT_BRANCH` is **not** checked out elsewhere:
      - `git switch "$DEFAULT_BRANCH"`
      - `git pull --ff-only`

10. Final summary — report counts:
    - Merged branches deleted (local + remote)
    - Subagent worktrees removed (Step 5a / Pass 1)
    - Orphan `worktree-*` branch refs deleted (Step 5b / Pass 2),
      broken down by which path applied (upstream-empty vs.
      no-upstream-reachable-from-default-branch)
    - Worktrees skipped, with reason for each (uncommitted changes,
      unpushed commits, nested worktree, etc.)
    - Orphan branch refs skipped, with reason for each (non-zero
      reachability count, rev-list could not verify, etc.)
    - Default branch updated (and whether it was updated in place
      via `git -C`)

    List anything that was skipped so the human can investigate.
