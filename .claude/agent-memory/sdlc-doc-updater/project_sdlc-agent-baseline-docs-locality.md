---
name: sdlc-agent-baseline-docs-locality
description: sdlc agents' model tier and foreground enforcement are documented only in orchestrate/SKILL.md + the agent frontmatter; top-level README and /docs describe agents by roster, not model.
metadata:
  type: project
---

# sdlc agent baseline docs locality

The sdlc agents' shared frontmatter baseline — which model each agent
runs (`sonnet` for issue-developer/issue-fixer/doc-updater, `opus` for
pr-reviewer), and how foreground execution is enforced — is documented
in exactly two places: `plugins/sdlc/skills/orchestrate/SKILL.md` (the
"hardened baseline" paragraph near the top and the "Token Efficiency"
section near the bottom) and the individual agent `.md` frontmatter.

**Why:** The top-level `README.md` describes sdlc only as a roster
("the developer/fixer/reviewer/doc agents"); `docs/plugin-migration-plan.md`
lists the four agents by name as a topology/structure plan. Neither
mentions model tier or the (now-removed) `background: false` frontmatter
key. The `block-background-agents` README documents its own hook's
`run_in_background: false` spawn-time flag — a different thing from the
inert agent-frontmatter `background:` key — and is unaffected by sdlc
agent-model changes.

**How to apply:** When a PR changes the sdlc agents' model tier or the
foreground-enforcement mechanism, the doc updates live in
orchestrate/SKILL.md and the agent frontmatter, and a well-formed PR
already contains them. Do not ripple such a change into the top-level
README or /docs — they document agents by role, not by model. Parallels
[[project_github-setup-docs-locality]] (behavior documented in one
SKILL.md; other docs reference by name only).
