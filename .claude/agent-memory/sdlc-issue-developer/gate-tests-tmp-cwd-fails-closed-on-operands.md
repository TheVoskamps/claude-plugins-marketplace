---
name: gate-tests-tmp-cwd-fails-closed-on-operands
description: Adding path grading to any permission-gate classifier silently breaks existing tests that use classifyCmd's `/tmp` cwd — containPathOperands hits the no-repo-context residual (DEFER since #262) there, so those rows read that bucket for a reason unrelated to what they assert.
metadata:
  type: feedback
---

When you add read/write containment to a permission-gate classifier
that did not have it, sweep the existing tests for rows of that
program carrying a PATH-shaped operand. `classifyCmd` sets
`CWD: "/tmp"`, which is not a git repo, so `resolveRepoContext` errors
and `containPathOperands` returns the no-repo-context residual — an
**ASK** before #262, a **DEFER** since — before any path is graded.
Move those rows to `classifyInRepo(t, cmd, repoDir)` or
`classifyCmdInRepo(t, cmd, subagent)`, both of which `gitInit` a
`t.TempDir()`.

**Why:** the failure is asymmetric and only half of it is loud. A row
asserting ALLOW fails visibly (that is how #229 found
`gh gist create f.txt` in two suites). A row asserting the residual
bucket keeps passing — for the no-repo-context arm instead of the tier
it was written to prove — so the assertion survives while the coverage
evaporates. `gh gist create --public f.txt` was exactly that: still
ASK, no longer reaching the publish tier at all.

Since #262 this is WORSE, not better. The residual is now `defer`,
which is also the honest verdict for the whole judgment middle, so a
row landing there looks plausible where the old `ask` looked odd. #262
hit it directly: `TestGhAPIRedirectToFileAsks_113` asserted a redirect
verdict under `/tmp`, and the redirect never got graded at all — the
unresolvable-boundary arm answered first.

**How to apply:** on any change that puts new operands through
containment. Grep the test tree for the program name, and for every
row whose command carries an operand, either move it in-repo or pin the
reason (`wantReason`) so a bucket-only pass cannot hide the swap. This
is the sibling of [[permission-gate-tests-can-pass-vacuously]]: that one
is about a NEW test passing without reaching the new code, this one is
about an OLD test continuing to pass after the code moved out from
under it.

Contrast [[permission-gate-origin-aware-rules-need-real-cwd]], where the
`/tmp` cwd fails **OPEN** (the origin lookup fails, the scoping is
skipped, the command allows). Containment fails CLOSED. Same missing
prerequisite, opposite direction — so you cannot reason about "the
`/tmp` cwd" in general; check which way the rule under test degrades.
