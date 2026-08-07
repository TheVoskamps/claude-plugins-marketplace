---
name: baseline-suite-totals-via-git-archive
description: To verify a PR's "+N new assertions/tests" delta claim, extract origin/main's whole payload with git archive into repo .claude/tmp and run the suite there — self-contained suites run fine from the extract, and totals-at-both-revisions settles the delta in two runs.
metadata:
  type: reference
---

The claude-vm payload test suites (`config-test.sh`,
`podman-mkosi-test.sh`) print a final `N passed, M failed` total, and PR
bodies claim deltas ("+7 new assertions"). The branch total alone cannot
verify a delta — you need main's baseline, and switching the review
worktree back to main mid-review is churn.

Recipe:

```bash
mkdir -p .claude/tmp/main-payload
git archive origin/main plugins/claude-vm/payload | tar -x -C .claude/tmp/main-payload
bash .claude/tmp/main-payload/plugins/claude-vm/payload/test/config-test.sh | tail -2
```

The suites resolve `lib/` relative to their own location, so the extract
is fully runnable with no repo checkout. Comparing the totals at both
revisions settles the delta, and catches an off-by-one tally in a PR
body that the branch total alone reads as fine.

**A wrong baseline is not always a stale-fork-point story.** On PR #231
the body said "grew from 289 to 350" while main's suite reported 294 —
and `git merge-base origin/main HEAD` was main's own tip, so no rebase
explained it. Check the other plausible metric before narrating a cause:
`grep -c 'assert_eq ' <suite>` gave 325 there, so neither metric yielded
the claimed number and it was simply wrong. Run merge-base and both
counts, then file it as a Low against the PR body only — the tree is
fine.

Related: [[baseline-lint-before-flagging]] (same baseline-first
principle, lint scope).
