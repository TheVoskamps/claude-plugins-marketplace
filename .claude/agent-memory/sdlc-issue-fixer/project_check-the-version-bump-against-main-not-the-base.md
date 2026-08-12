---
name: check-the-version-bump-against-main-not-the-base
description: On every fix round, diff the branch's plugin.json against origin/main — a merged sibling PR can land the same version number and silently void this PR's mandatory bump
metadata:
  type: project
---

The repo's hard rule is "a PR touching `plugins/<name>/` bumps that plugin's
`version`". The check that matters is
`git diff origin/main HEAD -- plugins/<name>/.claude-plugin/plugin.json`, not
"did this branch's diff contain a bump". A sibling PR merging the same version
number to main makes the branch's own bump a no-op without touching the branch,
and `git status` stays clean throughout.

On PR #254 the branch and main both read `0.14.0` — and the same hunk showed the
branch would also *revert* main's newer `description`, because the branch
predated a merge that rewrote it. Both are invisible in the PR diff, which is
computed against the merge base.

**Why:** the fix round is the last automated pass before `/pr-ready`, so it is
the last chance to catch a bump that main has absorbed. See
[[rebase-absorbs-an-identical-version-bump]] for the mechanism when it happens
*during* a rebase rather than before one.

**How to apply:** run the `git diff origin/main HEAD -- <plugin.json>` and
`git merge-base --is-ancestor origin/main HEAD` pair at the start of every fix
round. Do not resolve a stale branch yourself when main has diverged
semantically — on #254 main had deleted the `pr-reviewer*` agents and the
`pr-review-protocol` skill the branch's prose is written around, which is a
rewrite, not a rebase. Escalate it with both facts (behind-by count, what main
replaced) and let the orchestrator or the human decide.
