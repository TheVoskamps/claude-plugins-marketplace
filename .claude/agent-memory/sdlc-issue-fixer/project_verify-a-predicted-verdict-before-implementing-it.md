---
name: verify-a-predicted-verdict-before-implementing-it
description: An issue's acceptance bullets often PREDICT what existing code does ("X defers"); measure each predicted verdict against the real binary first, implement the stated rule uniformly, and report divergences instead of bending the code to match the prediction
metadata:
  type: project
---

Issue bodies in this repo get rewritten across fixer rounds, and their
acceptance bullets mix two different kinds of claim: the **rule** the
change must implement, and the author's **prediction** of what verdict
that rule produces for each case. The rule is authoritative; a
prediction is a claim about existing code and can be wrong.

**Why:** on #193 / PR #208 round 4 the bullet read "`cat < <in-repo>`
behaves exactly as `cat <in-repo>`" (a rule) alongside
"`cat < ~/.claude/CLAUDE.md` defers" and "`cat < $UNRESOLVED` defers"
(predictions). Measured: the operand forms ALLOW and (as of #262) DEFER
respectively — the second read ASK when measured, before #262 rebucketed
the unresolvable-path arms — because the curated read-utility track's
terminal for any contained-or-carved-out operand is an allow, and a
path-bearing utility fail-closes on a dynamic path. Implementing the predictions would
have required special-casing one carve-out for redirects only — the very
"two spellings of one read carry two verdicts" inconsistency the same
issue condemns elsewhere.

**How to apply:** before writing code for a verdict matrix, run each row
through the current binary (synthetic `PreToolUse` JSON on stdin) and
write the measured value down. Implement the uniform rule, assert the
redirect/alias form **against its own operand form** rather than against
a hardcoded bucket (so the two can never drift whatever either becomes),
and report every divergence from the predicted verdict explicitly in the
hand-back — with the measurement — rather than silently choosing either
side.

Related: [[flagscan-value-flag-swallows-path-operand]],
[[pin-a-specs-empirical-premise-with-a-live-test]],
[[real-build-verification-not-unit-tests]].
