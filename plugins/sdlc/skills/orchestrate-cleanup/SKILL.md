---
name: orchestrate-cleanup
description: Delete the review state of this repo's — or a named repository's — merged and closed PRs, keep it for open or unresolvable ones, then index the interim work runs leave behind — scratch, scratchpads, worktrees, branches — and remove what the human approves. --dry-run reports the verdicts and the index, and deletes no review state and no indexed item.
---

# Orchestrate Cleanup

Every review round leaves its evidence under the repo's `sdlc` state
directory, one `pr<N>/` per PR, and nothing removes it during a run —
a stalled or voided round is diagnosed from those files alone. This
skill is the pass that removes it once the human decides a PR's
evidence is no longer wanted. It runs in the main session, when
the human invokes it; `/sdlc:orchestrate` never invokes it, so a run's
evidence always outlives the run.

This skill lists, moves and deletes in the state directory only through
the `sdlc-agent-result-persist` CLI's `--mode list`, `--mode repos` and
`--mode delete`, whose contract is `sdlc:agent-result-persist-interface`.
Never list, read or delete there yourself — no `ls`, `find` or `rm`,
and no file-tool read or glob of the directory — even to double-check
what the CLI reported.

## Invocation

```text
/sdlc:orchestrate-cleanup [<repository>] [--dry-run]
```

- `<repository>` (optional) — the repository whose review state to
  clean up, as `((<host>/)<owner>/)<repo>` or
  `https://<host>/<owner>/<repo>`. Omitted, it is this repository.
  Pass it to the CLI as you were given it, or not at all: the CLI
  resolves it, and you resolve nothing.
- `--dry-run` (optional).

Any other token in `$ARGUMENTS`, or a second repository, is not one
this skill knows: say so and stop, rather than guessing what was
meant.

**`--dry-run` deletes no review state and no indexed item.** It
reports the same per-directory verdicts without calling
`--mode delete`, asks no host and moves no other repository's state in
step 4, and runs the interim-work pass with `--index-only`, so that
pass reports its index and removes none of it. Two writes are left:
the CLI moving the cleaned-up repository's own state out of the layout
that predates the host segment, which any call of it does first, and
the interim-work pass's opening `git fetch --all --prune`, which deletes the
remote-tracking refs of branches already gone from `origin`.

## Process

1. **List the PR directories**, passing `<repository>` only when you
   were given one:

   ```bash
   sdlc-agent-result-persist --mode list [<repository>]
   ```

   Each line is one PR, as its `<host>/<owner>/<repo>#<N>` reference —
   the `<PR>` the steps below pass on as it stands. A non-zero exit is
   a repository the CLI could not resolve or name: quote its message
   and stop, since there is no state directory to clean up. Empty
   output means no review state is held for the repository: report
   that, and go on to step 4. This call is also what moves the
   repository's own state out of the layout that predates the host
   segment, so step 4 never asks for its host.

2. **Give each PR a verdict** from GitHub:

   ```text
   /github-prs:pr-view <PR> --json state --jq .state
   ```

   | Answer | Verdict |
   | --- | --- |
   | `MERGED` | delete — merged |
   | `CLOSED` | delete — closed unmerged |
   | `OPEN` | keep — in flight |
   | anything else, or the call fails | keep — unresolved, with the error or the answer quoted |

   An unresolved PR is kept because a directory that cannot be tied to
   a finished PR might still be one a run is using.

3. **Delete each `delete` verdict's directory** — skipped entirely
   under `--dry-run`:

   ```bash
   sdlc-agent-result-persist --mode delete --pr <PR>
   ```

   A call that exits non-zero leaves that directory's outcome as
   "delete failed", with the CLI's message quoted; carry on with the
   rest.

4. **Identify every repository's state directory.**

   ```bash
   sdlc-agent-result-persist --mode repos
   ```

   Each line is `<kind> <repository> <directory>`. The CLI reads the
   repository from the directory's `repo.yml`, and so do you: never
   derive it from the directory's path.

   - **`repo`** — the file names the directory's own path. Nothing to
     do.
   - **`mismatch`** — the file names another repository than the path
     does. The file wins: the directory holds that repository's state.
     Report the mismatch, both names quoted, and change nothing.
   - **`old`** — a directory of the old layout, from before the host
     was part of the path, read as `<owner>/<repo>` by position. Ask
     the human which host that repository is on, offering
     `github.com`, one question per directory. On an answer, run

     ```bash
     sdlc-agent-result-persist --mode list <host>/<owner>/<repo>
     ```

     which moves the directory to `<host>/<owner>/<repo>/` and writes
     its `repo.yml`; it deletes none of that repository's PRs. Under
     `--dry-run`, report each one as old-layout and ask nothing.

5. **Sweep the interim work.** Invoke, with no arguments — or with
   `--index-only` under `--dry-run`:

   ```text
   /sdlc:cleanup-interim-work
   ```

   It runs after the state-directory pass, and owns every decision
   about scratch, scratchpads, worktrees and branches, including the
   question it asks the human before it removes anything; relay what it
   reports in its own words.

## Report

One line per directory, in the order `--mode list` printed them, with
its reason:

```text
pr<N>/  deleted            (merged)
pr<N>/  deleted            (closed unmerged)
pr<N>/  kept               (in flight: open)
pr<N>/  kept               (unresolved: <quoted error or answer>)
pr<N>/  delete failed      (<quoted CLI message>)
```

Under `--dry-run`, `deleted` reads `would delete`. Then one line per
step-4 directory that is not `repo`:

```text
<directory>/  mismatch     (repo.yml names <repository>)
<directory>/  moved        (to <host>/<owner>/<repo>/)
<directory>/  old layout   (host not given)
<directory>/  move failed  (<quoted CLI message>)
```

The report closes with the interim-work pass's own report — its index
alone under `--dry-run`.
