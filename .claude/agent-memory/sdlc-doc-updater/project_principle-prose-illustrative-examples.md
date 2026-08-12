---
name: principle-prose-illustrative-examples
description: A round that adds a named "principle" section to orchestrate/SKILL.md pays for itself in illustrative examples — each asserts a scope grant or a template shape that must be checked against the named agent's definition
metadata:
  type: project
---

When an sdlc round adds a *principle* section to
`plugins/sdlc/skills/orchestrate/SKILL.md` (PR #258 added
"Spawn-prompt principle" and "Report-consumption principle"), the
rules themselves are policy and not checkable — but each is sold with
an **illustrative example**, and those are ordinary claims about other
files. Two classes were wrong on that PR:

- **A cited scope grant the named agent does not have.** The prose
  read "a standing 'do NOT edit the PR body' aimed at `doc-updater`
  … carves away scope the agent definition grants". Neither
  `doc-updater.md` nor `issue-fixer.md` grants scope over the PR body
  — `issue-developer` authors it and is the only agent whose
  definition puts it in scope. (`issue-fixer.md` does *mention* it:
  step 5 lists a "PR-body sentence" among the prose whose claims it
  must verify. That is a standard applied to prose it was already
  authorised to write, not a grant of the surface.) The prohibition
  removed nothing *granted*; keeping the PR description current is
  scope a brief has to add.
- **A destination that only partly receives what the prose says.**
  "Its result goes into the plan table" for the Phase 1 analysis: the
  table has Complexity and Notes columns, so dependencies and
  conflicts arrive as Notes prose and the files-likely-affected list
  mostly does not arrive at all.
- **A widened enumeration that collides with the absolute right after
  it.** Repairing the bullet above by folding "the batching rationale"
  into the list of what the analysis yields falsified the very next
  sentence, "None of it goes into a spawn prompt" — the developer
  template's `Why these are batched` line carries exactly that, and
  `issue-developer`'s Inputs receives it. Loosening prose to match an
  example is only safe if you re-read the sentence the enumeration
  governs. Repaired by carving the grouping *decision* out as the
  named exception (a decision is passed; a finding is not).
- **A report-provenance sentence crediting the wrong producer.** The
  final-report paragraph called `Review Verdict` and `Review Rounds`
  "the pipeline's"; the pipeline's own "Report back" lists verdicts,
  severity counts, theorem tally and tier — no round count. The
  orchestrator counts its own loop iterations, so a section about
  which cells are second-hand had miscategorised an own-observation
  cell. Open the named producer's Report-back section and match it
  field by field.

**Why:** principle prose reads as pure policy, so the reflex is to
leave it alone; the examples inside it are the falsifiable part and
they are written by the same agent that wrote the rule.

**How to apply:** for every example naming an agent, open that agent's
definition and grep for the surface the example claims it owns or is
denied. For every "goes into `<artifact>`" clause, open the artifact's
template and match it field by field. Related:
[[no-blanket-predicate-over-a-list]] and
[[feedback_qualifier-that-contradicts-the-next-paragraph]]. The
PR-body half is the other side of
[[pr-description-is-a-doc-surface]]: that entry is why the spawn
prompt must grant the surface, this one is why the agent definition
alone never does.
