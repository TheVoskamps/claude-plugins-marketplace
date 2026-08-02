---
name: flag-model-cannot-swallow-containment-operands
description: In the permission-gate's read-only-utility track, containment operands come from pathOperands (flag-model-UNAWARE — it keeps every non-dash token, never consumes a value flag's value), so a "modelling -X as a value flag would swallow the path operand and skip containment" rationale is counterfactual; probe such claims against pathOperands, not flagScan. Also: `go version -m <binary>` verifies a cross-platform committed binary's build metadata without executing it.
metadata:
  type: reference
---

Found on PR #208 round 4 (#193, the `ls` addition): the shipped code,
README, and test comments all justified leaving GNU/BSD-divergent short
flags (`-I`/`-T`/`-w`) unmodelled with "modelling them as value flags
would let `ls -I <path>` swallow its only path operand, leaving nothing
for containment to check and allowing an out-of-repo listing outright."

That mechanism cannot occur in this codebase. The defer/allow decision
uses `flagScan` (value-flag-aware), but the containment walk uses
`pathOperands(args)` (classify_files.go), which skips only leading-dash
tokens and keeps EVERY non-dash token as an operand — a value flag's
value included. So even with `-I` modelled as a value flag,
`ls -I /etc` still surfaces `/etc` to `containPathOperands` and earns
the #148 deny. Flag-model changes can only move a form between
defer and allow-with-full-containment; they can never remove a token
from the containment walk. (The unmodelled-defers choice was still
right — fail-safe convention — so this graded Low: wrong rationale,
correct behavior.)

**How to apply:** whenever a guardrails PR justifies a flag-table choice
with an operand-swallowing / containment-skipping story, re-derive the
consequence through the ACTUAL operand extractor for that track
(`pathOperands` on the read track, the per-program `operandsFn` on the
write track — those write extractors ARE value-flag-aware, so the story
can be true there) before accepting or repeating it.

Same round, second tool: `go version -m <committed binary>` prints
go version, module, deps, `-trimpath`, `CGO_ENABLED` for a foreign-arch
binary (linux-amd64 on a mac) — use it to confirm both committed gate
binaries were rebuilt consistently when only one can be executed.
Related: [[guardrails-binary-verification]],
[[narrowing-a-gate-promotes-cosmetic-helpers]].

Correction note: [[probe-forms-that-cannot-prove-gate-carve-outs]] is
frozen at round 3 — its two premises (`ls` on no allow track; `>`
targets never graded) were deliberately falsified by round 3's fix
(24826ac): `ls` is now in `readOnlyUtilities` and redirect targets are
recorded in `sc.redirectTargets` and graded by `redirectVetoesAllow`.
Its probe-form advice is stale for #193-era binaries; the negate-check
recipe in it is still good.
