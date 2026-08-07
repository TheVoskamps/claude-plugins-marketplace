---
name: widened-guard-narrow-prose
description: When a guard is widened from equality to a relation (overlap, prefix, range), the prose at the guard and in the docs gets updated but the RATIONALE comments on each reserved value it protects still spell the old narrow case.
metadata:
  type: feedback
---

A PR that widens a check — string equality to an overlap/ancestor
relation, a value to a range — updates the function header, the error
strings and the doc surfaces. What it leaves behind is the prose sitting
next to each *item the guard protects*, which explains why that item is in
the guarded set and does so in the pre-widening vocabulary.

**Why:** issue #157 widened claude-vm's reserved-mountpoint guard from `=`
to `claude_vm_guest_paths_overlap` (equal, above, or below) in the same
commit that added `CLAUDE_VM_GUEST_WRAP_MOUNT` to the reserved set — and
both comments introducing that constant (`lib/config.sh`, and its restated
twin in `build-guest-image.sh`) said the validator rejects a `path:`
landing on it "or above it". Below was rejected too. Nothing tests a
comment, and the doc surfaces were all correct, so the narrow spelling
reads as a deliberate scoping rather than a leftover.

**How to apply:** after a widening, grep for the *narrow* relation's
vocabulary ("equal to", "the same as", "lands on", "or above") near every
member of the guarded set, not just at the guard. Then decide per hit
whether the code really is narrower there or the prose is stale — run the
predicate against a case in the newly-covered direction rather than
reasoning it out. Related: [[diagnostic-detail-claims]].
