#!/usr/bin/env bash
#
# podman-mkosi.sh -- the BUNDLED DEFAULT claude-vm image provisioner.
#
# Contract (the same one CLAUDE_VM_IMAGE_PROVISIONER overrides honor):
#
#   podman-mkosi.sh <boot-launcher-path> <output-image-path>
#
#   $1  boot-launcher-path  -- the boot launcher script build-guest-image.sh
#                             emitted. Wired into the guest as the autologin
#                             serial-getty@hvc1 login program (issue #88).
#   $2  output-image-path    -- where to write the raw, EFI-bootable guest
#                             image. vfkit boots this with --bootloader efi.
#
# It produces a raw, EFI-bootable Debian guest with the boot launcher wired as
# the autologin serial-getty@hvc1 login program (so claude becomes the
# interactive hvc1 console session -- issue #88), by running mkosi inside a
# THROWAWAY rootless
# podman container. mkosi is Linux-only, so it cannot run on the macOS host
# directly; podman (already installed for gvproxy) provides the Linux
# kernel via podman-machine, and a throwaway container provides the mkosi
# toolchain.
#
# Why this is the default (see issue #57 for the full analysis):
#
#   - vfkit / Apple Virtualization Framework accept ONLY a raw disk image
#     (no qcow2) and boot it directly via --bootloader efi. mkosi
#     Format=disk + Bootable=yes + a systemd-boot EFI bootloader hits both
#     constraints.
#   - mkosi defaults to RepartOffline=yes: systemd-repart builds the disk
#     image WITHOUT loopback devices. No /dev/loopX, no loop-device step.
#     This is load-bearing on macOS, where podman-created loop devices are
#     not visible inside the container. The container is run --privileged
#     (see issue #71, Bug 1): mkosi's build sandbox needs to
#     unshare(CLONE_NEWNS) and mount a fresh devpts, which a default
#     rootless container's capability/mount posture forbids. --privileged
#     is about the sandbox-setup path, NOT loop devices -- the build stays
#     loop-device-free via RepartOffline=yes.
#   - The only two cases that force RepartOffline=no (btrfs Subvolumes=,
#     SELinux+XFS root) are recipe choices we control and do NOT make: the
#     guest root is plain ext4, no subvolumes, no SELinux.
#   - mkosi's offline systemd-repart needs systemd >= 254. Debian Bookworm
#     (12, systemd 252) is too old, so the BUILD CONTAINER is Debian Trixie
#     (13, systemd >= 257). The GUEST distro stays on the debian-12 pin
#     (passed in via CLAUDE_VM_BASE_OS_REV) -- a normal mkosi cross-release
#     build. Build container and guest distro are decoupled.
#
# This provisioner does a real image build and therefore requires podman
# (with a started podman machine) on the host. It is the default, but
# CLAUDE_VM_IMAGE_PROVISIONER still overrides it: build-guest-image.sh
# prefers an explicit override and falls back to this script.

set -euo pipefail

BOOT_LAUNCHER="${1:?usage: podman-mkosi.sh <boot-launcher-path> <output-image-path>}"
OUTPUT_IMAGE="${2:?usage: podman-mkosi.sh <boot-launcher-path> <output-image-path>}"

# Baked packages + third-party apt repos (issue #105). build-guest-image.sh
# exports the CANONICAL bake config (order-/key-normalized JSON, from
# claude_vm_bake_config_json) as CLAUDE_VM_BAKE_CONFIG. Empty/unset means no
# baked packages -- the recipe is exactly the legacy base image. When present,
# the in-container build step (below) parses it to: (a) extend the mkosi
# Packages= list with packages.bake, and (b) render each packages.apt_sources
# entry into a keyring + sources.list.d drop-in in the mkosi SANDBOX TREE, so
# mkosi's apt can install baked packages that come from third-party repos.
# An unset/empty value is normalized to the empty canonical form so the
# in-container parser always sees valid JSON.
BAKE_CONFIG="${CLAUDE_VM_BAKE_CONFIG:-}"
if [ -z "$BAKE_CONFIG" ]; then
  BAKE_CONFIG='{"bake":[],"apt_sources":[]}'
fi

# Root partition headroom (issue #106 real-run fix). build-guest-image.sh
# resolves image.root_headroom_mb (default 1024, see
# lib/config.sh's CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB) and exports it as
# CLAUDE_VM_ROOT_HEADROOM_MB; it also validates it as a positive integer, so
# this is defense-in-depth, not the primary guard.
ROOT_HEADROOM_MB="${CLAUDE_VM_ROOT_HEADROOM_MB:-1024}"
case "$ROOT_HEADROOM_MB" in
  ''|*[!0-9]*)
    echo "podman-mkosi: CLAUDE_VM_ROOT_HEADROOM_MB must be a positive integer (MiB), got '$ROOT_HEADROOM_MB'" >&2
    exit 1
    ;;
esac

# The guest Debian release. build-guest-image.sh exports BASE_OS_REV as
# CLAUDE_VM_BASE_OS_REV so the guest pin is owned by the build recipe, not
# duplicated here. BASE_OS_REV looks like "debian-12-20250601"; the middle
# field is the numeric Debian release ("12").
#
# mkosi must be given the SUITE NAME ("bookworm"), NOT the numeric release.
# mkosi 25.3/26 do NOT map a numeric Debian Release to the suite for the
# apt mirror path: Release=12 requests deb.debian.org/debian/12/Release ->
# 404 (no Release file). So we map the numeric release to its suite name
# below (issue #71, Bug 2).
BASE_OS_REV="${CLAUDE_VM_BASE_OS_REV:-debian-12}"
# Extract the numeric release (the field between the distro and the date).
# "debian-12-20250601" -> "12"; "debian-12" -> "12".
GUEST_RELEASE_NUM="$(printf '%s\n' "$BASE_OS_REV" | sed -E 's/^debian-([0-9]+).*/\1/')"
if ! printf '%s\n' "$GUEST_RELEASE_NUM" | grep -qE '^[0-9]+$'; then
  echo "podman-mkosi: could not parse a numeric Debian release from BASE_OS_REV='$BASE_OS_REV'" >&2
  exit 1
fi

# Map the numeric Debian release to the apt suite name mkosi requires.
case "$GUEST_RELEASE_NUM" in
  11) GUEST_SUITE="bullseye" ;;
  12) GUEST_SUITE="bookworm" ;;
  13) GUEST_SUITE="trixie" ;;
  *)
    echo "podman-mkosi: no known Debian suite for numeric release '$GUEST_RELEASE_NUM' (BASE_OS_REV='$BASE_OS_REV')" >&2
    exit 1
    ;;
esac

# Build container: Debian Trixie carries systemd >= 254, required for
# mkosi's offline (loop-device-free) systemd-repart path.
BUILD_CONTAINER_IMAGE="${CLAUDE_VM_MKOSI_BUILD_IMAGE:-docker.io/library/debian:trixie}"

# ---------------------------------------------------------------------
# Preflight: podman must be installed and a machine running. mkosi runs
# INSIDE the container, so it is not a host requirement.
# ---------------------------------------------------------------------
if ! command -v podman >/dev/null 2>&1; then
  echo "podman-mkosi: 'podman' is required (brew install podman) but was not found on PATH." >&2
  exit 1
fi
# A rootless podman build on macOS needs a started podman machine (it
# supplies the Linux kernel). Probe it; a clear message beats an opaque
# mid-build failure.
if ! podman info >/dev/null 2>&1; then
  echo "podman-mkosi: 'podman info' failed -- is a podman machine started? Try 'podman machine init && podman machine start'." >&2
  exit 1
fi

[ -f "$BOOT_LAUNCHER" ] || { echo "podman-mkosi: boot launcher not found: $BOOT_LAUNCHER" >&2; exit 1; }

OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_IMAGE")" && pwd)"
OUTPUT_BASE="$(basename "$OUTPUT_IMAGE")"

# ---------------------------------------------------------------------
# Stage an mkosi recipe tree in a throwaway dir, mounted into the build
# container. The recipe is the exact one resolved in issue #57:
#
#   Format=disk        raw GPT block image (only format AVF/vfkit accepts)
#   Bootable=yes       installs an EFI bootloader + ESP partition
#   Bootloader=systemd-boot   EFI boot -> vfkit --bootloader efi
#   Distribution=debian / Release=<pin>   matches the guest version pin
#   RepartOffline=yes  (default) no loop devices -> runs in the container
#
# The guest root is plain ext4, no subvolumes, no SELinux -- neither
# RepartOffline=no trigger fires.
# ---------------------------------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-mkosi.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT INT TERM

mkdir -p "$STAGE/recipe/mkosi.extra/usr/local/lib/claude-vm"
mkdir -p "$STAGE/recipe/mkosi.extra/etc/systemd/system"
mkdir -p "$STAGE/recipe/mkosi.extra/etc/systemd/network"
mkdir -p "$STAGE/out"

# ---------------------------------------------------------------------
# Guest apt metadata diet (issue #106 real-run fix).
#
# A real guest boot hit ENOSPC twice in one session on the 991 MB root
# (~850 MB base usage): boot_apt_phase's `apt-get update` was re-materializing
# ~163 MB under /var/lib/apt/lists PLUS ~88 MB of pkgcache.bin/srcpkgcache.bin
# on every boot (packages.update_at_boot defaults true). Root cause, verified
# against mkosi v26's actual Debian installer (mkosi/distribution/debian.py):
# left to its own defaults, mkosi writes a `<suite>.sources` file with
# `Types: deb deb-src` for FOUR repo stanzas (main, debian-debug, updates,
# security) into the GUEST image itself (install_apt_sources() targets
# etc/apt/sources.list.d/<release>.sources with for_image=True) -- none of
# which this recipe ever asked for; we install pre-built binary packages
# only, never build from source, and never need debug symbols in the guest.
#
# Fix: pre-empt mkosi's own write. install_apt_sources() only writes when
# `not sources.exists()` -- mkosi.skeleton/ is copied into the OS tree BEFORE
# the package manager (and its sources file) is set up (unlike mkosi.extra/,
# which lands AFTER package installation and would be too late to affect
# apt's OWN traffic during the mkosi build). Placing our own binary-only,
# no-debug .sources file at the same path under mkosi.skeleton/ means mkosi's
# installer sees the file already exists and never overwrites it -- so the
# GUEST'S OWN sources.list.d entry point (used by boot_apt_phase and any
# later interactive apt-get) is main+updates+security, deb only, from the
# start. This does not touch the BUILD CONTAINER's own apt sources (which
# mkosi computes separately via cls.repositories(context) with
# for_image=False, unaffected by this file) -- only the image mkosi produces.
#
# Also drop Acquire::Languages "none" (skips Translation-* downloads --
# verified ~32 MB of the 163 MB lists total) and disable the persistent
# pkgcache.bin/srcpkgcache.bin (Dir::Cache::pkgcache/srcpkgcache "") via an
# apt.conf.d drop-in, mirroring standard container practice (empirically the
# same knobs debuerreotype/Docker's official debian images use for this exact
# problem -- confirmed by inspecting a debian:bookworm image's own
# /etc/apt/apt.conf.d/docker-clean). Placed under mkosi.skeleton/ (not
# mkosi.extra/) so it is present in the image's /etc/apt/apt.conf.d from
# before mkosi's own install_packages() step runs -- guaranteeing it governs
# boot_apt_phase and any later interactive apt-get inside the GUEST. Whether
# it ALSO influences mkosi's own build-container apt run (which uses an
# explicit -o Dir::Cache=/var/cache/apt / Dir::State::lists=... invocation
# targeting the sandbox, not this file -- see installer/apt.py's Apt.cmd) is
# NOT relied upon here; that apt run's own cache is discarded with the
# throwaway build container regardless, so it does not affect guest disk.
mkdir -p "$STAGE/recipe/mkosi.skeleton/etc/apt/sources.list.d" \
         "$STAGE/recipe/mkosi.skeleton/etc/apt/apt.conf.d"
cat > "$STAGE/recipe/mkosi.skeleton/etc/apt/sources.list.d/${GUEST_SUITE}.sources" <<SOURCES
Types: deb
URIs: http://deb.debian.org/debian
Suites: $GUEST_SUITE
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: ${GUEST_SUITE}-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: ${GUEST_SUITE}-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES
cat > "$STAGE/recipe/mkosi.skeleton/etc/apt/apt.conf.d/99claude-vm-diet.conf" <<'DIET'
// claude-vm apt metadata diet (issue #106 real-run fix). Skips Translation-*
// list downloads (unused; ~32 MB of a stock Debian lists set) and disables
// the persistent binary package caches (regenerated on every apt-get call;
// ~88 MB) so the guest's per-boot apt working set stays small on the small
// (headroom-constrained) root partition. boot_apt_phase's `apt-get clean`
// still removes any .deb archives fetched by an install; this drop-in means
// there is no pkgcache.bin/srcpkgcache.bin for clean to need to remove.
Acquire::Languages "none";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
DIET

# ---------------------------------------------------------------------
# Root partition headroom (issue #106 real-run fix, new feature).
#
# A real guest boot hit ENOSPC twice in one session on the previously
# auto-sized root: with NO mkosi.repart/ directory of our own, mkosi
# generates its OWN default partition definitions (verified against mkosi
# v26's actual make_disk(), mkosi/__init__.py) -- a 512M ESP (00-esp.conf,
# Type=esp/Format=vfat/SizeMinBytes=SizeMaxBytes=512M, no BIOS boot partition
# since this recipe has no grub-bios) and a root partition (10-root.conf,
# Type=root/Format=ext4/CopyFiles=//Minimize=guess) with NO SizeMinBytes= at
# all -- Minimize=guess sizes it to the TIGHT-FIT minimum needed to hold the
# built rootfs content, with zero margin for anything the guest writes after
# boot (apt working set, journald, session growth -- all empirically
# observed to matter; see build-guest-image.sh's boot_apt_phase and
# lib/config.sh's CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB comments).
#
# Fix: provide our OWN mkosi.repart/ directory. Once mkosi.repart/ exists at
# all, mkosi does NOT layer its defaults on top -- our directory must be a
# COMPLETE partition table, not just an addendum (verified from mkosi's own
# make_disk(): `if context.config.repart_dirs: definitions = ... else:
# <generate the two defaults>` -- an either/or, not a merge). So 00-esp.conf
# below is a VERBATIM copy of mkosi's own generated default (same Type=esp/
# Format=vfat/CopyFiles=/SizeMinBytes=SizeMaxBytes=512M -- we are not
# changing ESP sizing, only root), and 10-root.conf keeps Minimize=guess
# (so systemd-repart still self-measures the tight-fit content size -- we
# do not hardcode or re-derive that number ourselves) but ADDS
# SizeMinBytes=, which composes with Minimize=guess as "the larger of the
# two wins" (systemd repart.d(5): merging partition definitions,
# SizeMinBytes=/PaddingMinBytes= use the larger of the two values) -- so the
# partition ends up at max(guessed-tight-fit-size, BASE_ESTIMATE_MB +
# headroom), i.e. the guess still governs whenever the real content is
# bigger than our estimate, and our floor only bites when content is
# smaller. BASE_ESTIMATE_MB is a conservative ROUNDED-UP estimate from the
# real-run evidence (issue #106 review: "guest.raw size is 1.5G, consumes
# 850.2M" pre-diet, ESP ~512M of that 1.5G-ish total -> ~850M root content
# pre-diet; the post-diet apt/metadata trims reduce PER-BOOT churn, not this
# static baked content, so the estimate is kept at the pre-diet figure rather
# than assumed smaller) -- not a measurement of THIS build (mkosi's static
# mkosi.repart/ files cannot embed a value computed mid-build; see the
# investigation note this comment is paired with in the PR). Because
# Minimize=guess still runs and wins whenever it exceeds this floor, an
# underestimate here does not silently under-size the image -- it only means
# the operator-configured headroom is measured from a slightly-stale base
# figure, not a hard incorrectness.
BASE_ESTIMATE_MB=900
ROOT_SIZE_MIN_MB=$((BASE_ESTIMATE_MB + ROOT_HEADROOM_MB))
mkdir -p "$STAGE/recipe/mkosi.repart"
cat > "$STAGE/recipe/mkosi.repart/00-esp.conf" <<'ESPCONF'
[Partition]
Type=esp
Format=vfat
CopyFiles=/boot:/
CopyFiles=/efi:/
SizeMinBytes=512M
SizeMaxBytes=512M
ESPCONF
cat > "$STAGE/recipe/mkosi.repart/10-root.conf" <<ROOTCONF
[Partition]
Type=root
Format=ext4
CopyFiles=/
Minimize=guess
SizeMinBytes=${ROOT_SIZE_MIN_MB}M
ROOTCONF

# Bake config (issue #105): write the canonical JSON into the recipe tree so
# the in-container build step can parse it (with the container's python3) to
# extend Packages= and render apt_sources. The mkosi.sandbox/ dir is where the
# apt keyrings + sources.list.d entries are placed: mkosi auto-uses
# mkosi.sandbox/ as a SandboxTree (rooted at /), and invokes apt from OUTSIDE
# the image reading package-manager config from the sandbox tree's canonical
# /etc locations -- so a third-party repo written to
# mkosi.sandbox/etc/apt/sources.list.d/ (with its key at
# mkosi.sandbox/etc/apt/keyrings/) is available to mkosi's apt at install time.
# Created empty here; the in-container step populates it from apt_sources.
printf '%s\n' "$BAKE_CONFIG" > "$STAGE/recipe/bake-config.json"
mkdir -p "$STAGE/recipe/mkosi.sandbox/etc/apt/sources.list.d"
mkdir -p "$STAGE/recipe/mkosi.sandbox/etc/apt/keyrings"

# Install the boot launcher into the guest filesystem tree (mkosi.extra is
# copied verbatim into the rootfs).
install -m 0755 "$BOOT_LAUNCHER" \
  "$STAGE/recipe/mkosi.extra/usr/local/lib/claude-vm/boot-launcher.sh"

# A systemd-networkd .network unit so the guest actually CONFIGURES its
# virtio-net link via DHCP (issue #71, criterion (b)). Without it,
# systemd-networkd has no managed link: systemd-networkd-wait-online never
# completes, network-online.target is never reached, and the autologin
# serial-getty@hvc1 (After=network-online.target) never starts -- the boot
# reaches a login prompt but the acceptance test never sees the seam marker
# and times out.
# vfkit's virtio-net is served by gvproxy, which provides DHCP; the guest
# renames the link enp0s1 (from eth0), so match the en* / eth* glob rather
# than a fixed name. wait-online needs the matched link to reach "routable"
# (DHCP lease) to declare the network online.
cat > "$STAGE/recipe/mkosi.extra/etc/systemd/network/10-claude-vm.network" <<'NET'
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCPv4]
# Treat the DHCPv4 lease as sufficient for network-online.target so
# wait-online does not also block on (absent) IPv6 router advertisements.
RouteMetric=100
NET

# Mount the host-provided virtio-fs shares into the guest (issue #71). The
# host launcher (claude-vm.sh) ALWAYS attaches these virtio-fs devices:
# mountTag=runconfig (the run.env the boot launcher sources -- proxy,
# mount tags, CLAUDE_ARGS), mountTag=repo (the working tree),
# mountTag=claudebin (issue #49 -- the dir holding the host-verified claude
# binary), and mountTag=claudecreds (issue #50 -- the dir holding the host's
# claude.ai OAuth credential the boot launcher installs into
# $HOME/.claude/.credentials.json). vfkit only *shares* the dir under a tag;
# the GUEST must still mount the tag to a path. Nothing did, so
# /mnt/runconfig/run.env never existed and the boot launcher's
# `. /mnt/runconfig/run.env` aborted under `set -e` -- on a real run as well
# as under the acceptance test. fstab + systemd's fstab-generator does the
# mount; RequiresMountsFor on the boot unit (below) orders the seam launcher
# after it.
#
# nofail: a share that is absent on a given boot must not wedge the boot in
# emergency mode; the consumer (boot launcher / claude exec) decides whether
# its absence is fatal. runconfig, claudebin, and claudecreds are mounted ro
# (claudebin is a verified binary the guest must not mutate; claudecreds is
# the secret-bearing OAuth credential -- the boot launcher copies it out to a
# per-user file); repo is rw (the guest works in it).
mkdir -p "$STAGE/recipe/mkosi.extra/mnt/runconfig" \
         "$STAGE/recipe/mkosi.extra/mnt/repo" \
         "$STAGE/recipe/mkosi.extra/mnt/claudebin" \
         "$STAGE/recipe/mkosi.extra/mnt/claudecreds"
cat > "$STAGE/recipe/mkosi.extra/etc/fstab" <<'FSTAB'
# <tag>       <mountpoint>       <type>     <options>     <dump> <pass>
runconfig     /mnt/runconfig     virtiofs   ro,nofail     0 0
repo          /mnt/repo          virtiofs   rw,nofail     0 0
claudebin     /mnt/claudebin     virtiofs   ro,nofail     0 0
claudecreds   /mnt/claudecreds   virtiofs   ro,nofail     0 0
FSTAB

# Interactive boot model (issue #88): claude IS the hvc1 console session.
#
# The OLD model ran the boot launcher as a detached Type=oneshot unit, which
# systemd runs with NO controlling tty -- so claude (an interactive REPL) had
# no terminal and no interactive session appeared. The NEW model binds claude
# to /dev/hvc1 (the vfkit `virtio-serial,stdio` device the launching terminal
# is bridged to) as a FOREGROUND process with a real controlling tty, via an
# autologin getty:
#
#   - serial-getty@hvc1 is enabled explicitly. systemd only auto-spawns a
#     getty on the console= device (hvc0); the interactive console hvc1 needs
#     an explicit enable (the getty.target.wants symlink below).
#   - A drop-in overrides the getty ExecStart to run `agetty --autologin root`
#     with --login-program pointing at the boot launcher. agetty autologs in
#     root, sets up the controlling tty + termios (which is why a fullscreen
#     TUI renders), then execs the boot launcher AS the login program. The
#     boot launcher in turn `exec`s claude -- so claude IS the session, with no
#     shell in between. If claude exits, agetty respawns (a login shell on
#     hvc1) rather than leaving a black screen.
#
# This replaces the hand-rolled oneshot; the getty path is the mechanism
# verified in the #88 spike. The boot launcher still installs the host OAuth
# credential (#50) and execs the host-verified binary (#49); only its
# invocation context changes (detached oneshot -> hvc1 console-getty
# foreground).
#
# Ordering: the getty's RequiresMountsFor pulls in and orders after the
# virtio-fs mounts the launcher needs: runconfig (sourced run.env), claudebin
# (the host-verified binary it execs), claudecreds (the host OAuth credential
# it installs -- #50), and repo (the working tree it cd's into). It also runs
# after network-online.target so the launcher's egress-allowlisted fetch can
# reach the proxy.
mkdir -p "$STAGE/recipe/mkosi.extra/etc/systemd/system/serial-getty@hvc1.service.d"
cat > "$STAGE/recipe/mkosi.extra/etc/systemd/system/serial-getty@hvc1.service.d/10-claude-vm.conf" <<'GETTY'
[Unit]
Description=claude-vm interactive claude session on hvc1
After=network-online.target
Wants=network-online.target
# Order after the virtio-fs mounts the boot launcher needs so it never sees a
# bare mountpoint dir where it expects a mounted share.
RequiresMountsFor=/mnt/runconfig /mnt/claudebin /mnt/claudecreds /mnt/repo

[Service]
# Override the default agetty invocation: autologin root and run the boot
# launcher as the login program (which execs claude). Clear ExecStart first --
# a drop-in APPENDS ExecStart lines, and a unit with two ExecStart entries
# under the default Type=idle would try to run both; the empty assignment
# resets the list so only ours runs.
#
# agetty argument order is `agetty [options] <port> [baud] [term]` -- the PORT
# (hvc1) is the first positional, then the optional baud list, then $TERM
# (expanded by systemd from the serial-getty@.service template). --autologin
# root logs root in with no prompt; --login-program runs the boot launcher
# instead of /bin/login, so the launcher (which execs claude) becomes the
# session with no shell in between. --keep-baud matches the stock serial-getty
# behavior (the vfkit virtio-console has no real baud). The leading `-` makes a
# launcher exit non-fatal so agetty respawns to a login shell rather than a
# black screen if claude exits.
ExecStart=
ExecStart=-/sbin/agetty --autologin root --login-program /usr/local/lib/claude-vm/boot-launcher.sh --keep-baud 115200,57600,38400,9600 hvc1 $TERM
GETTY

# Enable serial-getty@hvc1 at build time by creating the getty.target.wants
# symlink in the tree (no running system to `systemctl enable` against).
# getty.target is pulled in by multi-user.target on a normal boot.
mkdir -p "$STAGE/recipe/mkosi.extra/etc/systemd/system/getty.target.wants"
ln -sf /usr/lib/systemd/system/serial-getty@.service \
  "$STAGE/recipe/mkosi.extra/etc/systemd/system/getty.target.wants/serial-getty@hvc1.service"

# The mkosi config. Kept as a static file so the recipe is auditable.
cat > "$STAGE/recipe/mkosi.conf" <<CONF
[Distribution]
Distribution=debian
# Suite name (e.g. "bookworm"), NOT the numeric release -- mkosi 404s on a
# numeric Debian Release for the apt mirror path (issue #71, Bug 2).
Release=$GUEST_SUITE

[Output]
Format=disk
# Emit to a CONTAINER-LOCAL directory on the same device as mkosi's
# workspace (/var/tmp, the container overlay), NOT the bind-mounted
# /work/out. mkosi finishes by rename()-ing its staged artifacts into
# OutputDirectory; a cross-device rename (workspace overlay -> bind mount)
# falls back to 'cp --preserve=...,xattr', which fails EOPNOTSUPP on the
# bind mount (it cannot hold security.* xattrs). Keeping the output on the
# overlay makes that an in-device rename. The finished image is then
# copied out to the bind-mounted /work/out with a plain cp (no xattr
# preservation) by the build-in-container step (issue #71).
OutputDirectory=/var/tmp/mkosi-out
Output=guest

[Content]
Bootable=yes
Bootloader=systemd-boot
# Interactive in-VM session (issue #88): give root an UNLOCKED, passwordless
# account. The 'hashed:' prefix with no hash sets an empty password hash, so
# root can log in with no password. This is what lets the autologin getty
# (serial-getty@hvc1 drop-in) reach a session -- the base recipe set no
# RootPassword, so the live login prompt rejected every credential. The guest
# is a throwaway micro-VM reachable only over the host-private vfkit
# virtio-serial console (no SSH, no network login), so an unlocked root is not
# an exposed-credential risk.
RootPassword=hashed:
# Direct the kernel console to the serial device vfkit captures (issue #71,
# criterion (b)). vfkit's --device virtio-serial,logFilePath=... is a
# virtio-console, which the guest exposes as /dev/hvc0 -- NOT the PL011 UART
# /dev/ttyAMA0 the EFI firmware stage uses. Without an explicit console= the
# virtio-console driver never registers as /dev/console, so the boot
# launcher's seam message (systemd unit StandardOutput=journal+console ->
# /dev/console) never reaches the captured log and the acceptance test sees
# zero guest output, then times out. hvc0 is the device that actually carries
# the message; ttyAMA0 is listed too as a harmless firmware-stage fallback so
# early-boot output before virtio-console is up is not silently dropped.
# systemd.firstboot=off disables the interactive First Boot Wizard (issue
# #71, criterion (b)). Without it, systemd-firstboot.service runs on the
# pristine image and BLOCKS the boot at "Please configure your system! --
# Press any key to proceed --", waiting on a keypress that never arrives in
# the headless vfkit boot, so the autologin getty (pulled in via
# multi-user.target -> getty.target) never starts and the acceptance test
# times out.
KernelCommandLine=console=ttyAMA0 console=hvc0 systemd.firstboot=off
# Plain ext4 root: keeps the offline (loop-device-free) repart path.
# No Subvolumes=, no SELinux -- neither RepartOffline=no trigger fires.
#
# A kernel package (linux-image-<arch>) is REQUIRED for Bootable=yes --
# without it mkosi fails with "no kernel was found" (issue #71). The
# kernel package name is architecture-dependent, so it is added by an
# arch-resolved mkosi.conf.d drop-in the in-container build step writes,
# rather than hardcoded here.
Packages=
    systemd
    systemd-boot
    udev
    ca-certificates
    curl
    bash
    iproute2
    # util-linux provides /sbin/agetty, which the autologin serial-getty@hvc1
    # drop-in execs to bind claude to the interactive hvc1 console (issue #88).
    # It is Essential on Debian (so normally present), but the autologin getty
    # depends on it directly, so pin it explicitly in the auditable recipe.
    util-linux
    # apt provides apt-get, which the boot launcher's boot_apt_phase (issue
    # #106) execs INSIDE the guest for install_at_boot/update_at_boot. Baked
    # here UNCONDITIONALLY -- not gated on whether boot-time apt work is
    # configured -- because mkosi installs packages from OUTSIDE the image
    # with its own (build-container) apt, so nothing else ever pulls apt/dpkg
    # tooling into the guest rootfs; a real guest boot confirmed
    # boot_apt_phase failing with "apt-get: command not found" before this
    # was added. The security boundary for a hard-secure all-baked config
    # (add_apt_uris_to_allowlist: auto, no boot-time apt work configured) is
    # the egress allowlist leaving package mirrors unreachable, NOT the
    # absence of the apt binary -- and the add_apt_uris_to_allowlist: always
    # mid-session-install path is only honest if apt actually exists to use
    # it. The fail-soft failure policy (a failed apt-get warns and continues
    # to claude) is unchanged.
    apt

[Build]
# Offline repart: build the disk without loopback devices so this runs in
# an unprivileged rootless-podman container. This is the default; pinned
# explicitly so a future mkosi default change cannot silently flip us onto
# the loop-device path. RepartOffline= is a [Build] key (per mkosi.1);
# under [Validation] it would be dropped and the explicit pin would do
# nothing.
RepartOffline=yes
CONF

# The build command run INSIDE the container. Running as a throwaway
# container means nothing is left on the host.
#
# mkosi v26 (upstream) is used, NOT Trixie's apt-packaged 25.3: 25.3's
# "Copying repository metadata" step runs `cp --preserve=...,xattr`, which
# fails EOPNOTSUPP on the podman-machine container filesystem (it cannot
# set security.* xattrs). v26 reworked that copy step and builds cleanly
# (issue #71, Bug 3). v26 is installed from the pinned upstream tag into a
# venv; pefile is required by v26's UKI/EFI step.
MKOSI_REF='v26'
cat > "$STAGE/build-in-container.sh" <<INNER
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# The host toolchain mkosi v26 shells out to for a Debian disk build, plus
# python3-venv/pip + git to install mkosi v26 from upstream. systemd-ukify,
# cpio, zstd, xz-utils, mtools, squashfs-tools are part of the v26 toolchain
# (issue #71). curl + ca-certificates are required by render_apt_source
# below (issue #105), which fetches each packages.apt_sources key_url with
# curl INSIDE this build container -- without them the fetch fails with
# "curl: command not found" before any baked package can be installed.
apt-get install -y -qq --no-install-recommends \\
  python3 python3-venv python3-pip git \\
  systemd-boot debootstrap dosfstools e2fsprogs systemd-repart \\
  systemd-ukify cpio zstd xz-utils mtools squashfs-tools \\
  curl ca-certificates >/dev/null

# Install mkosi v26 (pinned tag) + pefile into a venv and put it on PATH.
python3 -m venv /opt/mkosi-venv
/opt/mkosi-venv/bin/pip install --quiet \\
  "git+https://github.com/systemd/mkosi@${MKOSI_REF}" pefile
export PATH=/opt/mkosi-venv/bin:\$PATH

# Bootable=yes needs a kernel; its package name is arch-dependent. Resolve
# it from the container's architecture and add it via a mkosi.conf.d drop-in
# so the static recipe stays arch-agnostic (issue #71).
DEB_ARCH="\$(dpkg --print-architecture)"
KERNEL_PKG="linux-image-\${DEB_ARCH}"
mkdir -p /work/recipe/mkosi.conf.d
cat > /work/recipe/mkosi.conf.d/10-kernel.conf <<KCONF
[Content]
Packages=
    \${KERNEL_PKG}
KCONF
echo "podman-mkosi(inner): mkosi \$(mkosi --version), kernel package \${KERNEL_PKG}" >&2

# -------------------------------------------------------------------------
# Baked packages + third-party apt repos (issue #105).
#
# The canonical bake config lives at /work/recipe/bake-config.json (written by
# the host provisioner). Parse it here with the container's python3 (already
# installed above) and render two things:
#
#   (a) packages.bake -> a mkosi.conf.d drop-in extending Packages= (same
#       mechanism as the kernel drop-in above), so mkosi installs them into
#       the guest image.
#   (b) packages.apt_sources -> for each {name, repo, key_url}, fetch the key
#       into the mkosi SANDBOX TREE at /etc/apt/keyrings/<name>.asc and write
#       /etc/apt/sources.list.d/<name>.list (signed-by that keyring), so
#       mkosi's apt -- which reads package-manager config from the sandbox
#       tree -- can install baked packages served from third-party repos
#       (e.g. gh from cli.github.com). The fetch happens HERE, in the build
#       container, which has network.
#
# render_apt_source is written as a REUSABLE unit (keyring fetch + sources.list
# write) so the boot-time-install sibling slice (issue #106) can reuse the same
# shape against the guest's real /etc/apt at boot. The two WRITE dirs are args
# so the caller points them at the sandbox tree here (or the live guest /etc/apt
# there). keyring_runtime_dir is separate from keyrings_dir because the file is
# WRITTEN to the staging sandbox tree (/work/recipe/mkosi.sandbox/etc/apt/...)
# but apt READS it, at mkosi build time, from the sandbox tree's canonical
# mount point (/etc/apt/...) -- so the [signed-by=] path baked into the source
# line must be the RUNTIME path, not the staging path. For #106 the caller
# passes the same value for keyrings_dir and keyring_runtime_dir (both the live
# /etc/apt/keyrings), so the two collapse and the same function works verbatim.
#
#   render_apt_source <name> <repo> <key_url> \
#                     <keyrings_dir> <sources_dir> <keyring_runtime_dir>
#
# name VALIDATION: name flows unescaped into staging filenames
# (<keyrings_dir>/<name>.asc, <sources_dir>/<name>.list). The merged config
# unions the per-repo .claude-vm/config.yml into apt_sources, so name is NOT
# fully operator-authored for an untrusted repo -- a name containing e.g.
# "../" could write outside the intended staging dirs. Reject anything
# outside a conservative filename-safe charset BEFORE building any path.
#
# repo-line MERGE + PRECEDENCE (issue #105 real-build follow-up): the repo
# string may already carry its own apt one-line "[options]" block (e.g. an
# operator-authored "deb [arch=arm64 signed-by=/etc/apt/keyrings/x.asc] ...").
# apt's one-line format allows exactly ONE such block right after the leading
# deb/deb-src token; unconditionally splicing a second [signed-by=...] block
# in produces a line with TWO option blocks, which apt cannot parse (the
# second block lands where the URI belongs). So this function ADAPTS to
# whatever shape the repo line already has, and for any option the repo line
# already specifies (signed-by, today), the REPO LINE'S VALUE WINS -- this
# function never overrides an operator-authored option value:
#
#   1. No [options] block at all -> add one: "deb [signed-by=<runtime>] ...".
#   2. [options] block present, no signed-by= in it -> MERGE signed-by=<runtime>
#      into the existing block (other options pass through untouched); still
#      exactly one block.
#   3. [options] block present WITH an existing signed-by=P -> the line is
#      left byte-for-byte VERBATIM (P wins), and the fetched key is written to
#      P's STAGING equivalent (<keyrings_dir's sandbox root> + P) instead of
#      the default <keyrings_dir>/<name>.asc, so the declared path and the
#      actual key location never drift apart. P is validated with the same
#      conservative charset/traversal discipline as name before use.
#   4. No key_url (have_key=0) -- write the line verbatim regardless of shape;
#      an operator-supplied signed-by with no key_url is the operator's own
#      arrangement to pass through, not an error.
#   5. Lines not starting with deb/deb-src are written verbatim (unchanged).
render_apt_source() {
  local name="\$1" repo="\$2" key_url="\$3" keyrings_dir="\$4" sources_dir="\$5"
  local keyring_runtime_dir="\${6:-\$4}"
  if [ -z "\$name" ] || [ -z "\$repo" ]; then
    echo "podman-mkosi(inner): apt_source entry missing name or repo; skipping" >&2
    return 1
  fi
  case "\$name" in
    *[!A-Za-z0-9._-]*)
      echo "podman-mkosi(inner): apt_source name '\$name' contains characters outside [A-Za-z0-9._-]; aborting" >&2
      return 1
      ;;
  esac
  mkdir -p "\$keyrings_dir" "\$sources_dir"
  local keyring_write_path="\$keyrings_dir/\${name}.asc"
  local keyring_runtime_path="\$keyring_runtime_dir/\${name}.asc"

  # Does the repo line start with deb/deb-src, and if so does it already
  # carry an [options] block, and if so does that block already have a
  # signed-by=? Detected with one bash regex so the merge logic below has a
  # single source of truth for "what shape is this line". The [options]
  # block is a single bracketed span that may itself contain spaces (e.g.
  # "[arch=amd64 signed-by=...]"), so this is NOT safe to detect via
  # whitespace field-splitting (awk \$2) -- it must match the bracket span
  # itself.
  local is_deb_line=0 has_block=0 block_has_signed_by=0 existing_signed_by=""
  if [[ "\$repo" =~ ^(deb|deb-src)([[:space:]]+)\[([^]]*)\](.*)\$ ]]; then
    is_deb_line=1
    has_block=1
    local block_body="\${BASH_REMATCH[3]}"
    if [[ "\$block_body" =~ (^|[[:space:]])signed-by=([^[:space:]]+) ]]; then
      block_has_signed_by=1
      existing_signed_by="\${BASH_REMATCH[2]}"
    fi
  elif [[ "\$repo" =~ ^(deb|deb-src)[[:space:]] ]]; then
    is_deb_line=1
  fi

  local have_key=0
  if [ -n "\$key_url" ]; then
    if [ "\$is_deb_line" -eq 1 ] && [ "\$has_block" -eq 1 ] && [ "\$block_has_signed_by" -eq 1 ]; then
      # Case 3: the repo line already pins its own signed-by path. That path
      # wins verbatim; validate it before using it to build a staging write
      # path (same charset/traversal discipline as name -- this value flows
      # from the merged, partially repo-authored config).
      case "\$existing_signed_by" in
        /*) : ;;
        *)
          echo "podman-mkosi(inner): apt_source '\$name' signed-by path '\$existing_signed_by' is not absolute; aborting" >&2
          return 1
          ;;
      esac
      case "\$existing_signed_by" in
        *[[:space:]]*|*']'*)
          echo "podman-mkosi(inner): apt_source '\$name' signed-by path '\$existing_signed_by' contains disallowed characters; aborting" >&2
          return 1
          ;;
      esac
      local seg IFS=/
      for seg in \$existing_signed_by; do
        if [ "\$seg" = ".." ]; then
          echo "podman-mkosi(inner): apt_source '\$name' signed-by path '\$existing_signed_by' contains a '..' path segment; aborting" >&2
          return 1
        fi
      done
      unset IFS
      # SECURITY: absolute + charset-safe + no '..' is NOT sufficient. repo
      # (and therefore existing_signed_by) is UNTRUSTED -- it flows from the
      # merged, per-repo .claude-vm/config.yml (same untrusted-input status
      # documented on 'name' above). Without a further constraint, a
      # malicious per-repo config could pair an attacker-served key_url with
      # e.g. signed-by=/etc/cron.d/x and this function would write
      # attacker-controlled bytes to an arbitrary path in the guest image
      # staging tree, which then boots as root -- a strictly larger write
      # primitive than the one the 'name' allowlist closes. Constrain P to
      # the two canonical apt keyring directories: it must be exactly
      # /etc/apt/keyrings/<file> or /usr/share/keyrings/<file>, with no
      # further subdirectories and a charset-safe <file>. A repo wanting a
      # custom keyring path outside these is not a supported use case.
      case "\$existing_signed_by" in
        /etc/apt/keyrings/*|/usr/share/keyrings/*)
          local kr_file="\${existing_signed_by##*/}"
          case "\$kr_file" in
            *[!A-Za-z0-9._-]*|"")
              echo "podman-mkosi(inner): apt_source '\$name' signed-by path '\$existing_signed_by' has a filename outside [A-Za-z0-9._-]; aborting" >&2
              return 1
              ;;
          esac
          local kr_parent="\${existing_signed_by%/*}"
          if [ "\$kr_parent" != "/etc/apt/keyrings" ] && [ "\$kr_parent" != "/usr/share/keyrings" ]; then
            echo "podman-mkosi(inner): apt_source '\$name' signed-by path '\$existing_signed_by' is not directly under an allowed keyrings directory; aborting" >&2
            return 1
          fi
          ;;
        *)
          echo "podman-mkosi(inner): apt_source '\$name' signed-by path '\$existing_signed_by' is outside the allowed keyrings directories (/etc/apt/keyrings, /usr/share/keyrings); aborting" >&2
          return 1
          ;;
      esac
      # Write the fetched key to the STAGING equivalent of the declared
      # runtime path: <keyrings_dir-as-sandbox-root> + P. keyrings_dir is
      # "<sandbox_root><keyring_runtime_dir>" by construction (the caller
      # points keyrings_dir at the staging equivalent of
      # keyring_runtime_dir), so strip keyring_runtime_dir itself -- not a
      # hardcoded "/etc/apt/keyrings" literal -- as the suffix to recover the
      # root. This stays correct if a future caller (issue #106) passes a
      # keyring_runtime_dir other than /etc/apt/keyrings, and collapses to
      # sandbox_root="" for #106's live-/etc/apt reuse (write dir == runtime
      # dir), which is exactly the identity write-in-place that case needs.
      local sandbox_root="\${keyrings_dir%\$keyring_runtime_dir}"
      keyring_write_path="\${sandbox_root}\${existing_signed_by}"
      mkdir -p "\$(dirname "\$keyring_write_path")"
    fi
    # Fetch the signing key into the keyring (staging path, resolved above).
    # -fsSL: fail on HTTP error, quiet, follow redirects. A failed key fetch
    # is fatal -- an unsigned/unverified third-party repo must not be
    # silently added.
    if ! curl -fsSL "\$key_url" -o "\$keyring_write_path"; then
      echo "podman-mkosi(inner): failed to fetch apt key for '\$name' from \$key_url" >&2
      return 1
    fi
    have_key=1
  fi

  # Compose the emitted line per the have_key/shape matrix documented above.
  local line
  if [ "\$have_key" -eq 1 ] && [ "\$is_deb_line" -eq 1 ] && [ "\$has_block" -eq 1 ] && [ "\$block_has_signed_by" -eq 1 ]; then
    # Case 3: repo line wins -- emit verbatim, unchanged.
    line="\$repo"
  elif [ "\$have_key" -eq 1 ] && [ "\$is_deb_line" -eq 1 ] && [ "\$has_block" -eq 1 ]; then
    # Case 2: existing [options] block, no signed-by= in it -- merge
    # signed-by=<runtime> INTO the existing block; other options pass
    # through untouched. Reconstruct via the same regex match used for
    # detection above so this does not re-derive the split independently.
    if [[ "\$repo" =~ ^(deb|deb-src)([[:space:]]+)\[([^]]*)\](.*)\$ ]]; then
      local tok="\${BASH_REMATCH[1]}" ws="\${BASH_REMATCH[2]}" body="\${BASH_REMATCH[3]}" rest="\${BASH_REMATCH[4]}"
      line="\${tok}\${ws}[\${body} signed-by=\${keyring_runtime_path}]\${rest}"
    else
      # Unreachable given has_block=1 above; fall back to verbatim rather
      # than risk emitting a malformed line.
      line="\$repo"
    fi
  elif [ "\$have_key" -eq 1 ] && [ "\$is_deb_line" -eq 1 ]; then
    # Case 1: no [options] block at all -- add one right after the leading
    # deb/deb-src token.
    line="\$(printf '%s' "\$repo" | awk -v sb="\$keyring_runtime_path" '{
      printf "%s [signed-by=%s]", \$1, sb; for(i=2;i<=NF;i++) printf " %s", \$i; print ""
    }')"
  else
    # Case 4/5: no key fetched, or not a deb/deb-src line -- verbatim.
    line="\$repo"
  fi
  printf '%s\n' "\$line" > "\$sources_dir/\${name}.list"
  echo "podman-mkosi(inner): rendered apt_source '\$name' -> \$sources_dir/\${name}.list" >&2
}

# Parse the bake config with python3 and emit shell-safe records.
# Baked packages, one per line.
BAKE_PACKAGES="\$(python3 -c '
import json,sys
d=json.load(open("/work/recipe/bake-config.json"))
for p in d.get("bake",[]):
    print(p)
')"
if [ -n "\$BAKE_PACKAGES" ]; then
  {
    echo "[Content]"
    echo "Packages="
    while IFS= read -r pkg; do
      [ -n "\$pkg" ] && printf '    %s\n' "\$pkg"
    done <<< "\$BAKE_PACKAGES"
  } > /work/recipe/mkosi.conf.d/20-bake-packages.conf
  echo "podman-mkosi(inner): baking packages: \$(printf '%s ' \$BAKE_PACKAGES)" >&2
fi

# apt_sources, one TAB-separated record per line: name<TAB>repo<TAB>key_url.
# python3's json parse preserves the canonical order; render each into the
# mkosi sandbox tree so mkosi's apt sees the repo at install time.
# SANDBOX_* are the STAGING write paths under the recipe tree; APT_KEYRINGS_RT
# is the RUNTIME path apt reads keyrings from (the sandbox tree is mounted at
# / for the build), which is what the [signed-by=] in each source line must
# reference.
SANDBOX_KEYRINGS=/work/recipe/mkosi.sandbox/etc/apt/keyrings
SANDBOX_SOURCES=/work/recipe/mkosi.sandbox/etc/apt/sources.list.d
APT_KEYRINGS_RT=/etc/apt/keyrings
python3 -c '
import json
d=json.load(open("/work/recipe/bake-config.json"))
for s in d.get("apt_sources",[]):
    name=s.get("name","") or ""
    repo=s.get("repo","") or ""
    key_url=s.get("key_url","") or ""
    print("\t".join([name,repo,key_url]))
' | while IFS=\$'\t' read -r as_name as_repo as_key_url; do
  [ -n "\$as_name" ] || continue
  render_apt_source "\$as_name" "\$as_repo" "\$as_key_url" \\
    "\$SANDBOX_KEYRINGS" "\$SANDBOX_SOURCES" "\$APT_KEYRINGS_RT"
done
# -------------------------------------------------------------------------

cd /work/recipe
# Build. RepartOffline=yes (set in mkosi.conf) keeps this off loop devices.
mkosi build

# mkosi writes the image to the container-local OutputDirectory
# (/var/tmp/mkosi-out, on the overlay device -- see mkosi.conf). Copy it
# out to the bind-mounted /work/out with a PLAIN cp (NO --preserve=xattr):
# the bind mount cannot hold security.* xattrs, and we do not need them on
# the final raw image anyway (issue #71).
if [ -f /var/tmp/mkosi-out/guest.raw ]; then
  cp /var/tmp/mkosi-out/guest.raw /work/out/claude-vm-guest.raw
elif [ -f /var/tmp/mkosi-out/guest ]; then
  cp /var/tmp/mkosi-out/guest /work/out/claude-vm-guest.raw
else
  echo "podman-mkosi(inner): mkosi did not produce the expected disk image in /var/tmp/mkosi-out" >&2
  ls -la /var/tmp/mkosi-out >&2 || true
  exit 1
fi
INNER
chmod +x "$STAGE/build-in-container.sh"

echo "podman-mkosi: building raw EFI guest (debian-$GUEST_RELEASE_NUM/$GUEST_SUITE) via mkosi in a throwaway $BUILD_CONTAINER_IMAGE container..." >&2

# Run the build. --rm: throwaway container.
#
# --privileged is REQUIRED (issue #71, Bug 1): mkosi's sandbox calls
# unshare(CLONE_NEWNS) (a new MOUNT namespace) and then mounts a fresh
# devpts to set up its build sandbox. A default rootless container lacks
# CAP_SYS_ADMIN, so unshare() fails EPERM; --cap-add SYS_ADMIN alone
# advances past unshare but then fails at the devpts mount, and
# seccomp/unmask relaxations have no effect. Only --privileged clears the
# entire sandbox-setup path. The offline (RepartOffline=yes) repart path
# still uses no loop devices, so this stays a loop-device-free build.
#
# The recipe and output dirs are bind-mounted from the host stage so the
# produced image lands where we can copy it out.
podman run --rm --privileged \
  -v "$STAGE/recipe:/work/recipe" \
  -v "$STAGE/out:/work/out" \
  -v "$STAGE/build-in-container.sh:/work/build-in-container.sh:ro" \
  -w /work \
  "$BUILD_CONTAINER_IMAGE" \
  /work/build-in-container.sh

PRODUCED="$STAGE/out/claude-vm-guest.raw"
[ -f "$PRODUCED" ] || { echo "podman-mkosi: build did not produce $PRODUCED" >&2; exit 1; }

# Atomic-ish copy into place: write to a temp sibling, then rename.
TMP_OUT="$OUTPUT_DIR/.$OUTPUT_BASE.tmp.$$"
cp "$PRODUCED" "$TMP_OUT"
mv -f "$TMP_OUT" "$OUTPUT_IMAGE"

echo "podman-mkosi: wrote raw EFI-bootable guest image to $OUTPUT_IMAGE" >&2
