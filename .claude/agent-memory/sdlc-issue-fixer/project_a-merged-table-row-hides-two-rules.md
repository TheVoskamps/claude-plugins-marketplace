---
name: a-merged-table-row-hides-two-rules
description: A disposition-table row worded "either X's or Y's path" collapses two actors whose rules differ; split it per actor and re-grade the sentence below the table that names only one actor's value
metadata:
  type: project
---

A table row that quantifies over actors — "malformed twice (**either
agent's** own re-spawn path)" — asserts the two actors share an
outcome. That is a claim to check, not a convenience: in the sdlc
review pipeline a disprover malformed twice leaves the theorem
unsettled, while a verifier malformed twice **files** the finding with
the disprover's proposed class. One row said both went unsettled, and
three prose surfaces said otherwise.

Two things make it survive a review round:

- The merged wording usually originates in the **issue's own** table,
  so the developer transcribed it faithfully. Resolve toward the rule
  the prose states repeatedly, not the table the issue drew.
- The paragraph under the table names one actor's value ("the
  transcription of *the verifier's* consequence class"). Splitting the
  row falsifies that sentence silently — it is the same absolute-half
  problem as [[the-absolute-half-of-a-standing-claim]]. Re-grade the
  sentence in the same edit and say which row supplies which value.

**Why:** a derivation table is the surface a reader trusts over prose,
so a merged row is the one that actually ships the wrong behavior.

**How to apply:** grep the table's own vocabulary (`malformed`,
`unsettled`, `could not be settled`) across the plugin before
declaring the split complete, and check each hit names one actor.
See [[shared-predicate-list-is-one-claim]].
