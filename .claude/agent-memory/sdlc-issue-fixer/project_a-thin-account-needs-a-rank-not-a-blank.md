---
name: a-thin-account-needs-a-rank-not-a-blank
description: Filling a blank residual record with a generic account silently outranks the informative ones under a first-wins aggregator — rank the generic label below the specific ones, and negative-control the ordering that proves it
metadata:
  type: project
---

When a finding says "this high-frequency site logs an empty record",
the obvious fix is to give it an account. Do that — but first read the
AGGREGATOR that picks which of several per-part records the whole call
emits. If it is first-wins over "has an account", filling the blank
makes the residual WIN lines it previously lost, because the residual
usually fires on the first part of a command.

**Why:** on #262 round 2, `classifySimpleCommand`'s no-specific-rule
residual (an unrecognized program: `npm`, `python3`, `make`) returned a
bare `deferToPipeline`, so the §7 evolution log wrote
`{"operation":"","analysis":""}` for the largest share of deferred
traffic. Converting it to `deferJudgment` fixed that row and quietly
broke another: `classifyBash` kept the FIRST defer carrying an
analysis, so `npm test && git reset --hard` would have logged "the gate
has no table for npm" and dropped the reset's account — the half a
tuner acts on. The repair is a rank, not a discard: hold the residual
in its own variable and use it only when no other analysis was seen, so
it still reaches the log when it is the sole account on the line.

**How to apply:**

- Before converting a bare residual, grep the aggregator for how it
  chooses among same-bucket decisions, and name the residual's label as
  a constant so the aggregator can test for it.
- Assert the ranking in BOTH orderings. The reversed one (informative
  part first) passes with or without the fix, so only the
  residual-first row proves anything — say which is the control in the
  test's own comment, or the next reader deletes the wrong subtest.
- Negative-control by disabling the ranking arm (`case false && …`) and
  confirming EXACTLY the residual-first subtest fails. Restore by
  `diff`ing against a copy taken before the edit — see
  [[project_delete-the-named-mechanism-to-grade-the-prose]] for the
  same technique applied to prose.
- Sweep the surfaces that describe the log's shape. "operation and
  analysis are empty for a bare deferToPipeline" stays true, but a
  reader's mental example ("the gate has no rule for this → blank
  row") stops being one: fix it in the gate README, the verification
  playbook and the doc-updater's agent-memory note, not just the code.
