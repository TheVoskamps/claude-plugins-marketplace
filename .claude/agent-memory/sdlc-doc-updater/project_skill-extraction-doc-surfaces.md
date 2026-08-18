---
name: skill-extraction-doc-surfaces
description: When a round extracts duplicated cross-plugin behavior into a new skill, the surfaces the developer reliably updates and the two it misses (docs/plugin-authoring-constraints.md pattern list, the consumer README's dependencies edge)
metadata:
  type: project
---

A fix round that removes cross-plugin duplication by extracting a new
skill updates the obvious surfaces itself — the owning plugin's
`plugin.json` `description`, every consumer SKILL.md/agent that used
to restate the rule, and the consumer plugin's README narrative. What
it leaves behind:

- `docs/plugin-authoring-constraints.md` — the "Patterns this
  marketplace uses" section is where the *generalization* of the
  extraction belongs (duplicated behavior → skill in the owning
  plugin + `dependencies` edge; only the mechanism moves, each
  consumer keeps its policy). Nothing else in the repo records it.
- The consumer plugin's README does not mention the new
  `dependencies` edge its `plugin.json` gained, even when the README
  has a whole section on how that plugin resolves things internally.
- The consumer README's "what differs between these consumers"
  sentence. It enumerates the arms on which the consumers diverge, and
  a later round that gives the extracted skill a **new reported
  outcome** (here: "branch members not claimed") makes its "only on X"
  scoping false — one consumer acts on the new arm, the other doesn't.
  Only opening both consumer SKILL.mds settles it; the sentence reads
  fine in isolation.

**Why:** on PR #224 (`git-tools:git-issues-from-branch`) both were
missing after a thorough developer pass, and both are the kind of
thing a future run cannot recover from the code.

**How to apply:** on any round whose diff adds a SKILL.md in one
plugin and a `dependencies` array in another, check those two files
before concluding the pass is a no-op. Do **not** add a CLAUDE.md
sweep section for the surviving restatements — a sweep rule over
duplicated behavior is itself the defect, per
`docs/plugin-authoring-constraints.md` → "Sharing behavior (a parse, a
lookup, a derivation)"; the per-consumer policy arms
(`C ∩ B`, one-member stand-in, multi-member refusal) are deliberate
duplication, not drift.
