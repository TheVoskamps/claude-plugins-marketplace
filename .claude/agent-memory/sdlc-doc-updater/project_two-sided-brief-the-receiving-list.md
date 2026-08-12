---
name: two-sided-brief-the-receiving-list
description: When an sdlc round adds a field to a spawn-prompt template in orchestrate/SKILL.md, the receiving agent's Inputs list is the half that stays stale — even when the new prose cites that Inputs section as its sanction
metadata:
  type: project
---

A round that widens a spawn-prompt template in
`plugins/sdlc/skills/orchestrate/SKILL.md` argues the widening on the
SKILL.md side and leaves the receiving agent's `## Inputs` list
untouched. PR #258 added issue *titles* to the `doc-updater` template
and justified them by quoting `doc-updater.md`'s Inputs section
("it never reads those issues") — but that Inputs list still
enumerated only "Issue number(s)", so the agent's own definition did
not describe the brief it now receives.

**Why:** citing the other end reads like checking it. The cited
sentence can be true (it was) while the *list* above it is
incomplete, and the citation makes the round feel two-sided when only
one side moved.

**How to apply:** on any spawn-template diff in SKILL.md, open the
named agent's `## Inputs` bullet list — not just the prose under it —
and match it field by field against the template block. Repair on the
receiving side; the template is what the orchestrator actually sends.
Related: [[principle-prose-illustrative-examples]].
