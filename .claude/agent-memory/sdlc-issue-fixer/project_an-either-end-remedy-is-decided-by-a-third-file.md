---
name: an-either-end-remedy-is-decided-by-a-third-file
description: A finding offering "fix either end, not both left disagreeing" usually has one arm already forbidden by a third document that owns one of the two surfaces — find that owner before picking
metadata:
  type: project
---

When a finding names two disagreeing statements and says to reconcile
them by changing **one** of them, do not read that as a free choice.
Go find whichever document *owns* each of the two surfaces; one arm is
often already forbidden, and the finding's author did not necessarily
check.

**Why:** on PR #283 a finding read "either trim the root README's
`sdlc` bullet back to shorthand or update the CLAUDE.md sentence that
says the bullet has no behavior to falsify; one of the two, not both
left disagreeing." Trimming looked like the smaller edit and the one
that restored the invariant. It was illegal:
`docs/plugin-authoring-constraints.md` → "A new skill's registration
surfaces are…" names the root `README.md` roster bullet for a plugin
as one of the surfaces a **new skill** must reach, and the PR's whole
subject was a new skill. Trimming would have satisfied the finding and
broken a rule no one had cited. Only the CLAUDE.md arm was available,
and the repair worth writing was not "delete the false clause" but
"say which part of the bullet is stable (the agent shorthand) and
which is the part a rule elsewhere makes mutable (the skill names)".

**How to apply:** for each of the two statements, grep the repo's rule
surfaces — `CLAUDE.md`, `docs/*.md`, the owning plugin's README — for
the *surface* the statement is about (here, "root `README.md`", "roster
bullet"), not for the statement's own words. If a rule requires content
on that surface, that arm is closed and the other one is the fix. When
both arms stay open, prefer the one that leaves the constrained surface
alone. State in the report which arm you took and what closed the other,
so the next round does not re-litigate it. Companion to
[[pick-the-remedy-that-keeps-the-exemplar]] (there the rule cites the
violating site; here a third file compels the site's content) and to
[[pointer-target-must-carry-the-claim]].
