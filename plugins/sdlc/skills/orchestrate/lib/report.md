# Report

The post-merge tail that runs once after the last PR's monitor loop
ends, and the summary that closes the run.

## The post-merge tail, once per run

After the last PR's monitor loop ends, and before you write the
summary, invoke the whole-repo sweep exactly once, with no scoping
added — its own skip-and-report conditions are the scope:

```text
/git-tools:git-cleanup-branches-and-worktrees
```

Report what it reports, in its own words, and add nothing — no count of
your own, no list of what you expected it to find.

Then bring the primary clone back to the default branch, current with
the remote and with its stale tracking refs gone:

```bash
git checkout <default-branch>
git pull --ff-only
git remote prune origin
```

Then write the summary.

## Summary

Once all waves are complete, all review loops have settled, and the
post-merge tail has run, deliver a summary:

```text
## Issue Fix Summary

### Merged
| Batch | Issues | PR | Review Verdict | Review Rounds | Style-fix Rounds | Readiness Remedies | Doc Changes |
|-------|--------|----|-----------------|---------------|------------------|--------------------|-------------|
| A | <link-prefix>101 | <PR1> | Approved | 1 | 0 | 0 | README.md — documents the new flag |
| B | <link-prefix>106, <link-prefix>104 | <PR2> | Approved (both) | 2 (fixed high on 104) | 1 | 1 (BEHIND, rebased) | docs/api.md — records the changed endpoint |

### Needs Your Attention
| Issue | PR | Problem |
|-------|----|---------|
| <link-prefix>102  | <PR3> | Critical finding persists at review-round cap |
| <link-prefix>105  | —     | Dropped from batch C — needs a design decision its issue doesn't answer; not on <PR3>, still In Progress |

### Sequential Queue (not yet started)
| Batch | Issues | Waiting On | Reason |
|-------|--------|-----------|--------|
| D | <link-prefix>103 | Batch C to merge | same file conflict |

Every PR above merged while this run watched it; this run merged
nothing itself.

To start the sequential queue, reply: "continue with <link-prefix>103"
```

A **Needs Your Attention** row is something the human must act on to
merge, unblock, or trust a PR of this run. An observation the loop
already had a chance to act on does not qualify — the loop was where
it was cheap to settle, and holding it to the end spends the human's
turn on work that was yours. Round-cap findings, escalations, a
discrepancy your re-read could not settle, a PR closed without
merging, and a monitor loop the human declined to keep waiting on
qualify as they stand; the last two name which it was and the state
the last poll found, so the human reading the summary knows whether
the PR is gone or still open, ready, and unmerged.

Every cell in those tables is a claim to the human, and most arrive
from a teammate's report — the `Doc Changes` list is `docs-writer`'s,
and the `Review Verdict` and the severity detail behind it are the
reviewer's — while `Review Rounds`, `Style-fix Rounds` and
`Readiness Remedies` are your own counts, the last one naming each
state `pr-merge-readiness` reported and the remedy it drove. Fill them as
the claims they are: verify the PR column and its merged state
against the live PR, since the human reads the table as
the record of what landed; say what a finding's provenance was when it
is not the review's own — a defect you observed yourself is never "the
review found" it, while one the human raised and you relayed as an
adjustment comment is the review's finding by the round that minted
and broke its theorem; and give a discrepancy your re-read could not
settle its own **Needs Your Attention** row, naming both versions.
