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

Related: [[baseline-lint-before-flagging]] (same baseline-first
principle, lint scope).
