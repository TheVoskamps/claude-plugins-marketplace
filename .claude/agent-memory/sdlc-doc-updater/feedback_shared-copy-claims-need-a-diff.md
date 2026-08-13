---
name: shared-copy-claims-need-a-diff
description: "\"Only the bullets are shared copy\" is a diff result, not a reading — a per-agent framing paragraph can still end in a byte-identical sentence, and a counted \"the four bullets\" rots."
metadata:
  type: feedback
---

A sweep rule of the form "in these twin sections, only X is shared
copy and must stay byte-identical; the prose around it is deliberately
per-agent" is a claim about the whole section. Settle it with `sed` +
`diff` over both slices before writing or leaving it.

**Why:** on #259 CLAUDE.md said only the gloss bullets in
`theorem-disprover` / `counterexample-verifier` → "The consequence
classes" were shared. The bullets were byte-identical, but the
"per-agent" closing paragraphs also *ended* in one identical sentence
(severity is the pipeline's business) at a different line wrap. A
future sweep trusting the rule would have changed that sentence in one
file only — precisely the drift the rule exists to prevent.

**How to apply:** slice both sections to scratch files, `diff` them,
and let the diff hunks decide which sentences the rule calls shared
and which per-agent — line wrapping hides identity, so read the hunk
boundaries, not the line numbers. Also drop any count from the claim
("the four gloss bullets"): the same CLAUDE.md section says adding a
class edits these files, so the tally rots on the next class.
Related: [[carve-out-leaves-absolute-attributions]],
[[no-blanket-predicate-over-a-list]].
