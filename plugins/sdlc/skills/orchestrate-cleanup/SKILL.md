---
name: orchestrate-cleanup
description: Delete the review state of this repo's merged and closed PRs, keep it for open or unresolvable ones, then sweep merged branches and stale worktrees. --dry-run reports the verdicts and deletes nothing.
---

# Orchestrate Cleanup

Every review round leaves its evidence under the repo's `sdlc` state
directory, one `pr<N>/` per PR, and nothing removes it during a run —
a stalled or voided round is diagnosed from those files alone. This
skill is the pass that removes it once the human decides a PR's
evidence is no longer wanted. It runs in the main session, when
the human invokes it; `/sdlc:orchestrate` never invokes it, so a run's
evidence always outlives the run.

This skill lists and deletes in the state directory only through the
`sdlc-agent-result-persist` CLI's `--mode list` and `--mode delete`,
whose contract is `sdlc:agent-result-persist-interface`.
Never list, read or delete there yourself — no `ls`, `find` or `rm`,
and no file-tool read or glob of the directory — even to double-check
what the CLI reported.

## Invocation

```text
/sdlc:orchestrate-cleanup [--dry-run]
```

`--dry-run` is the only argument. Any other token in `$ARGUMENTS` is
not one this skill knows: say so and stop, rather than guessing what
was meant.

**`--dry-run` deletes nothing.** It reports the same per-directory
verdicts without calling `--mode delete`, and it skips the branch and
worktree pass, because `/git-tools:git-cleanup-branches-and-worktrees`
has no dry-run form.

## Process

1. **Resolve the repo.**

   ```bash
   gh repo view --json owner,name --jq '.owner.login + " " + .name'
   ```

   The two words are `<owner>` and `<repo>`. If the call fails, quote
   its error and stop: without them there is no state directory to
   name.

2. **List the PR directories.**

   ```bash
   sdlc-agent-result-persist --mode list --owner <owner> --repo <repo>
   ```

   Each line is one PR number. Empty output means no review state is
   held for this repo: report that, and go on to step 5.

3. **Give each PR a verdict** from GitHub:

   ```bash
   gh pr view <N> --json state --jq .state
   ```

   | Answer | Verdict |
   | --- | --- |
   | `MERGED` | delete — merged |
   | `CLOSED` | delete — closed unmerged |
   | `OPEN` | keep — in flight |
   | anything else, or the call fails | keep — unresolved, with the error or the answer quoted |

   An unresolved PR is kept because a directory that cannot be tied to
   a finished PR might still be one a run is using.

4. **Delete each `delete` verdict's directory** — skipped entirely
   under `--dry-run`:

   ```bash
   sdlc-agent-result-persist --mode delete --owner <owner> --repo <repo> --pr <N>
   ```

   A call that exits non-zero leaves that directory's outcome as
   "delete failed", with the CLI's message quoted; carry on with the
   rest.

5. **Sweep branches and worktrees** — skipped under `--dry-run`.
   Invoke, with no arguments:

   ```text
   /git-tools:git-cleanup-branches-and-worktrees
   ```

   It runs after the state-directory pass, and owns every branch and
   worktree decision; relay what it reports in its own words.

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

Under `--dry-run`, `deleted` reads `would delete`, and the report
closes by saying that the branch and worktree pass was skipped because
`/git-tools:git-cleanup-branches-and-worktrees` has no dry-run form.
Otherwise it closes with that skill's own report.
