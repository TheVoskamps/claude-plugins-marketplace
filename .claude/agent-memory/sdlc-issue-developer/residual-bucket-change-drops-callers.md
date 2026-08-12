---
name: residual-bucket-change-drops-callers
description: Changing the bucket a permission-gate residual arm returns silently moves every call that only reached it by falling through — enumerate those before moving it, because none appear in the diff.
metadata:
  type: project
---

Changing what a **residual** arm of `permission-gate` returns — the
unrecognized-`gh` floor, the no-repo-context arm, an unknown-flag screen —
re-verdicts every call that was reaching it only by FALLING THROUGH. Those
calls have no arm of their own, so none of them appears in the diff and no
test names them.

Issue #262 moved the unrecognized-`gh` floor from `ask` to `defer` and would have
dropped `gh auth token` (which prints the live OAuth token) out of the
credential hard-ask tier. Nothing about `gh auth token` changed; only what
happened to catch it did. The fix was an explicit arm in `classifyGh`'s `auth`
switch, plus a test asserting the REASON — a bucket-only assertion passes
again the moment the arm is deleted and the residual catches it once more.

**Why:** the whole class is invisible to the ordinary review surfaces. The
diff shows one changed bucket; the consequence is spread across every
unenumerated call in the tool's surface.

**How to apply:** before changing a residual's bucket, replay a probe corpus
against the merge-base binary AND the tip binary and diff the verdict columns
(the recipe is in `docs/guardrails-verification-playbook.md` → "Enumerate what
a residual bucket was catching before you move it"). Grade every mover on its
own terms rather than as a consequence of the intended change. Then give a
real arm to anything that was escalating by accident and should still
escalate, and pin it with `wantReason`, not `wantBucket`. Related:
[[aws-gh-acli-credential-read-surface]] for which reads are credential reads,
[[gate-tests-tmp-cwd-fails-closed-on-operands]] for the sibling trap where an
OLD test keeps passing on a residual it was never written to prove, and
[[permission-gate-tests-can-pass-vacuously]] for negate-checking a new one.
