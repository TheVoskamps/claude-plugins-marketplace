---
name: stand-in-arm-invalidates-the-sibling-lists-definition
description: When one arm of a resolution SUBSTITUTES a value for the caller's input, any auxiliary list defined as "input minus X" silently contradicts that arm — define it against the RESOLVED value, and catch it by transcribing the spec's own worked examples
metadata:
  type: project
---

Writing the reconciliation contract for
`git-tools:git-issues-from-branch` (issue #223 / PR #224), the spec
had a resolved set plus two derived lists, defined the obvious way:

- *claimed outside the branch set* = `C \ B`
- *branch members not claimed* = `B \ C`

`B \ C` is wrong. One arm of the resolution — "no overlap and `B` has
exactly one member, so the branch set **stands in** for the claim" —
replaces `C` entirely. With `B = {206}` and `C = {310}` the resolved
set is `{206}`, but `B \ C` still reports `206` as *not claimed*. The
consumers act on that list: `pr-create` would write "deferred #206"
into a body whose only closing line is `Closes #206`, and
the review pipeline would file a High against the very issue it is
reviewing. The correct definition is `B \ resolved`, which collapses
to `B \ C` on the ordinary overlap arm and to `∅` on the stand-in arm.
Its sibling stays `C \ B` — computed against the claim **as passed**,
so the stand-in does not hide a rogue number the consumers must still
refuse.

**Why:** an auxiliary list is almost always written while thinking
about the *main* arm, where input and resolved value coincide. Any arm
that substitutes, defaults, falls back, or stands in breaks that
coincidence, and nothing in the prose flags it — the definition and
the arm sit in different bullets and each reads fine alone.

**How to apply:** when a spec has a resolution with more than one arm
plus derived lists, re-read every list's definition once **per arm**,
asking "does this arm change what the input means?". Then transcribe
the documented steps into a throwaway script under `.claude/tmp/` and
render each of the spec's own Output examples, comparing
byte-for-byte with the line written in the file — that is what caught
this one: the stand-in example's documented output said
`branch members not claimed: (none)` while the definition computed
`206`. The examples were right and the definition was wrong, which is
the usual direction (examples get written by walking one case, the
definition by generalizing from one case). Related:
[[verify-a-predicted-verdict-before-implementing-it]],
[[pin-a-specs-empirical-premise-with-a-live-test]].
