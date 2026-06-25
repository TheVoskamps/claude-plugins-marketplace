#!/usr/bin/env bash
#
# podman-mkosi.sh -- the BUNDLED DEFAULT claude-vm image provisioner.
#
# Contract (the same one CLAUDE_VM_IMAGE_PROVISIONER overrides honor):
#
#   podman-mkosi.sh <boot-launcher-path> <output-image-path>
#
#   $1  boot-launcher-path  -- the one-shot boot launcher script
#                             build-guest-image.sh emitted. Installed into
#                             the guest as a Type=oneshot systemd unit.
#   $2  output-image-path    -- where to write the raw, EFI-bootable guest
#                             image. vfkit boots this with --bootloader efi.
#
# It produces a raw, EFI-bootable Debian guest with the boot launcher wired
# as a Type=oneshot unit, by running mkosi inside a THROWAWAY rootless
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

# Install the boot launcher into the guest filesystem tree (mkosi.extra is
# copied verbatim into the rootfs).
install -m 0755 "$BOOT_LAUNCHER" \
  "$STAGE/recipe/mkosi.extra/usr/local/lib/claude-vm/boot-launcher.sh"

# A systemd-networkd .network unit so the guest actually CONFIGURES its
# virtio-net link via DHCP (issue #71, criterion (b)). Without it,
# systemd-networkd has no managed link: systemd-networkd-wait-online never
# completes, network-online.target is never reached, and the seam oneshot
# (After=network-online.target) never runs -- the boot reaches a login
# prompt but the acceptance test never sees the seam marker and times out.
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
# host launcher (claude-vm.sh) ALWAYS attaches two virtio-fs devices:
# mountTag=runconfig (the run.env the boot launcher sources -- proxy, scoped
# token, CLAUDE_ARGS) and mountTag=repo (the working tree). vfkit only
# *shares* the dir under a tag; the GUEST must still mount the tag to a path.
# Nothing did, so /mnt/runconfig/run.env never existed and the boot
# launcher's `. /mnt/runconfig/run.env` aborted under `set -e` -- on a real
# run as well as under the acceptance test. fstab + systemd's
# fstab-generator does the mount; RequiresMountsFor on the boot unit (below)
# orders the seam launcher after it.
#
# nofail: a share that is absent on a given boot must not wedge the boot in
# emergency mode; the consumer (boot launcher / future claude exec) decides
# whether its absence is fatal. runconfig is mounted ro (it is secret-bearing
# and the guest never writes it); repo is rw (the guest works in it).
mkdir -p "$STAGE/recipe/mkosi.extra/mnt/runconfig" \
         "$STAGE/recipe/mkosi.extra/mnt/repo"
cat > "$STAGE/recipe/mkosi.extra/etc/fstab" <<'FSTAB'
# <tag>     <mountpoint>     <type>     <options>     <dump> <pass>
runconfig   /mnt/runconfig   virtiofs   ro,nofail     0 0
repo        /mnt/repo        virtiofs   rw,nofail     0 0
FSTAB

# The Type=oneshot unit that runs the boot launcher on guest boot. Wanted
# by multi-user.target so it runs on a normal boot; runs after the network
# is up so the egress-allowlisted fetch the launcher performs can reach the
# proxy. RequiresMountsFor pulls in and orders after the runconfig mount so
# the launcher's `. /mnt/runconfig/run.env` sees the share.
cat > "$STAGE/recipe/mkosi.extra/etc/systemd/system/claude-vm-boot.service" <<'UNIT'
[Unit]
Description=claude-vm one-shot boot launcher
After=network-online.target
Wants=network-online.target
# Pull in and order after the runconfig virtio-fs mount so the launcher's
# `. /mnt/runconfig/run.env` reads a mounted share, not a bare directory.
RequiresMountsFor=/mnt/runconfig

[Service]
Type=oneshot
ExecStart=/usr/local/lib/claude-vm/boot-launcher.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# Enable the unit at build time by creating the multi-user.target.wants
# symlink in the tree (no running system to `systemctl enable` against).
mkdir -p "$STAGE/recipe/mkosi.extra/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/claude-vm-boot.service \
  "$STAGE/recipe/mkosi.extra/etc/systemd/system/multi-user.target.wants/claude-vm-boot.service"

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
# falls back to `cp --preserve=...,xattr`, which fails EOPNOTSUPP on the
# bind mount (it cannot hold security.* xattrs). Keeping the output on the
# overlay makes that an in-device rename. The finished image is then
# copied out to the bind-mounted /work/out with a plain cp (no xattr
# preservation) by the build-in-container step (issue #71).
OutputDirectory=/var/tmp/mkosi-out
Output=guest

[Content]
Bootable=yes
Bootloader=systemd-boot
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
# the headless vfkit boot, so the seam oneshot (ordered after
# multi-user.target) never runs and the acceptance test times out.
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
# (issue #71).
apt-get install -y -qq --no-install-recommends \\
  python3 python3-venv python3-pip git \\
  systemd-boot debootstrap dosfstools e2fsprogs systemd-repart \\
  systemd-ukify cpio zstd xz-utils mtools squashfs-tools >/dev/null

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
