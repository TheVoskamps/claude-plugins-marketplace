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

1. Refresh the tracking refs the gates below read — `origin`, plus
   every remote a local branch's upstream names:

   ```bash
   # origin's failure stops the run — see below
   git fetch --prune origin || exit 1

   # every other remote's outcome is recorded, not fatal
   FAILED_REMOTES=""
   for remote in $(git for-each-ref --format='%(upstream:remotename)' \
     refs/heads/ | sort -u | grep -v -x -e '' -e 'origin'); do
     git fetch --prune "$remote" \
       || FAILED_REMOTES="$FAILED_REMOTES$remote "
   done
   ```

   Every gate below that asks whether work has been pushed answers from
   local remote-tracking refs and never from the remote itself, and
   which refs those are is decided per candidate rather than once for
   the run: step 4a's `@{upstream}..HEAD` and Pass 2's
   `<branch>@{upstream}..<branch>` read the tracking refs of whatever
   remote *that branch's* upstream names, while Pass 1's
   `HEAD --not --remotes=origin` reads `refs/remotes/origin/*`. A
   tracking ref git has not refreshed can name a commit its remote no
   longer serves, which is exactly the state that makes one of those
   gates read "already pushed" for work that is nowhere else, so this
   fetch is the precondition they rest on rather than a convenience:
   with it skipped there is nothing below that is safe to act on, and
   where it fails the candidates resting on that remote are
   disqualified below. `--prune` is the half that removes the tracking
   refs for branches the remote has deleted.

   Enumerating the upstreams is what makes the set of remotes match the
   set of candidates. `origin` alone leaves a branch tracking a second
   remote gated on refs nothing refreshed; `--all` would instead fetch
   remotes no candidate is gated on. `origin` is fetched unconditionally
   even so, because step 3's `git ls-remote origin` and Pass 1's
   `--remotes=origin` read it whether or not any branch tracks it.

   A fetch that fails disqualifies exactly the candidates gated on that
   remote's refs. `origin`'s failure **stops the run**: step 3 gates
   every branch candidate on origin and Pass 1 gates every worktree on
   it, so there is nothing left below worth proceeding for. Another
   remote's failure skips the branches whose upstream names it, reported
   by branch and remote, and the rest of the run proceeds.

   `$FAILED_REMOTES` above is that record, and this predicate is how
   every gate below reads it — a candidate is disqualified when its own
   upstream names a remote in the set:

   ```bash
   # exit 0 = this branch's upstream remote failed to fetch
   fetch_failed_for() {   # $1 = branch name
     upstream_remote=$(git for-each-ref \
       --format='%(upstream:remotename)' "refs/heads/$1")
     [ -n "$upstream_remote" ] || return 1
     case " $FAILED_REMOTES" in
       *" $upstream_remote "*) return 0 ;;
     esac
     return 1
   }
   ```

   A branch with no upstream configured returns 1: it is gated on no
   remote's refs, so no fetch outcome can disqualify it, and the arms
   that handle it read `$DEFAULT_BRANCH` instead. Two gates call this,
   and they are exactly the two that read a candidate's own upstream —
   step 3, standing in front of the whole delete-a-merged-branch path
   including step 4a's `@{upstream}..HEAD`, and Pass 2's first arm.
   Pass 1's `--remotes=origin` calls it for nothing, because origin's
   failure has already stopped the run. A disqualified candidate is
   **skipped and reported** by step 10, never fallen through to a
   different arm — falling through to a `$DEFAULT_BRANCH` reachability
   check would answer a question about the default branch when the
   question asked was whether this branch's own work reached its remote.

   What the fetch cannot cover is what happens on a remote *after* it:
   a branch deleted or force-pushed mid-run leaves this run reading the
   refs as they were. Read every gate below as answering "as of step
   1's fetch", and re-run the skill rather than trusting a run that has
   been sitting open.
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

   First consult step 1's fetch record: if `fetch_failed_for <branch>`
   succeeds, **skip the candidate and report it by branch and remote**.
   Step 4a's `@{upstream}..HEAD` is the gate that would otherwise read
   that remote's tracking refs, and a ref this run could not refresh
   reads "fully pushed" for work the remote may no longer hold. The
   skip covers 4a, 4b and 4c alike, because the branch deletion in 4b
   is the data-loss event and it rests on the same unrefreshed ref.

   For a candidate that survives that, the check is **PR merged AND
   remote branch is gone** — both must hold.
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
      harness shape `claude agent agent-<hash> (pid NNNN …)` AND (the
      PID is no longer alive (`kill -0 <pid>` fails) OR the branch
      passed step 3's "merged + remote gone" gate (which is the case
      here, since we're inside step 4)), this is a stale end-state
      lock from a returned or crashed subagent — run
      `git worktree unlock <path>` then re-run
      `git worktree remove <path>` (no `--force`). If the lock reason
      does not match the harness shape, or the uncommitted/unpushed
      check above failed, skip and report — do not unlock and do not
      force-remove.
   b. Delete the local branch (`git branch -D`).
      (Safe because step 3 already confirmed the PR was merged AND the
      remote branch is gone; `git branch -d` gives false negatives when
      worktree checkouts are stale.)
   c. Delete the remote branch only if step 3's `git ls-remote` shows
      it still exists (defensive — usually it's already gone, which
      was part of the gate).

5. Clean up `isolation: worktree` subagent worktrees and their
   leftover branch refs. Claude Code's `isolation: worktree` hands each
   subagent a directory under `.claude/worktrees/` and creates a branch
   matching `worktree-*` for it (e.g.
   `worktree-agent-a39b0297dc3421b9e`) — but that branch is often not
   what the worktree has checked out by the time you get here, so only
   Pass 2 keys on the name.

   Enumerate candidates in these passes:

   a. **Pass 1 — worktrees that still exist.** List **every** worktree
      under `.claude/worktrees/`, whatever it has checked out. Do not
      filter this enumeration by branch name: an agent typically checks
      out the branch it was sent to work on and detaches HEAD before it
      returns, so its worktree is on a detached HEAD or on an issue
      branch, and almost never on the `worktree-*` branch it was handed.
      (Measured in this repo during one orchestrated run: six live agent
      worktrees, all six on detached HEAD — a `worktree-*` filter
      enumerated none of them.) The gates below are the safety signal;
      the name never was.

      For each, run the safety check:
      - no uncommitted changes (`git status --porcelain` empty)
      - no commits missing from the remote. A detached worktree has no
        `@{upstream}`, so use a form that needs neither a branch nor an
        upstream:

        ```bash
        git rev-list HEAD --not --remotes=origin --count
        ```

        It asks a **broader** question than `@{upstream}..HEAD`: is
        everything at this HEAD anywhere on origin, rather than on this
        branch's own upstream in particular. The two answers diverge
        when a HEAD's commits reached origin under some other ref —
        non-zero for `@{upstream}..HEAD`, zero here — and where they
        diverge this form is the one to trust, because nothing is lost
        by removing a worktree whose every commit origin still serves
        under some name, which is the question this gate
        exists to ask.

        What makes the count answer *that* question rather than a
        weaker one is step 1's `git fetch --prune origin`, and that is
        why a failed fetch there stops the run. The command reads
        `refs/remotes/origin/*` and never the remote: against a
        tracking ref for a branch origin has deleted, a zero count says
        only that some local ref still names the commit. Nothing is
        lost at removal even then — the object stays reachable through
        that stale ref. The fetch is what keeps that ref from being
        stale by the time this gate reads it. Treat the `rev-list` exit
        status as authoritative: act on
        the count only on exit `0`, and read any non-zero exit as
        "cannot verify — skip and report". Do **not** compare against the
        default branch — feature and worktree branches are expected to
        diverge from it; what matters is whether the commits are on
        origin somewhere.

      If both checks pass: remove the worktree (`git worktree remove`,
      no `--force`), then delete its checked-out branch (`git branch
      -d`) **only when that branch matches `worktree-*`**. A detached
      worktree leaves no branch to delete here, and its leaked
      `worktree-*` ref, if any, is Pass 2's. Never delete any other
      branch from this pass: a worktree can hold an issue branch whose
      PR is still open, and step 3's merged-PR-plus-remote-gone gate is
      the only path by which such a branch is deleted.
      If either check fails: skip and report the reason.

      If `git worktree remove` fails with `fatal: cannot remove a
      locked working tree`, inspect the lock reason via
      `git worktree list --porcelain`. If the lock reason matches the
      standard harness shape `claude agent agent-<hash> (pid NNNN …)`
      AND the PID in the lock reason is no longer alive
      (`kill -0 <pid>` fails — the harness exited uncleanly or the
      subagent has already returned), this is a stale end-state lock
      and the canonical cleanup is `git worktree unlock <path>`
      followed by `git worktree remove <path>` (no `--force`). If the
      lock reason does not match the harness shape, or the PID is
      still alive (the
      subagent may be mid-run), **skip and report** — do not unlock
      a live subagent's worktree and do not force-remove. This is the
      check that keeps a running agent's worktree out of the pass, and
      with the enumeration above widened past `worktree-*` it is doing
      that job for every agent worktree rather than a subset of them:
      the harness holds a lock naming its own PID for as long as the
      subagent runs. Match that shape by its prefix, never as a whole
      string — the parenthesis carries more than the PID (measured
      here: `claude agent agent-<hash> (pid 97557 start Wed Sep  2
      23:15:24 2026)`), and a whole-string match would read every live
      lock as unrecognized. `--force` remains reserved for the
      data-loss carve-out (uncommitted work or unpushed commits the
      user has explicitly approved discarding), not for bypassing a
      lock.

   b. **Pass 2 — orphan branch refs with no worktree.** Some
      `worktree-*` branches are left behind as local refs after their
      worktree was already removed (the harness can leak these).
      Enumerate all local branches matching `worktree-*` that are
      **not** checked out in any worktree under `.claude/worktrees/`.
      For each, apply this decision tree:

      - **Branch has an upstream configured** (`git rev-parse
        --abbrev-ref --symbolic-full-name <branch>@{upstream}` succeeds
        and the upstream's own tracking ref still exists — the remote
        that upstream names, which is `%(upstream:remotename)` for this
        branch and not necessarily origin): consult step 1's fetch
        record first — if `fetch_failed_for <branch>` succeeds, skip
        and report by branch and remote rather than falling through to
        the arm below. Otherwise check that
        `git rev-list <branch>@{upstream}..<branch>` is empty — the
        branch is checked out in no worktree, so the check names the
        branch rather than `HEAD`, and a configured upstream answers
        the question directly where Pass 1's detached worktrees forced
        the broader `--remotes=origin` form. If empty, delete the
        branch with `git branch -d`. If non-empty, skip and report (the
        branch holds unpushed work).
      - **Branch has no upstream configured, or the upstream is gone**
        (the harness creates these refs but never pushes them, so the
        arm above — `git rev-list <branch>@{upstream}..<branch>` —
        fails loudly rather than giving a clean
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
   report them with a note that they need human inspection. Every
   worktree this skill knows how to reason about is a flat sibling
   under the primary clone, so a nested one was made by something
   this skill cannot account for — none of the gates above tell you
   who owns it or whether its work has landed. Auto-removing them
   risks data loss.
7. Run `git worktree prune` to clean up any stale worktree references.
8. Run `git fetch --all --prune` to leave every remote's tracking refs
   current after the deletions above. This is not step 1's fetch
   repeated: every gate has already run, so no gate rests on this one,
   and `--all` covers the remotes step 1 had no candidate to fetch them
   for as well as the ones it did.
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
    - Remotes whose step 1 fetch failed, if any, one line each
    - Merged-branch candidates skipped at step 3 because their
      upstream's remote failed to fetch, named by branch and remote
    - Worktrees skipped, with reason for each (uncommitted changes,
      unpushed commits, nested worktree, etc.)
    - Orphan branch refs skipped, with reason for each (non-zero
      reachability count, rev-list could not verify, upstream's remote
      failed to fetch — that one named by branch and remote, etc.)
    - Default branch updated (and whether it was updated in place
      via `git -C`)

    List anything that was skipped so the human can investigate.
