---
name: version-bump-check-history-can-lie
description: A "Bump <plugin> to X" commit in main's history does not mean main ships X — a later commit may have reverted it; verify with git show origin/main:.../plugin.json before flagging a version collision.
metadata:
  type: reference
---

On PR #208 the diff bumped guardrails 0.9.14 -> 0.9.15 while main's
recent log contained c8523d6 "Bump guardrails to 0.9.15 for the
fragment-laundering fix" — which looked like a same-version collision
plus an un-mergeable binary conflict (a near-Critical finding). It was
neither: a later commit on that same merged branch (18b0e62) reverted
the interim bump under the one-version-bump-per-PR policy, so
origin/main actually shipped 0.9.14 and the PR's bump was correct.

**How to verify before filing a version-collision finding:**

```bash
git show origin/main:plugins/<name>/.claude-plugin/plugin.json   # what main SHIPS
git log --oneline origin/main -- plugins/<name>/.claude-plugin/plugin.json  # who touched it last
git merge-base origin/main origin/<pr-branch>                    # is the branch current?
```

The shipped value and the last-touching commit are authoritative; a
bump commit mid-history is not. Also check the merge base equals
origin/main HEAD — a stale base with a genuine version collision ALSO
implies the committed gate binaries were built without main's newest
policy, which is the real (worse) defect behind the version number.

Related: [[review-end-state-not-superseded-commits]] — same principle
(judge the end state, not an intermediate commit), applied to the
TARGET branch's history instead of the PR branch's.
