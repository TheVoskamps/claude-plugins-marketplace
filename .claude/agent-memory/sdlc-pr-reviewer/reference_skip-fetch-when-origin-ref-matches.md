---
name: skip-fetch-when-origin-ref-matches
description: git fetch over SSH can time out (port 22, biometric-gated key) and block a review; if the local origin/<branch> ref already equals the PR's headRefOid, skip the fetch and check out from the existing remote-tracking ref.
metadata:
  type: reference
---

`git fetch origin` in a review worktree can fail with
`ssh: connect to host github.com port 22: Operation timed out`. That
is not a network fault and not something to debug or work around by
touching remotes or auth — it is a biometric-gated SSH key waiting on
a tap the user may be away from.

The review often does not need the fetch at all. The worktree shares
the primary clone's object store and remote-tracking refs, so the PR
head is frequently already present locally.

**How to apply:** before reaching for `git fetch`, compare the local
remote-tracking ref against the live PR head:

```bash
git rev-parse origin/<branch>
gh pr view <N> --json headRefOid --jq .headRefOid
```

`gh` goes over HTTPS, so it answers even when SSH is stalled. When the
two match, the objects are local and complete — check out with
`git checkout -B <branch> origin/<branch>` and review immediately. Only
when they differ do you actually need the fetch, and then the SSH stall
is worth surfacing to the user rather than retrying in a loop.

Confirm you are on the reviewed bytes afterward per
[[worktree-file-can-be-stale-after-checkout]]; checking out is still
required before exercising anything, per
[[checkout-pr-branch-before-exercising]].
