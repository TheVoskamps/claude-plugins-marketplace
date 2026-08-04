---
name: flag-model-cannot-swallow-containment-operands
description: In the permission-gate's read-only-utility track, a utility with no operandsFn (ls, cat, find, …) takes its containment operands from pathOperands (flag-model-UNAWARE — it keeps every non-dash token, never consumes a value flag's value), so a "modelling -X as a value flag would swallow the path operand and skip containment" rationale is counterfactual there; probe such claims against the track's ACTUAL extractor. Also: `go version -m <binary>` verifies a cross-platform committed binary's build metadata without executing it.
metadata:
  type: reference
---

Found on PR #208 round 4 (#193, the `ls` addition): the shipped code,
README, and test comments all justified leaving GNU/BSD-divergent short
flags (`-I`/`-T`/`-w`) unmodelled with "modelling them as value flags
would let `ls -I <path>` swallow its only path operand, leaving nothing
for containment to check and allowing an out-of-repo listing outright."

That mechanism cannot occur for `ls`. The defer/allow decision
uses `flagScan` (value-flag-aware), but `ls`'s containment walk uses
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
consequence through the ACTUAL operand extractor for that PROGRAM, not
for the track. Both tracks now carry per-program `operandsFn` hooks
(`readOnlyUtilities` / `inRepoWriters`) and those extractors ARE
value-flag-aware, so the story can be true for a program that has one
(`sed`, `awk`, `grep` on the read track; `cp`/`mv`/`sed -i`/`tee` on the
write track). It stays counterfactual for a program that falls back to
`pathOperands` (`ls`, `cat`, `find`, the rest).

**Since #225 the extractor is `utilitySpec.operands`, not `operandsFn`
alone**: it is `pathOperands`/`operandsFn` PLUS the values of the
program's declared `pathValueFlags`, appended (`pathFlagValues`, both
tracks). So a swallow story is now false even for a program WITH a
grammar when the flag is a declared path flag — `grep -f`, `sed -f`,
`awk -f`/`-i`, `diff -X`/`--from-file`/`--to-file`/`-S`,
`wc --files0-from`, `sort -T`/`--random-source`,
`realpath --relative-to` all reach containment in every spelling. Read
the table entry, not just the function: what is dropped is a pattern, a
script or a number, and only a flag ABSENT from `pathValueFlags` can
still hide a path.

Same round, second tool: `go version -m <committed binary>` prints
go version, module, deps, `-trimpath`, `CGO_ENABLED` for a foreign-arch
binary (linux-amd64 on a mac) — use it to confirm both committed gate
binaries were rebuilt consistently when only one can be executed.
Related: [[guardrails-binary-verification]],
[[narrowing-a-gate-promotes-cosmetic-helpers]].

Two probe facts that older review notes get backwards: `ls` IS on the
read-only-utility allow track (`readOnlyUtilities`), so it grades a path
rather than deferring on every one; and a redirect target IS graded —
destinations land in `sc.redirectTargets` and are decided by
`redirectVetoesAllow`. Neither `ls <path>` nor `cmd > <path>` is a
vacuous probe any more. Pick a probe form by reading the program's
classifier arm — see the track-terminal note in
[[guardrails-binary-verification]], which also carries the negate-check
recipe.
