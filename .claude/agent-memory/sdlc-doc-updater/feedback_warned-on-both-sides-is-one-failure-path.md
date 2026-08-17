---
name: warned-on-both-sides-is-one-failure-path
description: "warned on the host and again in the guest" is a claim about where a failure lands, not about how many warning strings exist; trace what the failing side does with the entry before letting it stand.
metadata:
  type: feedback
---

When a feature has two halves across a seam — a host stage step and a guest
install step, a producer and a consumer — prose written for it tends to
collapse both warnings into one sentence: "a copy that fails is warned about
loudly, on the host and again in the guest hvc0 log."

Grep confirms two warning strings exist, and the sentence still misreads:
each side warns only about **its own** failure. In claude-vm issue #108 a
host staging failure `rm -rf`s the partial entry, so the guest never sees it
and says nothing about it; the guest's warning fires only when the copy off
the mount fails. Nothing is ever reported twice.

**Why:** "and again" asserts one failure produces two reports, which is a
claim about the failing side's *recovery path*, not about the count of
warning statements. A reader debugging a missing `rules/` in the guest will
scan the guest log for a warning that structurally cannot be there.

**How to apply:** on any two-halves feature, read what the failing half does
with the artifact — drop it, pass it on partial, or abort — then attribute
each warning to the side that emits it. Same read settles the neighbouring
"nothing here can abort" claim: check that every copy is `||`-guarded, since
an unguarded `mkdir -p` under the launcher's `set -euo pipefail` would abort
the boot the sentence promises it cannot.
