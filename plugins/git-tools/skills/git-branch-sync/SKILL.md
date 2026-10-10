---
name: git-branch-sync
description: Run the fixed git steps around work on an existing branch — check it out fast-forward only and record the remote tip it saw, rebase it onto origin/<base>, finish or abort a rebase stopped on conflicts, push it against that recorded tip (refusing a branch behind it, with a lease exactly when it is not an ancestor of HEAD) and verify the push landed, and release the local branch and its record at the end of a run. Resolving a conflict stays with the caller.
---

# Git Branch Sync

The git steps an agent runs around its own work on a branch that
already exists on `origin`, as one script with one exit-status contract
the caller branches on. What the script does not do is resolve a
conflict: that is judgment, and stays with the caller, which edits the
conflicted files and hands the resolved paths back to `continue`.

## Invocation

```text
/git-tools:git-branch-sync <subcommand> [<argument>…]
```

Run the bundled script, spelled as a bare name, from inside the
checkout:

```bash
git-branch-sync checkout <branch>
git-branch-sync rebase <base>
git-branch-sync continue <path>…
git-branch-sync abort
git-branch-sync push
git-branch-sync release <branch>
```

No subcommand ever opens an editor.

## Subcommands

- **`checkout <branch>`** — fetches `origin`, checks `<branch>` out,
  and fast-forwards it to `origin/<branch>`. With no local `<branch>`,
  creates it tracking `origin/<branch>`. A local branch already ahead
  of `origin/<branch>` is checked out as it is. It then records the
  `origin/<branch>` tip it saw in the ref
  `refs/git-branch-sync/<branch>`, the recorded tip `push` decides
  against.
- **`rebase <base>`** — fetches `origin` and rebases the current branch
  onto `origin/<base>`. It leaves the recorded tip alone.
- **`continue <path>…`** — stages the given paths, then commits the
  stopped commit under `REBASE_HEAD`'s message and author and lets the
  rebase continue, exiting as `rebase` does on the next stop. Each path
  is taken literally, never as a pattern, and relative to the top level
  of the working tree from whatever directory `continue` runs in, as
  `rebase` prints it, so a path `rebase` printed can be passed back as
  it stands. When the staged resolution leaves
  the stopped commit with no change, the commit is skipped instead, as
  a rebase drops a commit that becomes empty.
- **`abort`** — aborts the rebase in progress, leaving the branch
  checked out at its pre-rebase tip.
- **`push`** — decides against the tip `checkout` recorded for the
  current branch, never a tip it fetches itself, so a commit another
  writer pushed after the checkout is refused rather than replaced.
  Unless it refuses as exits 11 and 12 state, it pushes the current
  branch to `origin/<branch>`: with `--force-with-lease=<branch>:<the
  recorded tip>` when the recorded tip is not an ancestor of HEAD, and a
  plain push otherwise, which succeeds when there is nothing new.
  Ancestry alone decides; nothing records whether a rebase ran. After a
  successful push it records the pushed tip, then fetches `origin` and
  verifies that `origin/<branch>` equals local HEAD and that the working
  tree is clean. It never uses `--force` or `--mirror`, and never moves
  the local branch, so no exit of `push` removes a local commit.
- **`release <branch>`** — detaches HEAD, deletes the local `<branch>`
  and deletes its recorded tip, if any, releasing the claim that
  otherwise keeps every other worktree from checking the branch out. It
  deletes whatever the branch holds: run it only once the branch's work
  is pushed, or when there was none.

## Exit status

Each status below is produced by exactly the condition it names, with
the stderr line shown, prefixed with the program's name and a colon.
Stdout is empty
on every status but 3.

| Exit | Condition | Stderr |
| --- | --- | --- |
| 0 | success | — |
| 1 | a failure the script did not classify, such as a failed fetch, no `origin/<branch>` on `checkout` or `origin/<base>` on `rebase`, a dirty tree blocking a checkout, or a push the remote refused for its own reason; git's own status is never passed through | names the failed command or condition |
| 2 | usage error: an unknown subcommand, or a missing or extra argument; nothing was run | `` `<subcommand>` is not a subcommand git-branch-sync takes. ``, `` `<subcommand>` takes <n> argument(s), not <m>. ``, `` `continue` needs at least one resolved path. `` or `No subcommand was supplied.`, then the synopsis |
| 3 | `rebase` or `continue`: the rebase stopped on conflicts. Stdout is the conflicted paths, one per line, verbatim and unquoted, and nothing else | `the rebase stopped on conflicts in the paths on stdout` |
| 4 | `checkout`: the local branch has diverged from `origin/<branch>`; nothing was checked out, reset or recorded | `local <branch> (<sha>) has diverged from origin/<branch> (<sha>); nothing was reset` |
| 5 | `continue`: a conflicted path remains unresolved after staging the given paths; nothing was committed | the unresolved paths, one per line, then `a conflicted path is still unresolved: the paths above` |
| 6 | `continue` or `abort`: no rebase is in progress | `no rebase is in progress` |
| 7 | `rebase` or `push`: no branch is checked out | `no branch is checked out (HEAD is detached)` |
| 8 | `push`: rejected because `origin/<branch>` moved past the recorded tip — a lease or fast-forward failure | `the push was rejected: origin/<branch> moved past the recorded tip (<sha>)` |
| 9 | `push`: verification failed, local HEAD differs from the remote tip | `local HEAD <sha> differs from origin/<branch> <sha>` |
| 10 | `push`: verification failed, the working tree is dirty | `the working tree is dirty after the push` |
| 11 | `push`: the local branch is behind the recorded tip — HEAD is a strict ancestor of it; nothing was pushed | `local <branch> (<sha>) is behind its recorded tip (<sha>); nothing was pushed` |
| 12 | `push`: no tip is recorded for the branch — `checkout` did not run in this clone; nothing was pushed | `` no tip is recorded for <branch>: run `checkout <branch>` first; nothing was pushed `` |

On 3 the rebase is still in progress: resolve the paths and run
`continue`, or run `abort`. On 5 the given paths stay staged and the
rebase stays in progress.
