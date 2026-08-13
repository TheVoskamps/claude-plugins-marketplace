---
name: a-negate-check-names-the-test-that-actually-fails
description: "\"Mutation M makes test T fail\" is two claims — that T fails and that no other test does; run the WHOLE package under M and read the FAIL list, because a fault-injection subtest often passes vacuously under the very mutation cited as its control."
metadata:
  type: project
---

A negate-check sentence ("removing arm A makes test T fail, so T does
not pass vacuously") asserts a *set*: T is in the FAIL list, and the
tests you did not name are not. Both halves are settled by one command
— apply the mutation, run the entire package, read the FAIL list —
and both halves were wrong on PR #264 in the same round.

**Why:** a fault-injection test is the shape most likely to go vacuous
under exactly its own control mutation. `TestLoggingFailureChangesNoVerdict_262`
points the gate's log at an unwritable path and asserts each bucket's
verdict survives. Deleting `|| d.Bucket == BucketDefer` from
`main.go`'s log condition — the mutation the PR body cited as its
negative control — means `logEvent` is never called for a defer, so
the defer subtest injects no fault at all and passes green. The
regression is really caught by a different test
(`TestEvolutionLogRecordsEveryNonAllowBucketWithAnalysis_262`, "expected
exactly one log record for a defer; got 0"). Symmetrically, the
"disabling the ranking arm makes ONLY the `residual first` subtest
fail" claim missed `TestGhPublishFileDynamicPathDefers_262`, because
the same arm decides which defer reason wins for an unrelated command.

**How to apply:** never write the negate-check sentence from the test
you were editing. Mutate, `go test ./...` (the package, not `-run
<the-one-test>` — a `-run` filter *cannot* see the second failure),
copy the FAIL list, and let the sentence name what the list names. If
a fault-injection subtest is absent from the list, say what its
control actually covers ("a *wired* bucket's failure is swallowed, not
which buckets are wired") in the test's own comment, so the next
reader does not re-derive the same false claim. Restore the source
with `git checkout -- <file>`; `cp` may be aliased interactive here.
Related: [[negative-control-the-approved-snippet]],
[[delete-the-named-mechanism-to-grade-the-prose]],
[[a-parity-fix-moves-verdicts-in-every-direction]],
[[pr-body-is-a-swept-surface]].
