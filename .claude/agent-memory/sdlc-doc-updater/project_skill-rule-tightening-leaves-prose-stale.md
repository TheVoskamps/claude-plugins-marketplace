---
name: skill-rule-tightening-leaves-prose-stale
description: When a fixer tightens a resolution rule inside a SKILL.md Execution step, the same file's narrative section above it and the plugin README's per-skill blurb keep the old flat rule
metadata:
  type: project
---

A round that tightens a decision rule in a `plugins/*/skills/*/SKILL.md`
**Execution** step almost never updates the three places that restate
that rule loosely:

- the same SKILL.md's narrative section above Execution (in
  `github-prs`, the "Own issue set only" section) — it states the rule
  as a flat absolute ("**the branch name is the higher-fidelity source
  of truth**") that the tightened step now contradicts in one branch of
  its case split;
- the plugin README's per-skill section (`plugins/github-prs/README.md`
  → `### /pr-create …`, `### /pr-link-issue …`), one blurb per skill,
  both needing the same edit;
- the calling agent's paraphrase — `plugins/sdlc/agents/issue-developer.md`
  step 10 describes what `/pr-create` guards against in a parenthetical.

**Why:** seen on PR #224 (issue #223). The fixer changed the empty-
intersection fallback into a three-way case split with an outright
refusal, editing only the Execution bullets in both SKILL.md files plus
the sibling doc surfaces of the *reviewer* change it was also making.
Every narrative restatement of the old fallback survived untouched.

**How to apply:** when a diff touches only numbered/Execution steps of
a SKILL.md, grep the rest of that file, the plugin README, and any
sdlc agent that invokes the skill, for the rule's distinctive phrase
(here `higher-fidelity`) plus the skill name. Related:
[[project_plugin-docs-locality]].
