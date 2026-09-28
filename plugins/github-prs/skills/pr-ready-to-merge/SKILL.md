---
name: pr-ready-to-merge
description: Report an open GitHub pull request's merge readiness — its `mergeable` and `mergeStateStatus` values, with `reviewDecision` and `statusCheckRollup` alongside so a caller can tell what a `BLOCKED` is blocked on — retrying on a fixed schedule while GitHub is still computing the merge commit. Read-only; refuses a PR that is not open.
---

# PR Ready To Merge

Report one pull request's merge readiness and nothing else. The skill
reads `mergeable` and `mergeStateStatus` off the PR, and `reviewDecision`
and `statusCheckRollup` alongside them, and reports the state it found;
it writes nothing, flips nothing, and remedies nothing. The two extra
fields are there because `mergeStateStatus: BLOCKED` names no cause —
a missing required review, a failing required check and a required
check still running all report the same word — and a caller deciding
what to do with a `BLOCKED` needs to know which it is.
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

Run the bundled script, spelled as a bare name:

```bash
pr-ready-to-merge <pr-number>
```

**A PR that is not open is refused.** GitHub stops computing merge
state once a PR closes: a merged or closed PR reports
`mergeable: UNKNOWN` and `mergeStateStatus: UNKNOWN` permanently.
Retrying against one would burn the whole schedule below and then
report a merge-readiness failure that means nothing, so the script
treats a non-open PR as an input error, with no retry.

**`mergeable: UNKNOWN` on an open PR is retried.** It means GitHub has
not finished computing the merge commit; it is neither a pass nor a
failure. The script makes at most **three attempts**: the immediate
read, a second after waiting **10 s**, and a third after waiting a
further **30 s**, announcing every wait on stdout before taking it so
the human can tell a wait from a hang:

```text
PR #<N>: merge state still computing, attempt 2 of 3 — waiting 10 s.
```

It stops as soon as `mergeable` is anything other than `UNKNOWN`. The
three-attempt, 10 s / 30 s schedule is a declared starting bound, not a
measured one: it is revised in the script if practice shows it is
wrong.

## Output and exit status

- **Exit 0** — the merge state resolved. After any wait announcements,
  stdout is one block:

  ```text
  PR #<N>: mergeable <MERGEABLE|CONFLICTING>, mergeStateStatus <STATE> — <meaning>
  reviewDecision: <REVIEW_REQUIRED|APPROVED|CHANGES_REQUESTED|(none)>
  checks running: <none, or one indented line per entry>
  checks not green: <none, or one indented line per entry>
  ```

  Report it back as it stands.
- **Exit 1** — either the PR is not open, and stderr says so and names
  the state it is in, or the third read still returned `mergeable: UNKNOWN`,
  and stdout is the block above reporting `UNKNOWN` — never a guessed
  state — while stderr says the state is still uncomputed. Report
  either as a failure.
- **Exit 2** — a usage error; nothing was read.
- **Exit 3** — the `gh` call failed, and gh's own error is on stderr
  above the script's line. Surface it verbatim.

`reviewDecision` is `(none)` when the base's rules require no review.
Each check line names an entry of `statusCheckRollup` with the values it
carries. That list mixes two shapes: a `CheckRun` carries `status` and
`conclusion`, a `StatusContext` carries `state` and names itself in
`context`. An entry is **running** when it is a `CheckRun` whose
`status` is anything but `COMPLETED`, or a `StatusContext` whose `state`
is `PENDING` or `EXPECTED` — it has not reported yet, so it is neither
a pass nor a failure, and a caller that treated it as a failure would
stop on a repo whose checks are merely slow. An entry is **green** when
it is a `CheckRun` with `status: COMPLETED` and a `conclusion` of
`SUCCESS`, `SKIPPED` or `NEUTRAL`, or a `StatusContext` with
`state: SUCCESS`, and green entries are not listed. Every other entry
is **not green**. The rollup does not say which entries are required,
so each list is every entry in its class, required or not.

The meaning column is GitHub's, and it is all this skill says: what a
caller does about a given state — a `BLOCKED` included, whichever of
the review and the checks accounts for it — is the caller's own rule.

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

A state this table does not name is reported verbatim with no meaning
attached, rather than mapped onto the nearest row.
