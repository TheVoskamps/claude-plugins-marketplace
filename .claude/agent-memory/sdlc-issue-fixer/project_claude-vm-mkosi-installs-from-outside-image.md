---
name: claude-vm-mkosi-installs-from-outside-image
description: mkosi's apt runs in the build container, NOT the guest image — any recipe that execs apt-get INSIDE the guest at boot needs `apt` explicitly added to the base Packages= list, or it silently has no apt/dpkg tooling.
metadata:
  type: project
---

PR 174 (issue #106) added a boot-time `boot_apt_phase` that execs
`apt-get` INSIDE the guest at boot (for `packages.install_at_boot` /
`packages.update_at_boot`). A real guest boot (human-run, not CI) found
every `apt-get` call failing with "command not found" — confirmed via
`payload/build-guest-image.sh` real image build + `debugfs` inspection
(see [[claude-vm-inspect-raw-image-with-debugfs]]) that the guest
rootfs genuinely had no `/usr/bin/apt`.

**Why:** mkosi's `Packages=` list is installed by mkosi's OWN apt,
running in the build container (`provisioners/podman-mkosi.sh`'s
`build-in-container.sh`), which builds the guest's rootfs from OUTSIDE
it. That build-time apt is never copied INTO the guest image — only the
packages it installs are. So a package baked via `packages.bake` lands
in the guest, but the `apt` binary itself does not, unless it is
ALSO named in the recipe's base `Packages=` list.

**How to apply:** any claude-vm recipe change that adds a boot-time (not
build-time) step needing a specific tool inside the guest must add that
tool's package to the base `Packages=` list in
`provisioners/podman-mkosi.sh` (around the `[Content]` `Packages=`
block), not assume mkosi's build-time toolchain leaks into the guest.
Bake it unconditionally if the boot-time feature it serves has a
default-on config knob (as `update_at_boot: true` does here) — gating
the package on "is this feature configured" just reproduces the same
bug for the default-off-but-flippable case. Bumping in
`LAUNCHER_LOGIC_REV` (see `build-guest-image.sh`) is required to
invalidate already-built cached images — the base `Packages=` list is
NOT covered by the separate bake-hash mechanism
(`packages.bake`/`packages.apt_sources` only).
