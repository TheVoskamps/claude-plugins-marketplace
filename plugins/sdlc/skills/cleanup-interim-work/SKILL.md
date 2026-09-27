---
name: cleanup-interim-work
description: Index the interim work sdlc runs leave behind in this repo — .claude/tmp/ scratch, the harness scratchpads, subagent worktrees, and local and remote branches — grade each item, ask the human which to remove, and remove only those. --index-only reports the index and removes nothing.
---

# Cleanup Interim Work

An `sdlc` run leaves interim work behind wherever it went: task
scratch under `.claude/tmp/`, the harness's per-session scratchpads,
the throwaway worktrees `isolation: worktree` subagents run in, the
issue branches its PRs were opened from — locally and on `origin` —
and the `worktree-*` refs the harness creates and never pushes. This
skill finds all of it, says of each item whether it can go, and removes
nothing until the human has said which items to remove.

It runs in the main session, because it asks the human a question and
a subagent cannot.

## Invocation

```text
/sdlc:cleanup-interim-work [--index-only]
```

`--index-only` is the only argument. It runs "Index" and prints the
report, then stops: it asks nothing and removes nothing. Any other
token in `$ARGUMENTS` is not one this skill knows: say so and stop,
rather than guessing what was meant.

## The protected branch

This skill protects exactly **one** branch: the repo's default branch,
detected at the start of the run. It is never deleted, locally or on
`origin`, and it is excluded from every branch scan below. The
orphan-ref check uses it as the "fully landed" yardstick, and it is
the branch "Finish" pulls forward.

Do **not** hardcode branch names. Detect the default branch once and
reuse it everywhere below as `$DEFAULT_BRANCH`:

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
to remove.

## Index

Run `git fetch --all --prune` first, so the remote-tracking refs the
checks below read are current. Then grade every item in the six
categories below. Each item gets one verdict:

- **clean** — it passed its category's gate; name the action that
  would remove it.
- **keep** — it failed the gate; name the reason.
- **ask** — no gate can tell whether it is still wanted; list what the
  human needs to decide: its path, its size (`du -sh`), when it was
  last modified, and its top-level entries.

Nothing in this section removes anything.

### Local branches

List every local branch except `$DEFAULT_BRANCH`:

```bash
git for-each-ref --format='%(refname:short)' refs/heads/ \
  | grep -v -x "$DEFAULT_BRANCH"
```

This deliberately includes branches that don't match `issue-NNN-*`,
because the gate, not the name, is the safety signal. A `worktree-*`
branch fails the gate — it has no merged PR — and is graded under
"Subagent worktrees" or "Orphan `worktree-*` refs" instead.

The gate is **PR merged AND remote branch gone** — both must hold.
"Issue closed" is not a sufficient signal: an issue can be closed
without its PR ever merging, and an unmerged branch may still hold work
that has not landed on the default branch.

```text
/github-prs:pr-list --head <branch> --state merged
```

```bash
git ls-remote --exit-code origin <branch>   # exit 2 = branch is gone
```

The branch is **clean** when `/github-prs:pr-list` returns a non-empty
array and `git ls-remote` exits 2; its action is removing any worktree
under `.claude/worktrees/` that uses it, under the same safety checks
as "Subagent worktrees" below, then `git branch -D`. `-D` rather than
`-d` because `-d` gives false negatives when worktree checkouts are
stale, and the gate has already established that the work landed.
Every other branch is **keep**, with the half of the gate it failed.

`/github-prs:pr-list --head <branch>` matches by branch *name*, not by
SHA. A branch deleted and later recreated under the same name, whose
new instance has its own merged PR, passes the name-based gate even
though the local SHA points at the first, gone, tip. The worktree
safety check catches this: the local branch's `@{upstream}` is gone,
so `git rev-list @{upstream}..HEAD` fails loudly and the worktree is
kept rather than removed. Closed-but-not-merged PRs are excluded by
`--state merged`, and a force-pushed branch is handled because the gate
requires the branch to be gone, not the local SHA to match the remote
tip.

### Remote branches

List every branch on `origin` except `$DEFAULT_BRANCH`:

```bash
git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin/ \
  | grep -v -x -e "$DEFAULT_BRANCH" -e HEAD
```

A branch is **clean** when all three hold, and its action is
`git push origin --delete <branch>`:

- `/github-prs:pr-list --head <branch> --state merged` returns a
  non-empty array;
- `/github-prs:pr-list --head <branch> --state open` returns `[]`, so
  no PR still builds on it;
- its tip is already on the default branch, so deleting it drops no
  commit:

  ```bash
  git rev-list --count "origin/<branch>" ^"origin/$DEFAULT_BRANCH"
  ```

  Act on the count only when the command exits 0, and only a count of
  `0` passes. A non-zero exit means the check could not be made — keep
  the branch, never read the failure as an empty count.

Every other remote branch is **keep**, with the condition it failed.

### Subagent worktrees

List the worktrees that are **direct** children of
`.claude/worktrees/` and are either on a `worktree-*` branch or at a
detached HEAD. An `sdlc` teammate checks out the PR's issue branch in
its worktree and, at the end of its run, releases that claim by
detaching HEAD and deleting the issue branch, so the worktree it leaves
is on no branch at all and a `worktree-*` match alone never reaches it.
A nested worktree is graded under "Nested worktrees", detached or not.

A worktree is **clean** when both checks pass:

- **Nothing uncommitted** — `git -C <path> status --porcelain` is empty.
- **Fully pushed.** On a branch, `git -C <path> rev-list
  @{upstream}..HEAD` is empty; compare with the branch's own upstream,
  never the default branch, since feature and worktree branches are
  expected to diverge from it. A detached HEAD has no upstream, so it
  counts as pushed only when its commit is reachable from some
  remote-tracking ref:

  ```bash
  # empty output = HEAD is reachable from a remote ref
  git -C <path> rev-list HEAD --not --remotes
  ```

  Read either `rev-list`'s exit status as "Orphan `worktree-*` refs"
  below directs for its own: a failure is "cannot verify", never an
  empty list.

Its action is `git worktree remove <path>` — never `--force` — then,
on a branch, `git branch -d <branch>`. A detached worktree has no
branch, so its removal ends at `git worktree remove`.

Read the lock state from `git worktree list --porcelain` as well. A
worktree locked with the standard harness reason
`claude agent agent-<hash> (pid NNNN)` whose PID is no longer alive
(`kill -0 <pid>` fails) holds a stale end-state lock from a returned
or crashed subagent: its action adds `git worktree unlock <path>`
before the removal. A lock of any other shape, or one whose PID is
alive — the subagent may be mid-run — makes the worktree **keep**.

Every worktree that fails a check is **keep**, with the check it
failed.

### Orphan `worktree-*` refs

List every local `worktree-*` branch that is not checked out in any
worktree under `.claude/worktrees/`; the harness can leak these after
their worktree is gone.

- **The branch has an upstream that still exists on origin**
  (`git rev-parse --abbrev-ref --symbolic-full-name <branch>@{upstream}`
  succeeds and `git ls-remote --exit-code origin` finds it): it is
  **clean** when `git rev-list <branch>@{upstream}..<branch>` is empty,
  with the action `git branch -d`, and **keep** otherwise — it holds
  unpushed work.
- **No upstream, or the upstream is gone** — the harness creates these
  refs and never pushes them: check reachability from the default
  branch instead.

  ```bash
  if count=$(git rev-list "<branch>" ^"$DEFAULT_BRANCH" --count); then
    # rev-list succeeded; $count is trustworthy
    :
  else
    # rev-list errored (bad revision, etc.) — cannot verify
    count=""
  fi
  ```

  **Treat the `rev-list` exit status as authoritative.** A non-zero
  exit is "cannot verify" and makes the ref **keep**; it must never
  read as an empty count that looks like zero. A count of `0` means
  every commit on the ref is already on the default branch, so the
  ref is **clean**, with the action `git branch -D` — `-d` refuses a
  ref with no upstream as "not fully merged" even when its commits are
  reachable. A non-zero count is **keep**: the ref has history the
  default branch lacks.

### Nested worktrees

Every worktree under `.claude/worktrees/*/.claude/worktrees/` is
**keep**, with the note that a nested worktree indicates
[Anthropic issue #47548](https://github.com/anthropics/claude-code/issues/47548)
(`isolation: worktree` spawned from inside a worktree) and needs human
inspection. Removing one risks data loss, so this skill never offers
to.

### `.claude/tmp/` and the scratchpads

Every top-level entry under the primary clone's `.claude/tmp/` is
**ask**. A task's scratch stays in place after a failure precisely so
it can be examined, so nothing on disk says whether it is still
wanted. Scratch inside a worktree is not listed separately: it goes
with its worktree.

The harness's per-session scratchpads for this repo are the
`<session-id>/scratchpad/` directories beside this session's own —
the scratchpad path the harness gave this session, two levels up, is
the directory that holds one per session. Take that path from your
context verbatim; never hand-build a lookalike. List the directory:

- **This session's own scratchpad** is **keep** — it is in use, and it
  holds anything this session hands off, such as the agent-memory
  inbox a curator has yet to read.
- **Every other session's scratchpad** is **ask**. A scratchpad can
  belong to a session that is still running, and nothing on disk says
  which.

The action for an approved **ask** item is `rm -rf <path>`.

## Report the index

One block per category, in the order above, each item on its own line
with its verdict and its action or reason:

```text
## Interim work

Default branch: <DEFAULT_BRANCH>

### Local branches
  clean  <branch>               (merged PR #<N>, remote gone) → remove worktree <path>; git branch -D
  keep   <branch>               (<gate half it failed>)

### Remote branches
  clean  origin/<branch>        (merged PR #<N>, no open PR, on <DEFAULT_BRANCH>) → git push origin --delete
  keep   origin/<branch>        (<condition it failed>)

### Subagent worktrees
  clean  <path>                 (<worktree-* branch | detached HEAD>, clean and pushed[, stale lock]) → <actions>
  keep   <path>                 (<check it failed>)

### Orphan worktree-* refs
  clean  <branch>               (<upstream-empty | reachable from default branch>) → git branch -<d|D>
  keep   <branch>               (<reason>)

### Nested worktrees
  keep   <path>                 (nested worktree — anthropics/claude-code#47548)

### .claude/tmp/ and scratchpads
  ask    <path>                 (<size>, modified <date>; <top-level entries>)
  keep   <path>                 (this session's scratchpad)
```

A category with no item reads `(none)`. Under `--index-only`, stop
here.

## Ask

Ask the human which items to remove, in prose, and end the turn at the
question. Name the exact actions: offer every **clean** item as a set,
and every **ask** item by its path. A **keep** item is never offered.

Remove only what the answer names. An answer that approves "the clean
items" covers every **clean** item and no **ask** item; an **ask** item
is removed only when the answer names it. Silence, or an answer that
names nothing, removes nothing.

## Remove

Work through the approved items in this order: subagent worktrees,
local branches, orphan `worktree-*` refs, remote branches, then
`.claude/tmp/` entries and scratchpads. Run each item's gate again
immediately before its action — a subagent may have started, committed,
or pushed since the index was taken — and keep, with the reason, any
item whose gate no longer passes. Never pass `--force` to
`git worktree remove`, and never unlock a lock other than the stale
harness lock the index named; discarding uncommitted or unpushed work
is the human's to approve item by item, outside this skill.

An action that fails is reported with its error quoted, and the rest
carry on.

## Finish

1. Run `git worktree prune` to drop stale worktree registrations.
2. Run `git fetch --all --prune` again.
3. Pull `$DEFAULT_BRANCH` forward. If `git worktree list` shows it
   checked out in another worktree, update that checkout in place with
   `git -C <that-path> pull --ff-only` — git refuses to switch to a
   branch another worktree has claimed. Otherwise `git switch
   "$DEFAULT_BRANCH"` and `git pull --ff-only`.

Close the report with what was removed per category, what was kept at
removal time and why, any action that failed, and whether the default
branch was updated in place.
