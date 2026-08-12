---
name: gate-blocks-sed-i-empty-suffix
description: The permission gate refuses BSD `sed -i ''` — it reads the empty suffix as a write target resolving outside the repo; use the Write/Edit tools for in-place edits instead
metadata:
  type: reference
---

`sed -i '' -e ... <file>` — the mandatory empty-suffix form on macOS —
is DENIED by the guardrails gate with:

> Blocked: 'sed' target '' resolves outside the current repository

The gate treats `sed -i`'s suffix argument as a write target and an
empty string does not resolve inside the repo, so the deny fires
however in-repo the actual file argument is. There is no in-repo
spelling that gets through; `-i.bak` would leave a stray file.

**How to apply:** never reach for `sed -i` to do a mechanical
find-and-replace across a file, even for a "boring" bulk edit such as
producing tier variants of an agent skeleton. Use `Edit` (with
`replace_all` when the substitution really is uniform), or `cp` the
file and then `Edit` the copy's differing lines. `cp` itself is fine —
only the in-place `sed` is refused.

Related: [[permission-gate-self-hosting]] for the general shape, and
[[worktree-write-path-must-be-worktree-copy]] for the other write-path
trap in a worktree run.
