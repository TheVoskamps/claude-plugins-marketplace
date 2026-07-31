---
name: redundant-restatement-is-not-a-defect
description: when a sweep replaces a behavioral statement with a policy rationale, check whether the behavior is still specified elsewhere before filing — a lost restatement of an already-specified behavior is not a defect
metadata:
  type: reference
---

A doc sweep often replaces a *behavioral* sentence ("X is dropped")
with a *policy rationale* ("the file is never edited outside a run, so
X never occurs"). The rationale reads weaker — it asserts as fact a
policy the tool cannot enforce — and the pull is to file it as an
accuracy defect.

**Before filing, ask whether the behavior is still specified
elsewhere.** If another passage independently pins the behavior, the
removed sentence was a redundant restatement and its loss changes no
agent's behavior. Only file if the sweep left the behavior genuinely
unspecified.

**Worked case (PR #199 round 4, `/repo-config`):** the sweep replaced
"any hand-edited slot the wizard doesn't know about (e.g. a user-added
`effort` slot) is dropped" with "the file is never edited outside a
`/repo-config` run, so it never carries a slot the wizard didn't
itself write." The premise is policy, not enforcement. But the drop
behavior survived in two independent places in the same file:

- Step 2 parse scope: "A field present in the file but unrecognized by
  the current schema is ignored, not surfaced."
- Step 3b.5 renderer spec: "The renderer is purely a function of the
  captured state — it never invents defaults."

Together those two fully determine that an unknown slot is dropped, so
the rewritten rationale costs nothing operationally. Verdict: not a
finding.

**How to apply:** grep the file for the *behavior* the deleted
sentence described (not its wording) before grading. Two independent
specifications of the behavior = redundant restatement = no finding.
Zero = real finding, graded on consequence. Complements
[[deleted-line-was-load-bearing]], which is the mirror case: there,
the deleted line was the *only* thing reconciling siblings, so its
removal broke them.
