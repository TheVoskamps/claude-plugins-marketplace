#!/usr/bin/env bash
#
# build-guest-image.sh -- build the claude-vm guest base image.
#
# The guest image is a STABLE BASE: a pinned OS plus a one-shot
# boot launcher that, on every boot, fetches the CURRENT `claude`
# through the egress allowlist and execs it against the mounted repo.
# Claude Code updates daily, so `claude` is deliberately NOT baked into
# the image -- only the base OS and the launcher logic are. The base
# changes only when the OS pin or the launcher logic version changes,
# never when claude does.
#
# The launcher (claude-vm.sh) calls this on demand:
#   - `--print-version`  : print the pinned base version and exit. Used
#                          to decide whether a cached image is current.
#   - `--output <path>`  : build the image at <path> and stamp
#                          <path>.version with the pinned version.
#
# No image artifact is committed to the repo, and there is no
# publish-prebuilt-image path -- every machine builds (or rebuilds on
# version mismatch) its own image locally.
#
# Requires (for an actual build): the macOS guest-image build toolchain
# (e.g. a base OS image fetch + cloud-init style provisioning). The
# concrete provisioning steps are environment-specific; this script
# pins the version and lays out the build so a missing/mismatched image
# triggers a rebuild rather than an error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The bundled DEFAULT provisioner: mkosi in a throwaway rootless podman
# container (see payload/provisioners/podman-mkosi.sh). Used when
# CLAUDE_VM_IMAGE_PROVISIONER is unset; the env var still overrides it.
DEFAULT_PROVISIONER="$SCRIPT_DIR/provisioners/podman-mkosi.sh"

# ---------------------------------------------------------------------
# Version pin. Bump BASE_OS_REV when the base OS image changes, and
# LAUNCHER_LOGIC_REV when the boot launcher logic below changes. The
# composite is what gets stamped into <image>.version and compared by
# the launcher. It intentionally does NOT include the claude version.
# ---------------------------------------------------------------------
BASE_OS_REV="debian-12-20250601"
LAUNCHER_LOGIC_REV="1"
PINNED_VERSION="${BASE_OS_REV}+launcher${LAUNCHER_LOGIC_REV}"

usage() {
  cat >&2 <<'EOF'
usage:
  build-guest-image.sh --print-version
  build-guest-image.sh --output <image-path>
EOF
}

# The one-shot boot launcher baked into the guest. It runs on guest boot,
# loads the run environment, and stops at the claude-fetch SEAM (this
# slice / issue #75 does not fetch claude; slice 4 / issue #76 fills the
# seam with a pre-verified binary). Emitted here (not committed as a
# separate file) so the launcher logic version is owned by this build
# recipe. Kept as a heredoc that the build step installs into the image
# as the Type=oneshot systemd unit's ExecStart.
emit_boot_launcher() {
  cat <<'BOOT'
#!/usr/bin/env bash
# claude-vm guest one-shot boot launcher (version-pinned with the base).
# Runs on guest boot. Loads the run environment (proxy + args) and stops
# at the claude-fetch seam. claude is NEVER baked in; slice 4 fills the
# seam below with a host-side GPG-verified binary mounted into the guest.
set -euo pipefail

# Mount points provided by vfkit virtio-fs tags.
REPO_MNT=/mnt/repo
RUNCONFIG_MNT=/mnt/runconfig

# Load run environment (proxy, scoped token, CLAUDE_ARGS) written by the
# host launcher into the runconfig share.
set -a
# shellcheck disable=SC1091
. "$RUNCONFIG_MNT/run.env"
set +a

# ---------------------------------------------------------------------
# claude-fetch SEAM (slice 3 / issue #75 stops HERE).
#
# This is the explicit boundary where the guest would obtain `claude`.
# Slice 4 (issue #76) fills this seam with the GPG-signed-manifest
# host-side cache: a pre-verified `claude` binary mounted into the guest,
# NOT a `curl https://claude.ai/install.sh | bash` fetched-and-run path.
#
# Shipping the install.sh path here would build a claude-fetch that slice
# 4 immediately rewrites -- and would run unverified, freshly-fetched
# code on every boot (the install.sh script is itself unsigned and
# unchecksummed; see issue #57's "root of trust" analysis). So this slice
# deliberately STOPS at the seam: the guest boots to the point of needing
# claude and no further. The boot is observable (the message below) so the
# acceptance test can confirm the guest reaches the seam.
#
# Until slice 4 wires the verified binary, the unit reaching this point IS
# the success condition for this slice's boot test.
# ---------------------------------------------------------------------
echo "claude-vm: guest booted to the claude-fetch seam (slice 4 / #76 fills this)." >&2
echo "claude-vm: no claude binary is provisioned yet; stopping at the seam." >&2

# Exit 0: reaching the seam IS this slice's success condition, so the
# oneshot unit records a clean stop at the seam (claude not yet run).
# Slice 4 replaces the seam above with the pre-verified binary and the
# exec below.
exit 0

# --- slice 4 fills the seam above; the exec lands here once claude exists ---
# cd "$REPO_MNT"
# # shellcheck disable=SC2086
# exec claude $CLAUDE_ARGS
BOOT
}

build_image() {
  local output="$1"
  local outdir
  outdir="$(dirname "$output")"
  mkdir -p "$outdir"

  echo "build-guest-image: building base '$PINNED_VERSION' -> $output" >&2

  # Emit the version-pinned boot launcher into a staging dir, then hand it
  # to the provisioner, which produces a bootable raw image at "$output"
  # carrying boot-launcher.sh as its Type=oneshot boot unit.
  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-build.XXXXXX")"
  emit_boot_launcher > "$stage/boot-launcher.sh"
  chmod +x "$stage/boot-launcher.sh"

  # --- provisioning -----------------------------------------------------
  # The provisioner takes <boot-launcher-path> <output-image-path> and
  # writes a bootable raw image. CLAUDE_VM_IMAGE_PROVISIONER overrides the
  # bundled default (podman-mkosi.sh). Export BASE_OS_REV so the
  # provisioner pins the same guest distro this recipe pins, rather than
  # duplicating the version.
  local provisioner
  if [ -n "${CLAUDE_VM_IMAGE_PROVISIONER:-}" ]; then
    provisioner="$CLAUDE_VM_IMAGE_PROVISIONER"
  else
    provisioner="$DEFAULT_PROVISIONER"
  fi
  if [ ! -x "$provisioner" ] || [ ! -f "$provisioner" ]; then
    echo "build-guest-image: provisioner not found: $provisioner" >&2
    echo "build-guest-image: set CLAUDE_VM_IMAGE_PROVISIONER to a script taking" >&2
    echo "  <boot-launcher-path> <output-image-path>, or restore the bundled default." >&2
    rm -rf "$stage"
    return 1
  fi
  CLAUDE_VM_BASE_OS_REV="$BASE_OS_REV" \
    "$provisioner" "$stage/boot-launcher.sh" "$output"
  # ----------------------------------------------------------------------

  rm -rf "$stage"

  # Stamp the version so the launcher's ensure-image check can compare.
  printf '%s\n' "$PINNED_VERSION" > "$output.version"
  echo "build-guest-image: built '$PINNED_VERSION' at $output" >&2
}

main() {
  case "${1:-}" in
    --print-version)
      printf '%s\n' "$PINNED_VERSION"
      ;;
    --output)
      [ -n "${2:-}" ] || { usage; exit 2; }
      build_image "$2"
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
