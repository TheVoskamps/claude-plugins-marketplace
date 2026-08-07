---
name: fetch-failed-check-local-origin-ref
description: When `git fetch origin main` dies on an SSH timeout in a fresh worktree, compare the local origin/main ref against the primary clone's HEAD before escalating — it is usually already current
metadata:
  type: feedback
---

When `git fetch origin <source-branch>` fails with
`ssh: connect to host github.com port 22: Operation timed out`, do not
treat the branch-create as blocked. Read the local ref instead:

```bash
git rev-parse origin/main HEAD
```

A subagent worktree shares the primary clone's object store and refs,
so `origin/main` carries whatever the orchestrator's last fetch or
merge left there — typically the merge commit of the PR that unblocked
your issue. When it matches, `git switch -c <branch> origin/main` roots
the branch correctly and the run proceeds; the missing fetch cost
nothing.

**Why:** the timeout is an un-tapped biometric prompt on the SSH agent,
not a network fault, and the human may be away for a long while.
Stopping on it burns the run for a ref that was already correct.

**How to apply:** at branch-create only. The end-of-run `git push`
still needs the credential, so a still-failing agent surfaces there —
report that failure per the credential-surfaces rule rather than
retrying it in a loop. This is the complement of
[[feedback_stale-origin-main-ref-after-fetch]]: that one is a fetch
that succeeded without advancing the ref, this one is a fetch that
never ran against a ref that was already current. Both are settled by
reading the ref, never by trusting the fetch's exit status.
