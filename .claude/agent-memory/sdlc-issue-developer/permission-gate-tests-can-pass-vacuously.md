---
name: permission-gate-tests-can-pass-vacuously
description: A new permission-gate test can pass for the wrong reason (another rule already produced the same bucket); negate the new condition and confirm the test fails before trusting it.
metadata:
  type: feedback
---

Before trusting a new permission-gate test, temporarily negate the
condition it is supposed to exercise (e.g. `if hs := harnessScratchRoot();
false && ...`), re-run just that test, and confirm it fails — then revert.

**Why:** the gate stacks many rules that produce the SAME bucket for a
given event, so a new test can pass without ever reaching the new code.
A carve-out test asserting "must not DENY" is the worst case: a path can
be non-denied because an unrelated earlier rule ALLOWed it, or because
the classifier never dispatched to the branch under test at all. The
assertion is satisfied and the new rule is never exercised. Nothing in
the output distinguishes that from a real pass.

**How to apply:** on any change to `testContainmentFrom`'s verdicts, a
`classify*` switch arm, or a rule predicate. The revert is the whole
risk, so do the negate/run/revert as three tight steps and re-run the
full suite afterwards. Count the failures: on #193 the negated build
failed 14 assertions across both path spellings and both tool classes,
which is itself the signal that the test covers what it claims. A single
failure where you expected many means the test is thinner than intended.

Pair this with the binary-level probe in
[[permission-gate-self-hosting]]: the negate-check proves the TEST is
real, the synthetic-event probe proves the COMPILED BINARY behaves.
Neither substitutes for the other — `go test` runs the source, but the
committed binary is what actually gates tool calls.
