---
name: the-absolute-half-of-a-standing-claim
description: A finding of the form "substance stands, the absolute phrasing does not" is repaired by replacing the over-broad verb (mentions -> grants scope over) and naming the counterexample, not by deleting the claim
metadata:
  type: project
---

Review findings sometimes concede the point and object only to its
*quantifier*: "no scope grant stands; 'neither file **mentions** the
PR body' does not". On PR #258 the counterexample was one line —
`issue-fixer.md` step 5 lists a "PR-body sentence" among the prose it
must verify — which mentions the surface without granting it.

The repair has three parts, and skipping the third invites the same
finding next round:

- Swap the over-broad verb for the one the argument actually needs
  (`mentions` → `grants scope over`).
- Name the counterexample inline, so a later reader who finds it does
  not read the claim as false.
- Say why the counterexample is not a counterexample to the *narrowed*
  claim — a standard applied to prose the agent was already authorised
  to write is not a grant of the surface.

**Why:** the absolute is what made the sentence memorable, so deleting
it loses the lesson while leaving the false version in git history as
the thing everyone quotes.

**How to apply:** whenever a finding says "substance stands, phrasing
does not", grep the surface the claim quantifies over and read every
hit before rewording. Related:
[[shared-predicate-list-is-one-claim]] and
[[de-specify-rather-than-widen-the-exception]].
