---
name: pr-ready-to-merge
description: Report an open GitHub pull request's merge readiness — its `mergeable` and `mergeStateStatus` values — retrying on a fixed schedule while GitHub is still computing the merge commit. Read-only; refuses a PR that is not open.
---

# PR Ready To Merge

Report one pull request's merge readiness and nothing else. The skill
reads `mergeable` and `mergeStateStatus` off the PR and reports the
state it found; it writes nothing, flips nothing, and remedies nothing.
"Ready for review" is a draft flag and says nothing about whether the
branch is current with its base, merges cleanly, or passes its required
checks — this skill is what answers those questions, for any caller
that has to decide whether a PR can move forward.

## Invocation

```text
/pr-ready-to-merge <pr-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.

## Execution

1. **Read the PR's state and merge fields:**

   ```bash
   gh pr view <N> --json number,state,mergeable,mergeStateStatus
   ```

2. **Refuse a PR that is not open.** If `state` is anything other than
   `OPEN`, abort with:

   ```text
   PR #<N> is <state>, not open. Merge readiness is only computed for
   an open PR.
   ```

   GitHub stops computing merge state once a PR closes: a merged or
   closed PR reports `mergeable: UNKNOWN` and
   `mergeStateStatus: UNKNOWN` permanently. Retrying against one would
   burn the whole schedule below and then report a merge-readiness
   failure that means nothing, so a non-open PR is an input error and
   is reported as one, with no retry.

3. **Retry while the merge commit is still being computed.**
   `mergeable: UNKNOWN` on an open PR means GitHub has not finished
   computing the merge commit; it is neither a pass nor a failure. Run
   at most **three attempts**: the immediate read in step 1, a second
   after waiting **10 s**, and a third after waiting a further
   **30 s**. Announce every wait before taking it, so the human can
   tell a wait from a hang:

   ```text
   PR #<N>: merge state still computing, attempt 2 of 3 — waiting 10 s.
   ```

   ```bash
   sleep 10
   gh pr view <N> --json number,state,mergeable,mergeStateStatus
   ```

   Leave the loop as soon as `mergeable` is anything other than
   `UNKNOWN`. If the third read still returns `UNKNOWN`, **fail**
   reporting `UNKNOWN` — never a guessed state.

   The three-attempt, 10 s / 30 s schedule is a declared starting
   bound, not a measured one: it is revised here if practice shows it
   is wrong.

4. **Report back**, in one block, the two values and what the
   `mergeStateStatus` means on GitHub's side:

   ```text
   PR #<N>: mergeable <MERGEABLE|CONFLICTING|UNKNOWN>,
   mergeStateStatus <STATE> — <meaning>
   ```

   The meaning column is GitHub's, and it is all this skill says: what
   a caller does about a given state is the caller's own rule.

   | `mergeStateStatus` | Meaning |
   | -------------------- | --------- |
   | `CLEAN` | mergeable |
   | `UNSTABLE` | mergeable; non-required checks failing |
   | `HAS_HOOKS` | mergeable; a pre-receive hook is pending |
   | `BEHIND` | the branch is behind its base |
   | `DIRTY` | the branch has merge conflicts with its base |
   | `BLOCKED` | required checks or reviews are not satisfied |
   | `DRAFT` | the PR is a draft |
   | `UNKNOWN` | still computing after the whole retry schedule |

   A state this table does not name is reported verbatim with no
   meaning attached, rather than mapped onto the nearest row.
