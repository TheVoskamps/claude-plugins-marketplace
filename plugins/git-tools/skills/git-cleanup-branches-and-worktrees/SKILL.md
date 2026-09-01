---
name: git-cleanup-branches-and-worktrees
description: Clean up merged local branches and reclaim the worktrees under `.claude/worktrees/` that hold nothing anyone can lose, reporting what it could not touch.
---

# git-cleanup-branches-and-worktrees

Please clean up merged local branches (regardless of naming
convention), reclaim the worktrees under `.claude/worktrees/` that hold
nothing anyone can lose, and report everything you had to leave.

This skill is written to be the **only** worktree cleanup a caller
needs, so that a caller that spawns worktrees can invoke it — or tell
the human to — rather than carrying an inline copy of the
unlock-then-remove procedure. Every such copy is an opportunity to
improvise when the happy path fails, and an improvised fallback that
reaches for a glob `rm` consults no gate at all. So the removal
*mechanism*, not just the gates around it, lives in one section here,
and a caller restates neither.

The sections below are named rather than numbered, and every reference
in this file names the section it means. Run them in the order they
appear.

## The protected branch

This skill protects exactly **one** branch: the repo's default
branch, detected dynamically at runtime. That branch is never deleted,
is always excluded from the merged-branch enumeration, is the "fully
landed" yardstick "Removing a worktree" and "Reclaim orphan
`worktree-*` branch refs" both measure against, and is the branch
"Pull the default branch forward" updates at the end.

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
to delete. Because the protected set is a single,
guaranteed-to-exist ref, the previous failure mode — a hardcoded list
naming branches the repo doesn't have, causing `git rev-list` to abort
with `fatal: bad revision` — cannot occur.

## Refresh the remote state

Run `git fetch --all --prune` to refresh tracking branches and remove
stale remote refs. Every gate below reads remote state, so this runs
before any of them.

## Removing a worktree

This is the one removal procedure. Every pass below points here and
restates none of it: a pass decides **which** worktrees to consider,
and this section decides whether each one goes and how.

**The gates are content-based, not ownership-based.** A worktree that
is clean, holds no commits that exist nowhere else, and carries no
live-PID lock holds nothing anyone can lose, whoever spawned it. That
is what makes this safe to run against a `.claude/worktrees/` shared
with other live sessions without having to establish whose each entry
is. Removing a worktree **never** deletes its branch — branch deletion
is "Deleting a branch", reached only by the passes whose own gate
establishes the branch has landed.

Take the worktree's **absolute** path from `git worktree list` and use
it verbatim. `git worktree remove` resolves a short argument against
the cwd first and then by unique suffix match, so a short form can
remove a different worktree than you meant or match two and fail with
an error that reads as though the worktree were already gone. See
`docs/agent-tooling-notes.md` → "Remove a worktree by the path
`git worktree list` prints".

Apply these gates in order. Any gate that does not clearly pass means
**skip the worktree and report the reason** — never route around a
gate, and never widen the mechanism to get past one.

1. **Clean working tree.** `git -C <path> status --porcelain` is
   empty. (This `git -C` is in *this* script, not in a subagent's Bash
   call, so the subagent forbidden-form rule does not apply.)

2. **No unreachable commits.** The worktree must hold no commit that
   exists nowhere else. Which comparison answers that depends on what
   its HEAD is:

   - **Detached HEAD** — reachable from some remote ref or from
     `$DEFAULT_BRANCH`:

     ```bash
     count=$(git -C <path> rev-list --count HEAD --not --remotes "$DEFAULT_BRANCH")
     ```

   - **Attached branch with a resolvable `@{upstream}`** —
     `@{upstream}..HEAD` is empty:

     ```bash
     count=$(git -C <path> rev-list --count '@{upstream}..HEAD')
     ```

     Do **not** compare against `$DEFAULT_BRANCH` here: a feature
     branch is expected to diverge from it, and what matters is
     whether the branch is fully pushed to its own remote.

   - **Attached branch with no upstream configured, or an upstream
     that is gone** — the same yardstick as the detached case. The
     harness creates refs it never pushes, so `@{upstream}..HEAD`
     fails loudly rather than giving a clean answer.

   In every arm the **`rev-list` exit status is authoritative**. Act on
   `$count` only when the command exited `0`; a non-zero exit reads as
   "cannot verify: skip and report", never as an empty-string that
   looks like a zero count. An errored `rev-list` must never read as
   "safe to remove". A `$count` of `0` passes the gate; anything else
   is a skip.

3. **The lock gate.** Attempt the removal; if it fails with
   `fatal: cannot remove a locked working tree`, read the lock reason
   from `git worktree list --porcelain`. Unlocking is allowed **only**
   when both hold:

   - the lock reason matches the harness end-state shape
     `claude agent agent-<hash> (pid NNNN)`, and
   - that PID is no longer alive (`kill -0 <pid>` fails).

   Then `git worktree unlock <absolute-path>` and re-run the removal.
   A lock reason of any other shape, or a **live** PID, is a skip with
   the reason reported — a live PID means a subagent may be mid-run,
   and that holds in every pass without exception. No branch gate
   anywhere in this file licenses unlocking a live-PID worktree.

The mechanism is bounded here and nowhere else: plain
`git worktree remove` against the absolute path, never `--force`,
never `rm`, never a glob. Force-removal is reserved for the data-loss
carve-out — uncommitted work or unpushed commits the human has
explicitly chosen to discard — which is a decision this skill does not
make and therefore an outcome it does not produce. A removal that
fails for any reason other than the lock case above is reported, never
routed around.

## Deleting a branch

Branch deletion is separate from worktree removal and is reached only
from a pass whose gate has established the branch has landed —
"Reclaim merged branches" (merged PR + remote gone) or "Reclaim orphan
`worktree-*` branch refs" (the reachability check). Nothing else in
this file deletes a branch.

- Delete the local ref with `git branch -D`. The `-D` form is required
  because a stale worktree checkout or an absent upstream makes
  `git branch -d` refuse with "not fully merged" even when the commits
  are in fact reachable.
- Delete the remote branch only if the calling pass's `git ls-remote`
  showed it still exists. This is defensive; usually it is already
  gone, which was part of the gate.
- A branch still checked out in a worktree is **not** deleted. Report
  it, with the worktree path and the reason that worktree was skipped.

## Reclaim clean-and-reachable worktrees

Enumerate **every** worktree under `.claude/worktrees/` from
`git worktree list --porcelain`, regardless of branch name or HEAD
state, and apply "Removing a worktree" to each. Nothing about the
branch a worktree holds is a gate here, and no branch is deleted for a
worktree this pass reclaims.

The wide enumeration is the point. Narrower ones miss most of what a
run leaves behind:

- A review pipeline's fan-out worktrees are **detached HEAD** — each
  agent checks out `origin/<branch>` detached — so a branch-name
  pattern never sees them.
- A teammate's worktree holds the open PR's `issue-N-…` branch, which
  fails the merged-plus-remote-gone gate for as long as the PR stays
  open, which at the end of an orchestrated run it always is.

Both are reclaimable the moment their content says so, and neither
loses a branch by being reclaimed.

## Reclaim merged branches

List all local branches **except** `$DEFAULT_BRANCH`:

```bash
git for-each-ref --format='%(refname:short)' refs/heads/ \
  | grep -v -x "$DEFAULT_BRANCH"
```

This deliberately includes branches that don't match `issue-NNN-*`
(e.g. `add-foo-skill`, `fix-bar-allowlist`), because the gate is the
real safety signal, not the name pattern.

For each candidate, the gate is **PR merged AND remote branch gone** —
both must hold:

```bash
gh pr list --state merged --head <branch> --json number,mergedAt
git ls-remote --exit-code origin <branch>   # exit 2 = branch is gone
```

- `gh pr list` returns a non-empty result for a merged PR on this
  branch, and
- `git ls-remote --exit-code origin <branch>` exits 2.

"Issue closed and assigned to me" is **not** a sufficient signal: an
issue can be closed without its PR ever merging. A branch with no
merged PR — a local-only branch you never pushed, or a
remote-tracking branch for in-progress work — fails the gate and is
left alone. Closed-but-not-merged PRs are correctly excluded by
`--state merged`, and a force-pushed branch is handled correctly
because the gate requires the *branch* to be gone, not the local SHA
to match the remote tip.

**Note on the name-based PR match.** `gh pr list --head <branch>`
matches by branch *name*, not by SHA. Edge case: a branch was deleted,
then recreated with the same name and a different commit lineage, and
that new instance has its own merged PR. The name-based gate would
pass even though the local SHA points at the first, now-gone remote
tip. "Reclaim clean-and-reachable worktrees" is what catches it — in
that scenario the local branch's `@{upstream}` is gone, so the
no-unreachable-commits gate falls back to the reachability yardstick
and skips the worktree rather than removing it, and the branch below
is then skipped too.

For each branch where both conditions hold, apply "Deleting a branch".
Its worktree, if it had one, was already considered by "Reclaim
clean-and-reachable worktrees" above; a branch whose worktree that
pass skipped is skipped here as well, per that section.

## Reclaim orphan `worktree-*` branch refs

Claude Code's `isolation: worktree` produces branch names matching
`worktree-*` (e.g. `worktree-agent-a39b0297dc3421b9e`), and some are
left behind as local refs after their worktree is gone — the harness
leaks these, and the pass above never sees them because they have no
merged PR.

Enumerate all local branches matching `worktree-*` that are **not**
checked out in any worktree. For each:

- **Upstream configured and still present on origin**: the branch is
  landed when `git rev-list --count '<branch>@{upstream}..<branch>'` is
  `0`. Non-zero means it holds unpushed work — skip and report.
- **No upstream configured, or the upstream is gone**: fall back to
  reachability from `$DEFAULT_BRANCH`:

  ```bash
  if count=$(git rev-list --count "<branch>" ^"$DEFAULT_BRANCH"); then
    :        # rev-list succeeded; $count is trustworthy
  else
    count="" # rev-list errored (bad revision, etc.) — cannot verify
  fi
  ```

  **Treat the `rev-list` exit status as authoritative**, exactly as
  "Removing a worktree" does: act on `$count` only on a zero exit, and
  read a non-zero exit as "cannot verify — skip and report". A count
  of `0` means every commit on the branch is already reachable from
  `$DEFAULT_BRANCH`, so the ref is a stale starting point with no
  unique history and deleting it loses nothing; a non-zero count means
  the branch holds history the default branch does not, so skip and
  report before any of it is dropped.

Where the gate passes, apply "Deleting a branch".

## Nested worktrees are report-only

Do **not** auto-clean nested worktrees
(`.claude/worktrees/*/.claude/worktrees/`). If any are detected,
report them with a note that they need human inspection: a nested
registry is not a state this skill's gates were measured against, and
reclaiming one risks data loss. "Reclaim clean-and-reachable
worktrees" does not reach them either.

## Prune, then sweep the filesystem

Run `git worktree prune` to clear stale worktree registrations, then
compare what is on disk against what git knows:

```bash
ls -A .claude/worktrees/
git worktree list --porcelain
```

For each entry in the listing that git does not know about, read
`<dir>/.git` to identify what it is. A worktree checkout carries a
one-line `gitdir: <owner-repo>/.git/worktrees/<name>` pointer, which
names the repository the entry is registered to; a directory or file
without one is plain debris.

**This sweep deletes nothing.** Name every such entry in the final
summary — a foreign-repo worktree with the owning-repo path read from
its `.git` file, a stray file or directory as such — and leave it in
place. The owning repo's registry is outside the current repository,
so reclaiming one of its worktrees needs human judgment. A run where
the filesystem listing and `git worktree list` agree adds nothing to
the summary.

This pass exists because entries not registered to the current repo
are invisible to `git worktree list` entirely, so every enumeration
above passes straight over them and a cleanup can report itself
complete with tens of megabytes of another clone's checkouts still
sitting under `.claude/worktrees/`.

Then run `git fetch --all --prune` again, to pick up anything the
branch deletions above changed.

## Pull the default branch forward

Check `git worktree list` first. If `$DEFAULT_BRANCH` is currently
checked out in another worktree, do **not** `git switch` to it from
the primary clone — git refuses to check out a branch claimed by
another worktree. Update that checkout in place instead:
`git -C <that-path> pull --ff-only`.

If `$DEFAULT_BRANCH` is not checked out elsewhere:

```bash
git switch "$DEFAULT_BRANCH"
git pull --ff-only
```

## Final summary

Report:

- Worktrees reclaimed (from "Reclaim clean-and-reachable worktrees"),
  by path.
- Merged branches deleted, local and remote.
- Orphan `worktree-*` branch refs deleted, broken down by which arm
  applied (upstream-empty vs. reachable-from-default-branch).
- Worktrees skipped, with the reason for each — dirty tree, commits
  reachable from nowhere, a rev-list that could not verify, a live-PID
  lock, an unrecognised lock reason, nested worktree.
- Branch refs skipped, with the reason for each.
- Entries the filesystem sweep found that git does not own: a
  foreign-repo worktree with its owning-repo path, a stray file or
  directory as such. None of these were deleted.
- Whether the default branch was updated, and whether in place via
  `git -C`.

List everything skipped, with its reason, so the human can
investigate. A skip is the expected outcome for anything that still
holds work, and reporting it is what makes this skill safe to run
against a shared `.claude/worktrees/`.
