---
name: carve-out-leaves-absolute-attributions
description: A round that adds an exception path ("in this case take X from the OTHER agent") leaves sibling files asserting the unqualified attribution; grep the actor's name, not the rule's name.
metadata:
  type: feedback
---

When a round carves an exception into a rule — "the class comes from
the verifier, except on the verifier-malformed-twice path, where you
take the disprover's proposal" — the exception is written where the
rule is defined and nowhere else. Sibling files restate the rule as an
**attribution** ("a severity is transcribed from the consequence class
a `counterexample-verifier` assigned") and go silently false.

**Why:** on #259 `skills/orchestrate/SKILL.md`'s "Never pre-set or
soften a severity" bullet named the verifier as the assigner while
`pr-review-pipeline/SKILL.md` had grown a path where the disprover's
proposal is what gets transcribed. The bullet's *point* (never
re-tier) was intact, which is why every previous round read past it —
the falsehood sits in the incidental clause, not the imperative.

**How to apply:** grep the ACTOR named in the new exception
(`counterexample-verifier`, `theorem-disprover`) across the plugin,
not the rule's vocabulary — the stale sentences name the actor and
never name the exception. Repair by widening the attribution and
leaving the pointer to do the work ("a consequence class one of the
review agents assigned, by the rules in `<skill>` → `<section>`"),
rather than restating the carve-out at the pointer site: CLAUDE.md's
sdlc sweep section forbids re-arguing a rule at a consumption point.
Include the rule's OWN file in that grep: `pr-review-pipeline`'s
"Consequence classes are transcribed, not graded" opened with the
unqualified "the verifier already assigned" two paragraphs above the
sentence stating the exception — three fixer rounds widened the
downstream restatements and never touched the header sentence.
Related: [[deferral-pointer-outruns-its-target]],
[[widened-enumeration-trailing-clause]].

The same round's own new prose is worth one read for definite
singulars: "on **the one** entry where no usable verifier report
exists" states a per-entry rule as if at most one such entry can occur
in a review body. Write "on any entry for which".
