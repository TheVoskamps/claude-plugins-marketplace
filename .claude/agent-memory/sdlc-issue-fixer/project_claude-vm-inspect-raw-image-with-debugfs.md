---
name: claude-vm-inspect-raw-image-with-debugfs
description: how to inspect claude-vm's built guest.raw ext4 partition from a macOS host without loop devices — carve the partition with dd, then debugfs (no -o offset flag in this e2fsprogs build) directly on the carved file.
metadata:
  type: project
---

To positively verify a `payload/build-guest-image.sh --output guest.raw`
build actually contains a given file/package (not just that the build
exit-code was 0), on a macOS host with no ext4 driver and no usable loop
device inside a rootless podman container:

1. Build for real: `payload/build-guest-image.sh --output guest.raw`
   (runs mkosi inside a throwaway podman container per
   `provisioners/podman-mkosi.sh`; takes several minutes).
2. `fdisk -l guest.raw` (inside a `podman run --privileged debian:bookworm`
   container with `fdisk`/`e2fsprogs` apt-installed) to read the GPT
   partition table and find partition 2's start sector (the guest's
   ext4 root — partition 1 is the small vfat ESP).
3. `losetup --find --show -P` fails inside this podman/podman-machine
   setup ("cannot find an unused loop device") — do not fight it.
   Instead carve partition 2 straight out with
   `dd if=guest.raw of=rootfs.img bs=512 skip=<start-sector> count=<sector-count> status=none`.
4. `debugfs -R "stat /usr/bin/apt-get" rootfs.img` and
   `debugfs -R "cat /var/lib/dpkg/status" rootfs.img` read the ext4
   filesystem directly from the plain file — no mount, no loop device.
   This e2fsprogs build (1.47.0) has **no `-o <offset>` flag**; passing
   the whole disk image with an offset does not work, only a raw
   partition-only file does.
5. `debugfs -R "cat /var/lib/dpkg/status" rootfs.img | awk '/^Package: apt$/{f=1} f{print; if(/^$/) exit}'`
   extracts one package's full dpkg record for a definitive
   "installed ok installed" check.

This is the [[real-build-verification-not-unit-tests]] pattern applied
to claude-vm specifically — the host-acceptance.sh acceptance test only
proves the build succeeds and boots; it does not assert package
contents. When a fix is specifically "package X is now baked in," this
debugfs recipe is the way to prove it without a real vfkit boot.

Also note: task-output files under
`/private/tmp/claude-*/.../tasks/*.output` (from `run_in_background`)
are OUTSIDE the repo and both `Read` and `Bash` (cat/grep) refuse them
by the repo-boundary gate. Redirect background-command output into a
repo-scoped `.claude/tmp/` path instead if you need to read it back.
