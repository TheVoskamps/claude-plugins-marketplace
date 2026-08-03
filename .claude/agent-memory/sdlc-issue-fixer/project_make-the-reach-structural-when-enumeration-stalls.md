---
name: make-the-reach-structural-when-enumeration-stalls
description: When successive review rounds each find one more instance of "the walk misses position X", stop adding call sites — replace the hand-listed enumeration with a traversal, and pin it with a count-equality test rather than a row list
metadata:
  type: project
---

When a review round hands you "you closed one more instance of the same
class", and the round before it said the same thing, the enumeration is
the defect. Stop adding call site N+1: rewrite the mechanism so its
reach is a property of the **traversal** rather than of a list a human
has to keep complete.

**Why:** guardrails #225 wired `descendProcSubsts` to argv (round 0),
then to redirect words (round 1), and round 2 still found `for f in
<(cmd)`, `case <(cmd) in`, the `case`-PATTERN position, and `x=<(cmd)`
ungraded — every one of them an allow on a command the gate never
looked at. Taking a `syntax.Node` and finding the substitutions with
`syntax.Walk` (stopping at any nested `*syntax.Stmt`, which the main
walk reaches on its own) closed argv, redirects, item lists, `case`
words and patterns, assignment RHSs, array elements, inline
`FOO=<(…) cmd` prefixes, declaration clauses and `[[ … ]]` operands in
one call — including three positions no round had thought to list.

**How to apply:**

- Make the invariant testable as an EQUALITY, not a row list: count
  what the parser reports (`syntax.Walk` + type assertion) and what the
  walk graded, and assert they match over a corpus. A row list only
  ever pins the positions someone already thought of; the equality
  fails on the next one. Keep the verdict rows too — they are what says
  the change is behavioral — but the equality is the guard that
  converges.
- State every deliberate exception in the test itself, with the reason
  and its blast radius (on #227: an argv-position `$(…)` body is not
  descended into, which is a different class and only ever DEFERS,
  asserted right there).
- Ask whether the wider reach needs a scope guard: a `<(…)` / `$(…)`
  runs in a CHILD shell, so newly-walked inner statements must not
  record assignments or `cd`s into the enclosing program's state.
  Reaching more places multiplies whatever the descent already got
  wrong.
- Where the descent runs matters as much as what it covers: on #227 it
  had to precede the redirect-only fallback's emitted-command capture,
  or `[[ -f <(echo hi) ]] > out.log` lost its write grading. Prove that
  ordering claim by moving the call and watching the assertion fail.

Related: [[project_probe-the-parser-ast-not-the-grammar]] for measuring
which positions exist, [[feedback_negative-control-the-approved-snippet]]
for proving the new test fails pre-fix, and
[[project_sweep-sibling-agent-guards]] for the prose half — a closed gap
means deleting the "known gap" sentence from every surface that carried
it, code comment, README and agent-memory note alike.
