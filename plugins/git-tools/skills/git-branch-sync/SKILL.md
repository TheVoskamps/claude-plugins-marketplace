---
name: git-branch-sync
description: Run the fixed git steps around work on an existing branch — check it out fast-forward only, rebase it onto origin/<base>, finish or abort a rebase stopped on conflicts, push it (refusing a branch behind its remote, with a lease exactly when the remote tip is not an ancestor of HEAD) and verify the push landed, and release the local branch at the end of a run. Resolving a conflict stays with the caller.
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
  of `origin/<branch>` is checked out as it is. A local branch that has
  diverged from `origin/<branch>` exits 4 with nothing checked out and
  nothing reset.
- **`rebase <base>`** — fetches `origin` and rebases the current branch
  onto `origin/<base>`. On a stop, exits 3 with the conflicted paths on
  stdout.
- **`continue <path>…`** — stages the given paths, then commits the
  stopped commit under `REBASE_HEAD`'s message and author and lets the
  rebase continue, exiting as `rebase` does on the next stop. When the
  staged resolution leaves the stopped commit with no change, the
  commit is skipped instead, as a rebase drops a commit that becomes
  empty. A conflicted path still unresolved once the given paths are
  staged exits 5, before anything is committed.
- **`abort`** — aborts the rebase in progress, leaving the branch
  checked out at its pre-rebase tip.
- **`push`** — fetches `origin`. When HEAD is a strict ancestor of
  `origin/<branch>` — the local branch is behind the remote — exits 11
  and pushes nothing. Otherwise pushes the current branch to
  `origin/<branch>`: with `--force-with-lease=<branch>:<the fetched
  remote tip>` when `origin/<branch>` exists and is not an ancestor of
  HEAD, and a plain push otherwise, which succeeds when there is nothing
  new.
  Ancestry alone decides; nothing records whether a rebase ran. It then
  verifies that `origin/<branch>`, read from the remote, equals local
  HEAD and that the working tree is clean. It never uses `--force` or
  `--mirror`.
- **`release <branch>`** — detaches HEAD and deletes the local
  `<branch>`, releasing the claim that otherwise keeps every other
  worktree from checking the branch out. It deletes whatever the branch
  holds: run it only once the branch's work is pushed, or when there was
  none.

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
| 3 | `rebase` or `continue`: the rebase stopped on conflicts. Stdout is the conflicted paths, one per line, and nothing else | `the rebase stopped on conflicts in the paths on stdout` |
| 4 | `checkout`: the local branch has diverged from `origin/<branch>` | `local <branch> (<sha>) has diverged from origin/<branch> (<sha>); nothing was reset` |
| 5 | `continue`: a conflicted path remains unresolved after staging the given paths | the unresolved paths, one per line, then `a conflicted path is still unresolved: the paths above` |
| 6 | `continue` or `abort`: no rebase is in progress | `no rebase is in progress` |
| 7 | `rebase` or `push`: no branch is checked out | `no branch is checked out (HEAD is detached)` |
| 8 | `push`: rejected because `origin/<branch>` moved since the fetch — a lease or fast-forward failure | `the push was rejected: origin/<branch> moved since the fetch` |
| 9 | `push`: verification failed, local HEAD differs from the remote tip | `local HEAD <sha> differs from origin/<branch> <sha>` |
| 10 | `push`: verification failed, the working tree is dirty | `the working tree is dirty after the push` |
| 11 | `push`: the local branch is behind `origin/<branch>` — HEAD is a strict ancestor of the remote tip; nothing was pushed | `local <branch> (<sha>) is behind origin/<branch> (<sha>); nothing was pushed` |

On 3 the rebase is still in progress: resolve the paths and run
`continue`, or run `abort`. On 5 the given paths stay staged and the
rebase stays in progress. On 8, 9, 10 and 11 the local commits are
intact: nothing the push did removes them.
