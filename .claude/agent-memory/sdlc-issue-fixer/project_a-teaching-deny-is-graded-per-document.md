---
name: a-teaching-deny-is-graded-per-document
description: A verdict justified by the prose it teaches must cover every element of the input it fires on — the per-VERB membership rule for a redirect deny is only half of it; a bundle needs the per-DOCUMENT rule too
metadata:
  type: project
---

When a tier's membership rule is "this verdict is legitimate only
because its message tells the caller what to do instead", the rule is a
property of the whole INPUT, not of the one element that matched.

**Why:** `ghGraphQLMutationRedirect` in the permission gate denied on
the first field found in `ghGraphQLMutationRedirects`, so `mutation {
updateIssue(…) deleteIssue(…) }` returned a deny whose reason
enumerated `updateIssue`'s allowed spellings and never mentioned
`deleteIssue` — a dead end, which is exactly what the map's own doc
comment and a pinned sibling test (the `updateIssueFieldValue +
deleteIssue` analogue, which DEFERS) said must not happen. The per-verb
rule ("a verb joins this map only when its redirect is total") had been
implemented and the per-document rule had not, and the whole-document
version reads as a restatement rather than a second obligation, which
is why it was missed.

The repair shape: fire only when every element is covered (redirectable
or already allow-listed), otherwise fall through to the middle tier.
That is the same all-fields-must-pass the sibling ALLOW check already
carried, applied to the TEACHING set instead of the allow set — so the
tell is a codebase that already spells the rule for one set and not the
other.

Two things that fell out of the same fix and generalize:

- A map whose value is one string forces the rationale into the
  caller's message, and the caller's message is then written for the
  founding member. Splitting the value into `{why, redirect}` is what
  keeps a second member from inheriting the first's justification
  verbatim.
- The verdict probe must be run per-shape, not per-verb: verb alone,
  verb + covered companion, verb + uncovered companion, and with the
  uncovered companion FIRST (a first-match loop is order-sensitive and
  a same-order probe hides it).

**How to apply:** when a finding says a verdict's justification does not
cover the whole input, look for the sibling check that already grades
all elements and mirror it. Negative-control it by reverting your guard
to the pre-fix `continue` and confirming the new rows fail.

Related: [[project_shared-predicate-list-is-one-claim]],
[[negative-control-the-approved-snippet]],
[[project_the-class-is-the-set-of-uses-not-values]].
