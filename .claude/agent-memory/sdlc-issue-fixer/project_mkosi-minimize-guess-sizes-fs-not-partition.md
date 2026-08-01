---
name: mkosi-minimize-guess-sizes-fs-not-partition
description: in mkosi offline repart, Minimize=guess sizes the ext4 FILESYSTEM to tight-fit while SizeMinBytes only pads the GPT PARTITION slot; the extra partition space is dead/unformatted and invisible to the guest's df — so a headroom floor via SizeMinBytes+Minimize=guess is inert
metadata:
  type: project
---

Issue #106 / PR #174 root-headroom bug, proven by inspecting a real
built `guest-2973831d.raw` (launcher14, the buggy tip) directly, not by
theory:

- GPT partition entry for `root-arm64`: **1924 MiB** (= BASE_ESTIMATE_MB
  900 + headroom 1024, i.e. `SizeMinBytes=1924M` WAS applied to the
  partition slot).
- ext4 superblock INSIDE that partition: total 1041 MiB (723 used + 317
  free). The **filesystem** is tight-fit to mkosi's measured minimal
  (~1G), NOT grown to fill the 1924 MiB slot.

So ~883 MiB of the partition is beyond the filesystem — unformatted
dead space the running guest cannot use. The guest's `df` sees a 1041
MiB fs with ~317 MiB free (≈ the "991 MB, headroom inert" the human
reported). The old comment "SizeMinBytes composes with Minimize=guess
as 'the larger of the two wins'" is BACKWARDS for the FILESYSTEM: with
mkosi offline repart, `Minimize=guess` sizes the ext4 filesystem to
tight-fit content; `SizeMinBytes=` only enlarges the GPT partition
entry around it. The two operate on different objects (fs vs slot), not
on one value that takes a max.

**Fix (agreed with human):** DROP `Minimize=guess` on the root
partition. With Minimize unset and `Format=ext4`+`CopyFiles=/`+
`SizeMinBytes=<floor+headroom>`, mkosi/systemd-repart sizes the ext4
filesystem to the SizeMinBytes floor (the fs fills the slot), so the
headroom becomes real free space the guest can use.

**How to verify:** parse the GPT (partition slot size) AND the ext4
superblock (s_blocks_count * block_size = fs size) SEPARATELY from the
built `.raw`. They must now AGREE (fs fills partition). Pure-python
GPT + ext4 superblock parse works on macOS with no mount — see the
fixer's scratch scripts. `debugfs`/mount is unavailable on the macOS host, so
this offset-parse is the portable inspection path.
