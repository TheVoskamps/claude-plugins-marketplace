---
name: encode-the-interpretation-not-the-instance
description: When successive review rounds rule opposite ways on the same check, the defect is the check's wording — edit the rule to settle it, rather than reflowing the instances it flagged.
metadata:
  type: project
---

A finding that says "rounds 1 and 2 ruled X satisfies this, this round
ruled it does not" is not a finding about the instances. It is a
finding about the rule the rounds are applying: the rule admits two
readings, so fixing the flagged instances buys one clean round and the
dispute returns on the next diff that hits it.

**Why:** #265 shipped a note prescribing that a `→ "Section"` pointer
be compared "to the heading line character for character". Three
pointers wrap the quoted title at a word boundary — unavoidable, since
the prose wraps at a column limit and the title is longer than the
room left on the line. Two verifiers read the wrap as satisfying the
comparison, a third read it as failing. Unwrapping the three sites
would have left the rule still saying the thing that cannot be
satisfied for a title near the column limit.

**How to apply:** when a finding hands you a split ruling, pick the
reading that stays satisfiable in the general case and write it into
the rule — here, that a wrap is joined back to a single space before
comparing, and that what the comparison catches is a pointer whose
*words* differ (a truncation, a reordering, a dropped subtitle). Then
re-check the flagged instances against the settled rule instead of
reflowing them. Related: [[shared-predicate-list-is-one-claim]] and
[[pointer-target-must-carry-the-claim]] on grading a pointer against
what its target actually says.
