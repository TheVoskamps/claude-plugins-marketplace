---
name: your-change-can-void-a-controls-liveness-anchor
description: A negative control that proves its own harness is live by pinning one still-passing row goes VACUOUS when your change moves that exact row — re-point the liveness half at a row your change does not touch, and check every control whose anchor your diff names.
metadata:
  type: project
---

A well-built negative control has two halves: the claim ("restoring the
old table entry must not restore the old verdict") and a liveness
anchor ("and here is a row that DOES still ride that table, so the swap
is proven to do something"). The anchor is a row your change is
supposed to leave alone. When it is not, the control still compiles,
still passes, and no longer separates anything.

**Why:** on issue #229 / PR #232 the `gist create` control read:

```go
withGistRecoverableWriteVerbs(t, map[string]bool{"create": true, "edit": true})
wantReason(t, …"gh gist create notes.md"…, BucketAsk, …)   // the claim
wantBucket(t, …"gh gist edit abc123 notes.md"…, BucketAllow) // the anchor
```

Round 11 then made every `gh gist edit` an ASK as well. Both lines now
read ASK, so the test passes — while asserting nothing: with the table
row restored and BOTH verbs escalating on an arm above
`isGhRecoverableWrite`, an inert swap helper produces exactly the same
output as a live one. The anchor had to move to `label create`, whose
ALLOW genuinely does come from `ghRecoverableWriteVerbs`, and the
noun-specific helper had to be generalized to take the noun.

The trap is that nothing points at it. `go test` is green, the class of
the change (a verdict move) is not the class of the defect (a control
losing its discriminating power), and the anchor line looks like just
another assertion about the verb you were already editing.

**How to apply:** when a change moves a verdict, grep the test tree for
the command strings your change moves — not only for assertions that
now FAIL, but for the ones that still pass and were carrying a
different claim. A control whose anchor row your diff touches needs a
new anchor, chosen from a row the diff provably does not reach, and the
helper it uses is usually the thing to generalize rather than copy.
When the noun you are emptying has no allowing verb left at all, the
anchor must cross to another noun — which is the signal that the old
control was noun-scoped by accident.

Related: [[negative-control-the-approved-snippet]],
[[a-tier-premise-can-be-a-vendor-fact]],
[[a-parity-fix-moves-verdicts-in-every-direction]].
