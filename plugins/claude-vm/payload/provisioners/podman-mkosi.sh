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
# Interactive in-VM session (issue #88): give root an UNLOCKED, passwordless
# account. The `hashed:` prefix with no hash sets an empty password hash, so
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
