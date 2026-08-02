---
name: graphql-relationship-read-gate-blocked
description: Query-only `gh api graphql -f query='…'` documents now classify and ALLOW under the current gate (verified live on PR #222); the old "refused in every form" state was a pre-#113 gate. `-F query=@file` stays blocked; fall back to `gh issue view --json` when a document is refused.
metadata:
  type: reference
---

During PR #211 round 2 the then-active permission gate refused
`gh api graphql -f query='{...}'` as "too complex to verify that it
stays inside the worktree", so the /issue-view relationship lookup was
unrunnable from a review worktree in every form.

**That state is stale.** On PR #222 (2026-08-02, gate 0.9.15 active
from main) three separate query-only introspection documents —
`-f query='query { __type(name: "…") { inputFields { … } } }'`, full
of braces, parens, and quoted strings — each ran and ALLOWed: the
post-#113 gate classifies the document instead of refusing on shell
shape, and a document whose every top-level construct is a `query`
allows. Mutation-bearing documents allow only when every mutation
field is on `ghGraphQLMutationAllowlist` (#195, extended #209).

**How to apply:** try the plain `-f query='…'` literal form first for
GraphQL reads — do not preemptively degrade. The file-based
`-F query=@file` form is still blocked (no statically-present document
to classify), so keep the document inline. If a specific document is
refused anyway, fall back to
`gh issue view <N> --json number,title,body,url,labels,assignees,state`
and degrade the parent/sub-issues/blockedBy/blocking sections
gracefully, noting the omission in the review preamble. Related:
[[git-sandbox-via-script-file]] is for multi-step git experiments, not
for evading a refused read.
