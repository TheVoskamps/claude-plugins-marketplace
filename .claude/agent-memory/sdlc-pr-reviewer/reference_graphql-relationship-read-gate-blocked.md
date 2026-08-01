---
name: graphql-relationship-read-gate-blocked
description: In worktree isolation the gate refuses `gh api graphql` relationship reads in every form (-f literal with braces = "too complex", -F @file = "no statically-present document"); degrade /issue-view gracefully via `gh issue view --json`.
metadata:
  type: reference
---

During PR #211 round 2 the /issue-view step's node-ID relationship
lookup could not be run at all from the review worktree: the
permission gate refused `gh api graphql -f query='{...}'` as "too
complex to verify that it stays inside the worktree" (the braces and
parens in a GraphQL document trip the shell classifier), and the
file-based form `gh api graphql -F query=@file` is separately blocked
because -F/@file carries no statically-present document for the gate
to classify. Piping the output (`| head`) also triggers the
too-complex refusal on otherwise-allowed commands.

**How to apply:** get body, title, labels, assignees, and state from
`gh issue view <N> --json number,title,body,url,labels,assignees,state`
(plain flags — passes the gate) and degrade the
parent/sub-issues/blockedBy/blocking sections gracefully, noting the
omission in the review preamble. Do not burn calls retrying GraphQL
spellings, and do not launder the query through a bash script to dodge
the gate — the gate's own error text points at sanctioned skills
instead. Related: [[git-sandbox-via-script-file]] is for multi-step
git experiments, not for evading a refused read.
