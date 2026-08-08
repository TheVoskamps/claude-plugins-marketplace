---
name: measure-the-declared-safe-counter-case
description: When a fix's prose names a sibling as the safe counter-case ("X is right to read the merged document, nothing reaches it"), probe THAT sibling — the round measured only what it changed
metadata:
  type: feedback
---

A round that fixes gate A almost always leaves a sentence declaring sibling
gate B safe, with a structural reason. Probe B. The round measured A.

**Why:** PR #243 (claude-vm, issue #135) fixed two presence gates and, in the
same prose, asserted `claude_vm_mount_mode_entries` "asks a merged document and
is right to: `mode:` sits inside a list *element*, which neither prune pass can
reach." That was on four surfaces (CLAUDE.md, `payload/README.md` twice,
`lib/config.sh` header, and a `config-test.sh` comment) and false: the prune's
second pass is `del(.. | select(tag == "!!map" and length == 0))`, and `..`
descends into list elements, so `mode: {}` is deleted and that config launches
while `mode: ro` / `""` / `[]` / valueless all abort. The entry map is never
empty — true, and the reason everyone stopped reading — but the *value* inside
it can be. Nothing failed: the test fixture carried three spellings and not the
fourth.

**How to apply:** the probe is cheap and beats reading — source the real lib in
a scratchpad script, drive the real merge/normalize function, then call the
real gate, one row per spelling per layer. Do that for the sibling the prose
exempts, not only for the function in the diff. A structural exemption
("inside a list element", "no consumer reaches it", "the parent is never
empty") is a claim about a *recursive* operator's reach — go read the operator's
actual expression, since `..` / `walk` / `select(..)` all cross the boundary the
exemption assumes. Related: [[no-blanket-predicate-over-a-list]],
[[probe-the-gate-binary-not-the-walk]].
