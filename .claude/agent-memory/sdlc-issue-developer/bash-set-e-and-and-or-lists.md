---
name: bash-set-e-and-and-or-lists
description: Measured, not assumed -- `[ -f x ] && . x` does NOT abort under `set -e` when the test fails, because a failing command other than the last in an AND-OR list is exempt. A negative control caught me writing the opposite claim into a test comment.
metadata:
  type: feedback
---

Rule: before writing "this spelling would abort under `set -e`" (or the
converse) into a comment, run the negative control. `set -e` ignores a failing
command that is part of an AND-OR list **other than the last one**, so
`[ -f missing ] && . missing` mid-script continues silently -- the `if` form is
a legibility choice, not a `set -e` fix.

**Why:** in issue #135 I wrote a boot-launcher test whose comment claimed the
absent-file assertion was load-bearing because the `&&` spelling "returns 1 and
would abort the whole boot". I then rewrote the launcher's guard into the `&&`
form to confirm the test would fail -- and it still PASSED. The behavior claim
was false; the assertion was vacuous for the reason I gave it (it still earns
its place for what it does measure, that the boot tier lands with no baked
file). The test would have shipped a confident, wrong sentence about shell
semantics next to correct code.

**How to apply:** any time a test comment explains WHY a spelling is unsafe,
mutate the code into the unsafe spelling and confirm the test goes red. If it
stays green, either the assertion is vacuous or the explanation is wrong --
find out which before committing. This is the cheap half of
[[permission-gate-tests-can-pass-vacuously]] applied to shell semantics rather
than to overlapping rules.
