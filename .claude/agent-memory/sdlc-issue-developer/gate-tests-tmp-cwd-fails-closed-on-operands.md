---
name: gate-tests-tmp-cwd-fails-closed-on-operands
description: Adding path grading to any permission-gate classifier silently breaks existing tests that use classifyCmd's `/tmp` cwd — containPathOperands fails CLOSED to ASK there, so those rows read ASK for a reason unrelated to what they assert.
metadata:
  type: feedback
---

When you add read/write containment to a permission-gate classifier
that did not have it, sweep the existing tests for rows of that
program carrying a PATH-shaped operand. `classifyCmd` sets
`CWD: "/tmp"`, which is not a git repo, so `resolveRepoContext` errors
and `containPathOperands` returns the no-repo-context **ASK** — before
any path is graded. Move those rows to `classifyInRepo(t, cmd,
repoDir)` with a `gitInit`'d `t.TempDir()`.

**Why:** the failure is asymmetric and only half of it is loud. A row
asserting ALLOW fails visibly (that is how #229 found
`gh gist create f.txt` in two suites). A row asserting **ASK** keeps
passing — for the no-repo-context fail-closed instead of the tier it
was written to prove — so the assertion survives while the coverage
evaporates. `gh gist create --public f.txt` was exactly that: still
ASK, no longer reaching the publish tier at all.

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
