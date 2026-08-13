---
name: de-specify-round-leftovers
description: A round that removes a named value (a model name) from prose so it lives in one file leaves ragged mid-paragraph wrapping and does not revisit consumer-attribution prose in other plugins; settle the "no file outside X spells it" claim with one grep
metadata:
  type: project
---

A **de-specify** round — deleting a value (e.g. `model: sonnet`) from
every prose surface so only the declaring frontmatter spells it —
lands as small in-paragraph substitutions and leaves two things:

- **Ragged wrapping.** The replacement text is shorter or longer than
  what it replaced, so the paragraph keeps the old line breaks
  (`value is a decision (the` / `bounded, spec-driven…`). markdownlint
  passes — MD013 is off here — so nothing catches it but a read.
  Reflow the whole paragraph, not the changed line.
- **The round's own headline claim.** "No file outside that
  frontmatter spells the value" is one
  `grep -rn -iE "\b(sonnet|haiku|opus|fable)\b" --include='*.md'` away.
  Run it: the generators declare `model: fable`, and an unrelated
  plugin README quotes a model name in sample output, so a naive grep
  looks like a violation until you read each hit.

A third surface no de-specify round touches: consumer-attribution
prose in *other* plugins. `github-prs/skills/pr-diff/SKILL.md` named
the agents the pipeline spawns — `theorem-generator` /
`theorem-disprover` then, `counterexample-verifier` as well now, and
the roster grows with each new stage — as
"`/sdlc:orchestrate`'s agents", which is false on the
`/sdlc:git-review-pr` path — the pipeline has two callers. Attribute a
fanned-out agent to the skill that spawns it, not to the flow that
usually runs that skill.

**Why:** the fixer edits the sentences it knows about; the claim it
writes about the *whole tree* is the part nobody measured.

**How to apply:** on any round whose point is "this value now lives in
exactly one place", grep the value across the tree before letting the
prose assert it, and re-read every paragraph the diff touched for
wrap damage. See [[agent-variant-doc-surfaces]] and
[[fan-out-doc-surfaces]].
