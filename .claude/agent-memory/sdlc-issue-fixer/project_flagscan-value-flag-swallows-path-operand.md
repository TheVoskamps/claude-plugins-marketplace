---
name: flagscan-value-flag-swallows-path-operand
description: CORRECTION — in the permission-gate, flagScan's valueFlags do NOT decide which tokens get contained; pathOperands keeps every non-dash token without consulting the flag model, so mismodelling a flag as value-taking makes the verdict STRICTER (deny), never fail-open. Verified against a real binary.
metadata:
  type: project
---

**This memory previously asserted the opposite, and was wrong.** It
claimed that marking a short flag as a `valueFlags` entry lets it eat
the command's only path operand so containment never runs (an outright
ALLOW). That is inverted. The same inverted claim shipped in the gate's
own `lsDefers` comment, its README and a test comment before it was
caught.

**The actual mechanism.** Two independent functions:

- `flagScan.defers(args)` decides only allow-ELIGIBILITY. Its internal
  `pathOps` counter exists solely to enforce `maxPathOperands`, and for
  `ls` that cap is `-1` (unlimited), so consuming a token changes
  nothing.
- `pathOperands(args)` builds the list actually put through Engine B
  containment, and it keeps **every token that does not begin with
  `-`** — it never consults the flag model at all.

So `ls -I /etc` yields the operand `/etc` either way. The two outcomes:

    unmodelled          -> unknown flag -> lsDefers -> DEFER
    modelled as a value -> allow-eligible -> containment runs -> DENY

**Verified, not reasoned:** temporarily adding `-I`/`-T`/`-w` to
`lsDefers`'s `valueFlags`, rebuilding the darwin-arm64 binary and piping
real `PreToolUse` events gave `ls -I /etc -> deny`,
`ls -w 80 /etc -> deny`, `ls -I README.md -> allow`.

**Why they still stay unmodelled:** not to hold a hole shut, but because
a flag model must not assert an arity that is wrong on one of the two
platforms — as value flags the predicate misreads BSD's `ls -I .`, and
as bools it misreads GNU's `ls -w 80 .`. A defer costs one prompt, which
is cheaper than either mismodel. An optional-value flag (`--color`,
legal bare) must stay a bool for the same reason.

**How to apply:** when reasoning about whether a permission-gate flag
model can fail OPEN, find the function that builds the operand list
before assuming the flag scanner feeds it. And treat "a guard whose
comment inverts its own rationale" as a live defect class here: the next
maintainer avoids a correct change believing they are holding a hole
shut.

Related: [[permission-gate-read-only-utility-allow-hides-carve-outs]],
[[pin-a-specs-empirical-premise-with-a-live-test]],
[[verify-a-predicted-verdict-before-implementing-it]].
