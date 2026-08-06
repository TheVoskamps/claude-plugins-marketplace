---
name: measure-the-quantifier-in-your-own-premise
description: A finding's "nothing else reaches X / this is the only member" premise is a measurable claim about the rest of the system — measure it before filing, because a fixer will build prose, placement and a CLAUDE.md rule on it
metadata:
  type: feedback
---

When a finding's recommendation rests on an **exclusivity premise** — "this
is the only member an operator can hit", "no other caller touches that path",
"checking earlier would refuse a launch that would otherwise work" — measure
the premise with the same rigour as the defect. It is a universally quantified
claim about code outside the diff, so it is falsifiable in one enumeration,
and it is the part a reviewer is most tempted to reason out instead.

**Why:** on PR #231 round 5 I filed a real Low (the single-file wrap dir rides
`sharedDir=` unchecked) and attached the premise "in the git-repo +
`repo.mount: live` shape no built-in device touches `$TMPDIR`". The next round
enumerated every vfkit argument and found `virtio-net,unixSocketPath=` is a
`mktemp -d` under `$TMPDIR` on every launch. The defect survived; the *stated
benefit* did not — the guard is an earlier cause-naming abort, never a rescue
— and my placement recommendation ("check at the `$MOUNT_WRAP_DIR`
assignment") was argued from the false premise. Three doc surfaces plus a
CLAUDE.md authoring rule had to be reshaped around the correction, and a
fixer, a doc-updater and a review round were spent on it. Cost of measuring
first: one `grep -n -- '--device'` and five throwaway `vfkit` invocations.

**How to apply:** before the finding goes in, write the premise as a sentence
with an explicit quantifier ("no X", "the only X", "every X"), then run the
enumeration that would refute it — `grep` the one construct it quantifies
over, and feed the edge value to the real consumer. If you cannot enumerate
it, drop the premise from the finding rather than hedging it; the defect
usually stands on its own. When a later round *does* refute one of yours, say
so plainly at the top of the next review and re-verify the correction
first-hand — the fixer is usually right (see
[[regrade-own-verified-and-check-round-narratives]]), and confirming it with
your own measurement is what makes the round cheap.

Related: [[slice-the-real-launcher-loop-to-probe-emissions]] (the emission
that carried this premise), [[vfkit-is-installed-probe-it-directly]],
[[re-review-the-whole-diff-fresh]].
