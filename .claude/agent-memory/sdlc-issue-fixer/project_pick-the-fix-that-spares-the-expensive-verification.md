---
name: pick-the-fix-that-spares-the-expensive-verification
description: When a finding admits several fix shapes and the PR's strongest evidence came from an expensive run you cannot repeat, prefer the shape that leaves that already-verified path byte-identical and confines the change to the unverified branch
metadata:
  type: project
---

A review finding often lists more than one acceptable remedy. Cost of
*re-verification* is a legitimate tie-breaker, and in claude-vm it is
usually the deciding one, because the only real evidence for guest
behavior is a real image build plus a real vfkit boot (see
[[real-build-verification-not-unit-tests]] and Edwin's
`unit-tests-are-not-real-runs`), and a fixer round rarely gets to redo
the developer's full manual boot matrix.

**Worked instance (PR #231, wrap-dir siting).** The wrap directory held
a hard link to the operator's file and sat under `$RUN`, which is inside
the rw repo share under `repo.mount: live`. Options were: (a) branch —
keep `$RUN` for `clone`, use a non-shared dir for `live`; (b) always
move it out; (c) refuse single-file mounts under `live`. (b) is fewer
lines, but `clone` is the default and the mode the PR's real-boot
acceptance table exercised, so (b) would have invalidated the one piece
of expensive evidence the PR had. (a) confines the change to the branch
that was never verified anyway and leaves the verified path
byte-for-byte unchanged. (c) was rejected because it removes a
legitimate feature rather than fixing it.

**How to apply:** before choosing among remedies, ask which paths the
PR's existing strong evidence covers, and whether your candidate
disturbs them. Then say so explicitly — in the code comment, in the PR
body ("clone mode, the default, is byte-for-byte unchanged"), and in the
report — so the reviewer can see that the untouched path's evidence
still stands rather than having to re-derive it.

Write the branch condition against the **resolved value** rather than
the config knob: testing `$RUN` against `$MOUNT_SHARED_DIR` (what is
actually shared) instead of against `repo.mount` survives a later change
of mount strategy, and it stayed correct for the non-git-source case the
knob alone would have mis-answered. Same idea as
[[stand-in-arm-invalidates-the-sibling-lists-definition]].
