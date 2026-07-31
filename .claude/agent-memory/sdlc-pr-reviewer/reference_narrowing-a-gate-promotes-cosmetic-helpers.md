---
name: narrowing-a-gate-promotes-cosmetic-helpers
description: When a permission-gate PR narrows an ASK into an ALLOW, re-audit every helper the new ALLOW consumes — a parser written to LABEL an ASK reason becomes the security boundary and its lossy cases become bypasses.
metadata:
  type: reference
---

A guardrails PR that turns a blanket ASK into a conditional ALLOW
silently promotes whatever helper computes the condition from
*cosmetic* to *load-bearing*. Any shape that helper mis-reads was
harmless while everything ASKed and becomes a bypass the moment one
branch ALLOWs.

**Worked instance (#195, PR #205):** `topLevelSelectionFields` existed
only to name mutation fields in the ASK reason ("Used to name the
mutation fields in the ASK reason"). It has no `...` handling, and
`walkGraphQLTopLevel`'s `case "fragment":` discards fragment bodies.
So `mutation { ...addSubIssue } fragment addSubIssue on Mutation {
deleteIssue(…) }` reported `mutationFields = ["addSubIssue"]` and
ALLOWed while GitHub executed `deleteIssue`. Verified live: GitHub
parses, validates, and executes a root-level fragment spread (probe
with unresolvable IDs reaches `NOT_FOUND` at the resolver), and
`__schema { mutationType { name } }` is literally `Mutation`, so
`on Mutation` is a valid type condition.

**How to apply:** on any gate PR whose diff adds an ALLOW where an ASK
used to be, list every field of the result struct the new condition
reads, find the function that populates each, and read that function's
own doc comment for its *original* purpose. Then enumerate the input
shapes it drops or mislabels (indirection like fragment spreads /
includes / aliases / variables, and anything it skips by depth or
paren counting) and probe each against the committed binary, comparing
with the `origin/main` binary to prove regression vs pre-existing.
The author's own new guard is the tell: PR #205 added `sawSubscription`
for exactly this reason but stopped at one indirection.

See [[guardrails-binary-verification]] for the probe mechanics and
[[checkout-pr-branch-before-exercising]] for getting on the right bytes
first.
