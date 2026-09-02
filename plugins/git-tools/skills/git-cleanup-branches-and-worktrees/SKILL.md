---
name: git-cleanup-branches-and-worktrees
description: Clean up merged local branches and reclaim every worktree under `.claude/worktrees/` that holds nothing anyone can lose. The one place a run's leftovers are removed.
---

# git-cleanup-branches-and-worktrees

Please clean up merged local branches (regardless of naming convention)
and their worktrees, plus everything an `isolation: worktree` subagent
run leaves behind under `.claude/worktrees/`.

This skill is the **only** place a run's leftovers get reclaimed.
`/sdlc:orchestrate` runs its whole flow without removing anything and
reaches one invocation of this skill at the end. Everything it spawns
removes nothing at all — `sdlc:theorem-based-pr-reviewer` and its
fan-out included — and `/sdlc:git-review-pr`, which a human runs
directly, leaves its reviewer's worktrees for whenever that human
invokes this skill. That is what makes "how a worktree is removed" a
single procedure with a single answer rather than a pattern each caller
improvises when its happy path fails.

One deletion is not reclamation and stays outside this skill: a
subagent that checked its branch out attached runs `git branch -D` on
that branch at the end of its own run. Worktrees of one repo share a
single ref store, so that ref is a **claim** the next subagent cannot
check out until it is released — the branch itself lives on the remote
throughout. This skill deletes a branch only once a gate below has
established it landed.

The sections below are **named, never numbered**, and every
cross-reference names a section. Numbering is what let one removal
procedure exist in two places without the file admitting it: two steps
with different numbers read as two different things even when they say
the same words.

## Protected branch

This skill protects exactly **one** branch: the repo's default
branch, detected dynamically at runtime. That branch is **never**
deleted by this skill, is always excluded from the merged-branch scan
in "Pass: merged branches", and is the "fully landed" yardstick that
"Pass: orphan `worktree-*` branch refs" and "Removing a worktree" both
measure reachability against. It is also the branch "Pull the default
branch forward" updates at the end of the run.

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
subject to the gates the passes below apply. Because the protected set
is a single, guaranteed-to-exist ref, the previous failure mode — a
hardcoded list naming branches the repo doesn't have, causing
`git rev-list` to abort with `fatal: bad revision` — cannot occur.

## Refresh remote state

Run `git fetch --all --prune` to refresh tracking branches and remove
stale remote refs. Every gate below reads remote state, so a run that
skips this grades branches against a stale picture.

## Removing a worktree

This is the **one** removal procedure in this skill. Every pass below
points here and restates none of it. Passes differ in *which worktrees
they enumerate* and — for branch deletion — *which gate establishes the
branch has landed*; none of them differ in how a removal is performed.

**The mechanism is bounded here and nowhere else.** A worktree is
removed with plain `git worktree remove` against the **absolute** path
`git worktree list` prints:

```bash
git worktree list
git worktree remove <absolute-path-from-the-listing>
```

Never `--force`, never `rm`, never a glob, and never a short
`.claude/worktrees/<name>` argument. `git worktree remove` resolves a
short argument cwd-relative first and then by unique component-aligned
suffix, so which worktree a short argument names depends on where you
stand and on what else is registered; the absolute path names one
unconditionally. See `docs/agent-tooling-notes.md` → "Remove a worktree
by the path `git worktree list` prints". A removal that fails is
reported, never routed around: there is no fallback spelling, and a
glob `rm` consults no gate at all, which is why it is out even as a
last resort.

**Preconditions — all must hold, or the worktree is skipped and
reported with the reason:**

1. **The working tree is clean.** `git status --porcelain` inside the
   worktree is empty.

2. **It holds no commits that exist nowhere else.** Which check applies
   depends on the worktree's HEAD state:

   - **Detached HEAD** (what the review fan-out agents leave — each
     checks out `origin/<branch>` detached): every commit must be
     reachable from some remote ref or from `$DEFAULT_BRANCH`.
   - **Attached branch with a resolvable `@{upstream}`**:
     `@{upstream}..HEAD` must be empty. Do **not** compare against the
     default branch here — a feature branch is expected to diverge from
     it; what matters is whether the branch is fully pushed to its own
     remote.
   - **Attached branch with no upstream configured, or an upstream that
     is gone**: `@{upstream}..HEAD` fails loudly rather than giving a
     clean answer, so fall back to the same reachability yardstick as
     the detached case.

   ```bash
   # detached, or attached with no usable upstream
   if count=$(git -C <path> rev-list --count HEAD \
       --not --remotes "$DEFAULT_BRANCH"); then
     : # rev-list succeeded; $count is trustworthy
   else
     count=""   # rev-list errored — cannot verify
   fi
   ```

   **Treat the `rev-list` exit status as authoritative in every arm.**
   Act on the count only when the command exited `0`. A non-zero exit
   (bad revision, unresolvable upstream, etc.) reads as "cannot verify:
   skip and report", never as an empty-string-that-looks-like-zero
   count. An errored `git rev-list` must NOT be allowed to read as
   "safe to remove".

3. **The lock gate passes.** If `git worktree remove` fails with
   `fatal: cannot remove a locked working tree`, inspect the lock
   reason via `git worktree list --porcelain`. Unlock-then-remove is
   allowed only when **both** hold: the lock reason matches the harness
   end-state shape

   ```text
   claude agent agent-<hash> (pid NNNN start <date>)
   ```

   **and** the PID it carries belongs to no session other than the one
   invoking this skill — either the PID is no longer alive
   (`kill -0 <pid>` fails), or it is one of the invoking shell's own
   ancestors.

   That PID is the **spawning session's**, not the subagent's: one
   `claude` process stamps its own PID on every worktree it spawns and
   outlives all of them (see `docs/agent-tooling-notes.md` → "A
   worktree lock's PID is the session's, not the agent's"). So a live
   PID says some session is running, never that a particular agent
   still is. A foreign live PID is hands-off on that basis. The
   invoking session's own PID is not: it is alive because it is
   running this cleanup, and a gate that read it as a live agent would
   make a session unable to reclaim any worktree it ever spawned.

   ```bash
   # the PIDs that are this session's rather than a foreign session's
   pid=$$
   while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
     printf '%s\n' "$pid"
     pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
   done

   git worktree unlock <absolute-path-from-the-listing>
   git worktree remove <absolute-path-from-the-listing>
   ```

   If the lock reason does not match the harness shape, or its PID is
   alive and outside that ancestry, **skip and report** — a foreign
   live session may be mid-run, and no branch-side gate overrides
   that. `--force` is reserved for the data-loss carve-out
   (uncommitted work or unpushed commits the user has explicitly
   approved discarding) and is never used to bypass a lock.

**Removals are serial, never parallel** — see
[Anthropic issue #48927](https://github.com/anthropics/claude-code/issues/48927)
for a parallel-cleanup data-loss bug.

**Removing a worktree never implies deleting its branch.** Branch
deletion is a separate decision with its own gate; see "Deleting a
landed branch".

## Deleting a landed branch

This is the one place a branch is deleted. It is reached **only** from
a pass whose gate has established the branch landed — "Pass: merged
branches" (merged PR + remote gone) and "Pass: orphan `worktree-*`
branch refs" (the reachability check). No other pass reaches it, and
"Pass: clean and reachable worktrees" deliberately does not: reclaiming
a directory says nothing about whether its branch still has work to do.

```bash
git branch -D <branch>
```

`-D` rather than `-d`: `git branch -d` gives false negatives when a
worktree checkout is stale, and it refuses "not fully merged" for a
branch with no upstream even when every commit is reachable from
`$DEFAULT_BRANCH`. The calling pass's gate is what makes `-D` safe, so
never call this section without one.

Delete the remote branch too only when the calling pass observed it
still exists (defensive — the merged-branch gate already requires it to
be gone).

## Pass: merged branches

List all local branches **except** `$DEFAULT_BRANCH`:

```bash
git for-each-ref --format='%(refname:short)' refs/heads/ \
  | grep -v -x "$DEFAULT_BRANCH"
```

This deliberately includes branches that don't match `issue-NNN-*`
(e.g. `add-foo-skill`, `fix-bar-allowlist`), because the gate is the
real safety signal, not the name pattern.

**The gate is: PR merged AND remote branch is gone** — both must hold.
"Issue closed and assigned to me" is **not** a sufficient signal: an
issue can be closed without its PR ever merging, and an unmerged branch
may still hold work that hasn't landed on the default branch.

```bash
gh pr list --state merged --head <branch> --json number,mergedAt
git ls-remote --exit-code origin <branch>   # exit 2 = branch is gone
```

Both conditions must be true:

- `gh pr list` returns a non-empty result for a merged PR on this branch
- `git ls-remote --exit-code origin <branch>` exits 2 (branch absent on
  origin)

A branch with no merged PR (a local-only branch you never pushed, or a
remote-tracking branch for in-progress work) fails the gate and is left
alone.

**Note on the name-based PR match.** `gh pr list --head <branch>`
matches by branch *name*, not by SHA. Edge case: a branch was deleted,
then later recreated with the same name and a different commit lineage,
and that new instance has its own merged PR. The name-based gate would
pass even though the local SHA points at the *first* (now-gone) remote
tip. "Removing a worktree"'s reachability precondition catches that —
the local branch's `@{upstream}` is gone in that scenario, so the check
falls back to reachability and skips rather than removing silently.

Closed-but-not-merged PRs are correctly excluded by `--state merged`.
Force-pushed branches are handled correctly too: the gate requires the
*branch* to be gone, not the local SHA to match the remote tip.

For each branch that passes the gate: remove any worktree under
`.claude/worktrees/` that has it checked out, per "Removing a worktree",
then delete the branch per "Deleting a landed branch". A worktree the
removal procedure skips takes its branch with it — leave both and report
the reason.

## Pass: clean and reachable worktrees

Enumerate **every** worktree under `.claude/worktrees/` from
`git worktree list --porcelain`, regardless of branch name or HEAD
state, save the nested ones under
`.claude/worktrees/*/.claude/worktrees/`, which are report-only per
"Nested worktrees are report-only". Put each of the rest through
"Removing a worktree". Nothing else decides: this pass's gate *is* that
procedure's preconditions, and anything they skip is reported with its
reason.

Removal here is the **directory only** — no branch is ever deleted by
this pass. That is what lets it reclaim a teammate worktree still
holding an open PR's `issue-N-…` branch, and a review agent's
detached-HEAD fan-out worktree, neither of which any landed-branch gate
would ever pass.

The gates are deliberately **content**-based rather than
ownership-based. A worktree that is clean, holds no commits that exist
nowhere else, and carries no lock held by another live session holds
nothing anyone can lose, whoever spawned it — so this pass is safe to
run against a `.claude/worktrees/` shared with other live sessions
without asking whose each entry is. Ownership is not knowable from the
listing anyway, and a run that tried to guess it would either skip
everything or improvise, which is the failure this skill exists to
prevent.

## Pass: orphan `worktree-*` branch refs

Some `worktree-*` branches — the branch names Claude Code's
`isolation: worktree` produces, e.g.
`worktree-agent-a39b0297dc3421b9e` — are left behind as local refs
after their worktree is gone (the harness can leak these, and "Pass:
clean and reachable worktrees" creates more of them by design, since it
never deletes a branch).

Enumerate all local branches matching `worktree-*` that are **not**
checked out in any worktree, and apply this decision tree:

- **Branch has an upstream configured** (`git rev-parse --abbrev-ref
  --symbolic-full-name <branch>@{upstream}` succeeds and the upstream
  still exists on origin): if `@{upstream}..HEAD` is empty, delete it
  per "Deleting a landed branch". If non-empty, skip and report — the
  branch holds unpushed work.
- **Branch has no upstream configured, or the upstream is gone** (the
  harness creates these refs but never pushes them, so
  `@{upstream}..HEAD` fails loudly rather than giving a clean answer):
  fall back to a reachability check against `$DEFAULT_BRANCH`:

  ```bash
  if count=$(git rev-list "<branch>" ^"$DEFAULT_BRANCH" --count); then
    : # rev-list succeeded; $count is trustworthy
  else
    count=""   # rev-list errored — cannot verify
  fi
  ```

  **The `rev-list` exit status is authoritative**, exactly as in
  "Removing a worktree": act on `$count` only on a `0` exit, and read a
  non-zero exit as "cannot verify — skip and report".

  A count of `0` means every commit on `<branch>` is already reachable
  from `$DEFAULT_BRANCH` — the ref is a stale starting point with no
  unique history, so deleting it loses nothing. Delete it per "Deleting
  a landed branch". A non-zero count means the branch has commits that
  are nowhere else: skip and report so the human can investigate before
  any history is dropped.

## Nested worktrees are report-only

Do **not** auto-clean nested worktrees
(`.claude/worktrees/*/.claude/worktrees/`). "Pass: clean and reachable
worktrees" does not reclaim them either. If any are detected, report
them with a note that they need human inspection — a nested worktree is
an unusual topology this skill has no measured removal order for, and
auto-removing one risks data loss.

## Prune stale worktree references

Run `git worktree prune` to clean up worktree records whose directory
is already gone.

## Filesystem sweep (report-only)

`git worktree list` cannot see an entry in `.claude/worktrees/` that is
not registered to *this* repository, so a run can report cleanup
complete while tens of megabytes of another clone's worktrees sit in
the directory. After pruning, diff the filesystem against the registry:

```bash
ls -A .claude/worktrees/
git worktree list --porcelain
```

For each entry `ls` shows that no listed worktree path ends in, read
`<dir>/.git` to identify what it is. A worktree checkout carries a
one-line pointer:

```text
gitdir: <owner-repo>/.git/worktrees/<name>
```

Report each such entry with the owning repo's path taken from that
pointer, and report an entry with no such `.git` file as plain debris,
naming it too.

**Delete none of them.** The owning repo's registry is outside the
current repository, so removing one is a human decision — and the same
"absolute path only, no glob `rm`" rule that binds "Removing a worktree"
binds here with no mechanism left to apply it. A run where the
filesystem listing and `git worktree list` agree emits nothing here.

## Refresh remote state again

Run `git fetch --all --prune` again, so the summary and the default
branch update below read post-deletion state.

## Pull the default branch forward

Check `git worktree list` first. If `$DEFAULT_BRANCH` is currently
checked out in another worktree, do **not** `git switch` to it from the
primary clone — git refuses to check out a branch claimed by another
worktree. Update the existing checkout in place instead:

```bash
git -C <that-path> pull --ff-only
```

(This `git -C` use is in *this* procedure, not in a subagent Bash call,
so the subagent forbidden-form rule doesn't apply.)

If `$DEFAULT_BRANCH` is **not** checked out elsewhere:

```bash
git switch "$DEFAULT_BRANCH"
git pull --ff-only
```

## Final summary

Report:

- Merged branches deleted (local + remote), from "Pass: merged
  branches"
- Worktrees removed by "Pass: clean and reachable worktrees"
- Orphan `worktree-*` branch refs deleted, broken down by which path
  applied (upstream-empty vs. no-upstream-reachable-from-default-branch)
- Worktrees skipped, with the reason for each (uncommitted changes,
  unreachable commits, rev-list could not verify, lock held by another
  live session, unrecognized lock reason, nested worktree)
- Orphan branch refs skipped, with the reason for each
- Entries the filesystem sweep found that git does not know about —
  foreign-repo worktrees with their owning-repo path, and stray
  files/dirs — each named, none removed
- Default branch updated (and whether it was updated in place via
  `git -C`)

List everything that was skipped so the human can investigate. A caller
that invoked this skill as its terminal cleanup step relays this summary
as its own cleanup record rather than keeping a count of its own.
