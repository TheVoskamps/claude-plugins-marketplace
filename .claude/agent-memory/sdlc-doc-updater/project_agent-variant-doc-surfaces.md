---
name: agent-variant-doc-surfaces
description: Doc surfaces a PR that adds an sdlc agent variant (or extracts an agent's instructions into a preloaded skill) reaches — and the two the developer reliably leaves alone
metadata:
  type: project
---

A PR that adds a *variant* of an existing sdlc agent, or moves an
agent's instructions into a `skills:`-preloaded skill, updates
`CLAUDE.md`, `orchestrate/SKILL.md`, `git-review-pr/SKILL.md` and
`plugin.json` on its own — the developer covers those. What it leaves:

- `docs/plugin-authoring-constraints.md` → *Patterns this marketplace
  uses*. The pattern list is the durable home for a new packaging
  shape; a within-plugin dedup via preloaded skill is not covered by
  the existing cross-plugin lib-as-skill entries.
- Count words introduced with the new section ("Three reviewer
  definitions exist —", "except for three frontmatter lines",
  "those three lines", "a fourth differing line"). A brand-new
  section is where the core-principles §7 tally defect is born.

**Why:** the developer writes prose about the thing it just built and
stops at the plugin's own tree; the marketplace-wide reference doc has
no diff hit forcing it.

**How to apply:** on any agent/skill-topology PR, open
`docs/plugin-authoring-constraints.md` even when it is not in the diff,
and grep the new sections for number words. Also open
`plugins/issues/skills/lib/repo-config.md`: it names the sdlc agents
that read repo-config and says which of them dispatch on
`source-control`, so an agent added, retired, or changed in what it
reads falsifies it — and fixing it means an `issues` version bump in
the same PR. See [[skill-extraction-doc-surfaces]].
