#!/usr/bin/env bash
#
# build-guest-image.sh -- build the claude-vm guest base image.
#
# The guest image is a STABLE BASE: a pinned OS plus a boot launcher that,
# on every boot, runs the host-verified `claude` (mounted RO at
# /mnt/claudebin) against the mounted repo as an interactive session on the
# hvc1 console (issue #88).
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
# Bumped 1 -> 2: the boot launcher now fills the claude-fetch seam, mounting
# the host-verified binary (mountTag=claudebin) and exec'ing claude against
# /mnt/repo (issue #49). Old images stamped 'launcher1' rebuild on next run.
# Bumped 2 -> 3: the boot launcher now installs the host's claude.ai OAuth
# credential (mounted RO under mountTag=claudecreds) into
# $HOME/.claude/.credentials.json (mode 0600) before exec'ing claude, so the
# guest authenticates as the host operator (issue #50). Replaces the dropped
# ANTHROPIC_API_KEY/ANTHROPIC_VM_TOKEN model. Old images stamped 'launcher2'
# rebuild on next run.
# Bumped 3 -> 4: interactive boot model (issue #88). claude now runs as the
# login program of an autologin serial-getty@hvc1 (with a real controlling
# tty -- the vfkit stdio console the launching terminal is bridged to) instead
# of a detached Type=oneshot unit, so an interactive in-VM claude session
# appears on the launching terminal. The boot launcher routes diagnostics to
# /dev/console (hvc0 capture), seeds the hvc1 tty geometry from the host's
# CLAUDE_VM_COLUMNS/LINES, and the renderer controls (CLAUDE_CODE_*) flow
# through run.env. The recipe also sets RootPassword=hashed: (unlocked root)
# and enables the autologin getty. The boot-logic change requires old images
# (stamped 'launcher3') to rebuild on next run.
# Bumped 4 -> 5: OAuth setup-token auth (issue #88). Current Claude Code does
# not treat the mounted ~/.claude/.credentials.json as pre-authenticated -- it
# runs its interactive login flow, unusable on the byte-pipe console. The boot
# launcher now reads the host's CLAUDE_CODE_OAUTH_TOKEN (from `claude
# setup-token`) out of the shred-on-exit claudecreds mount and exports it
# before exec'ing claude, so the guest authenticates headlessly. The
# boot-logic change requires old images (stamped 'launcher4') to rebuild.
LAUNCHER_LOGIC_REV="5"
PINNED_VERSION="${BASE_OS_REV}+launcher${LAUNCHER_LOGIC_REV}"

usage() {
  cat >&2 <<'EOF'
usage:
  build-guest-image.sh --print-version
  build-guest-image.sh --output <image-path>
EOF
}

# The boot launcher baked into the guest. As of issue #88 it runs as the
# LOGIN PROGRAM of an autologin serial-getty@hvc1 (a real controlling tty),
# loads the run environment, then execs the host-verified `claude` binary
# (mounted RO at /mnt/claudebin by the guest fstab) against the mounted repo
# at /mnt/repo -- so claude IS the interactive hvc1 session. The binary is
# fetched, GPG-manifest-verified, and cached HOST-SIDE by the launcher
# (lib/claude-cache.sh, issue #49); the guest only runs the already-verified
# binary off the RO mount -- it never runs `install.sh | bash` on this trusted
# path. Emitted here (not committed as a separate file) so the launcher logic
# version is owned by this build recipe. Kept as a heredoc that the build step
# installs into the image; the provisioner wires it as the getty's
# --login-program (issue #88), replacing the old Type=oneshot unit.
emit_boot_launcher() {
  cat <<'BOOT'
#!/usr/bin/env bash
# claude-vm guest boot launcher (version-pinned with the base).
#
# Interactive model (issue #88): this runs as the LOGIN PROGRAM of an autologin
# getty on /dev/hvc1 (serial-getty@hvc1 drop-in), so it has a real controlling
# terminal -- the vfkit `virtio-serial,stdio` console the launching terminal is
# bridged to. It loads the run environment (proxy + args + geometry + renderer),
# installs the host's claude.ai OAuth credential (mounted RO at /mnt/claudecreds)
# into $HOME/.claude/.credentials.json so claude authenticates as the host
# operator (issue #50), seeds the tty geometry from the host (issue #88), then
# `exec`s the host-verified `claude` binary mounted RO at /mnt/claudebin against
# the repo at /mnt/repo -- so claude IS the interactive session, with no shell
# in between. claude is NEVER baked into the image and is NEVER fetched-and-run
# inside the guest: the host fetches, GPG-manifest-verifies, and caches the
# binary, and shares it in RO. The guest only runs the already-verified binary.
set -euo pipefail

# Diagnostics go to /dev/console (the BOOT console, hvc0), which the host
# captures via vfkit virtio-serial,logFilePath (issue #87). claude's own
# stdin/stdout/stderr stay on this process's controlling tty (hvc1, the
# interactive console). Routing diagnostics to hvc0 keeps boot/seam noise OFF
# the interactive terminal AND keeps it observable in the host capture log
# (and lets the headless acceptance test, which captures only hvc0, still see
# the seam marker). Fall back to this process's stderr if /dev/console is not
# writable for any reason.
log() {
  if [ -w /dev/console ]; then
    printf '%s\n' "$*" > /dev/console
  else
    printf '%s\n' "$*" >&2
  fi
}

# Mount points provided by vfkit virtio-fs tags.
REPO_MNT=/mnt/repo
RUNCONFIG_MNT=/mnt/runconfig
# The host-verified claude binary's containing dir, shared under tag
# 'claudebin' and mounted here by the guest fstab.
CLAUDEBIN_MNT=/mnt/claudebin
# The host's claude.ai OAuth credential dir, shared RO under tag
# 'claudecreds' and mounted here by the guest fstab.
CLAUDECREDS_MNT=/mnt/claudecreds

# Load run environment (proxy, mount tags, geometry, renderer, CLAUDE_ARGS)
# written by the host launcher into the runconfig share. NOTE: run.env no
# longer carries any secret -- auth is the host's claude.ai OAuth credential,
# installed below from the RO claudecreds mount, not an ANTHROPIC_API_KEY here.
# set -a exports every var it defines, so the renderer controls
# (CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN / CLAUDE_CODE_NO_FLICKER, written by
# the host when claude.renderer is set -- issue #88) are exported into claude's
# environment for free.
set -a
# shellcheck disable=SC1091
. "$RUNCONFIG_MNT/run.env"
set +a

# ---------------------------------------------------------------------
# Auth: install the host's claude.ai OAuth credential (issue #50).
#
# The host read its live claude.ai login from the macOS Keychain, SELECTED
# only the `claudeAiOauth` key from it (dropping any unrelated mcpOAuth and
# other siblings -- see claude-vm.sh), and shared the resulting
# `{"claudeAiOauth": {...}}` file RO into the guest under mountTag=claudecreds.
# claude reads its credential from $HOME/.claude/.credentials.json, so copy
# the mounted file there (mode 0600). The RO virtio-fs mount cannot itself BE
# that writable per-user file, so we copy it into place rather than symlink:
# claude expects a real, owner-only file at that path. This gives the guest
# the host operator's full-scope claude.ai login, which Remote Control requires.
#
# claude runs as the autologin getty's user (root, via serial-getty@hvc1), so
# $HOME is that user's home. Derive the credential dir from $HOME so the
# path tracks whatever user claude runs as.
# ---------------------------------------------------------------------
MOUNTED_CREDENTIAL="$CLAUDECREDS_MNT/.credentials.json"
if [ ! -s "$MOUNTED_CREDENTIAL" ]; then
  log "claude-vm: no claude.ai OAuth credential found at $MOUNTED_CREDENTIAL"
  log "claude-vm: (mountTag=claudecreds). The host did not share a credential; claude"
  log "claude-vm: cannot authenticate. Ensure you are logged in to Claude Code on the host."
  exit 1
fi
CLAUDE_HOME="${HOME:-/root}"
CRED_DIR="$CLAUDE_HOME/.claude"
mkdir -p "$CRED_DIR"
# The mounted file is the host-selected claudeAiOauth-only credential; copy it
# verbatim into place (the host already did the selection), then tighten perms.
cp "$MOUNTED_CREDENTIAL" "$CRED_DIR/.credentials.json"
chmod 600 "$CRED_DIR/.credentials.json"
log "claude-vm: installed host claude.ai OAuth credential at $CRED_DIR/.credentials.json"

# ---------------------------------------------------------------------
# Auth: export the OAuth setup-token (issue #88).
#
# Current Claude Code does NOT treat the mounted ~/.claude/.credentials.json
# above as pre-authenticated -- it runs its interactive login flow, which is
# unusable on this byte-pipe console. The documented headless-auth path is
# CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`). The host wrote that
# token into the SAME shred-on-exit claudecreds mount (mountTag=claudecreds)
# as the credential above -- NOT into run.env, honoring the launcher's
# "secrets never ride in run.env" invariant. Read it here and EXPORT it so it
# is in claude's environment before the `exec` below. The host launcher gates
# on the token being present (preflight), so its absence at boot is an
# unexpected state -- abort rather than fall through to the unusable login flow.
MOUNTED_OAUTH_TOKEN="$CLAUDECREDS_MNT/oauth-token"
if [ ! -s "$MOUNTED_OAUTH_TOKEN" ]; then
  log "claude-vm: no OAuth setup-token found at $MOUNTED_OAUTH_TOKEN (mountTag=claudecreds)."
  log "claude-vm: the host did not share a CLAUDE_CODE_OAUTH_TOKEN; claude would fall back to"
  log "claude-vm: its interactive login flow, which is unusable on this console. Aborting."
  exit 1
fi
CLAUDE_CODE_OAUTH_TOKEN="$(cat "$MOUNTED_OAUTH_TOKEN")"
export CLAUDE_CODE_OAUTH_TOKEN
log "claude-vm: exported CLAUDE_CODE_OAUTH_TOKEN from the host (setup-token auth)."

# ---------------------------------------------------------------------
# claude-fetch SEAM -- FILLED (issue #49).
#
# This is the boundary where the guest obtains `claude`. The trusted path
# is: the HOST resolves the requested channel/pin to a concrete version,
# downloads that version's GPG-signed manifest, verifies the signature
# against the operator's pinned key, checksum-verifies the binary against
# the verified manifest, caches it keyed on the version, and shares it RO
# into the guest under mountTag=claudebin. So by the time the guest boots,
# the binary at $CLAUDEBIN_MNT/claude is ALREADY verified -- the guest runs
# it directly and never executes `curl https://claude.ai/install.sh | bash`
# (which is unsigned, unchecksummed, and re-fetched on every boot; see
# issue #57's "root of trust" analysis). There is no install.sh|bash
# fallback: the host-verified binary is the ONLY path, and a missing
# verified binary aborts the boot rather than fetching unverified code.
#
# The seam message is retained (now reporting that the verified binary was
# found) so the acceptance test can still observe the guest reaching this
# point.
# ---------------------------------------------------------------------
CLAUDE_BIN="$CLAUDEBIN_MNT/claude"
if [ ! -x "$CLAUDE_BIN" ]; then
  log "claude-vm: guest booted to the claude-fetch seam, but no verified claude binary"
  log "claude-vm: was found at $CLAUDE_BIN. The host-side verified cache mount"
  log "claude-vm: (mountTag=claudebin) is missing; refusing to fetch-and-run unverified code."
  # Fatal: the trusted path requires the host-verified binary. There is no
  # install.sh|bash fallback anywhere -- a missing verified binary aborts
  # the boot rather than fetching unverified code.
  exit 1
fi

log "claude-vm: guest booted to the claude-fetch seam; running host-verified claude from $CLAUDE_BIN."

# Seed the interactive tty geometry from the host (issue #88). The vfkit stdio
# console is a byte pipe with no out-of-band window-size channel, so the guest
# hvc1 tty comes up at a fixed 80x24 regardless of the host window. The host
# launcher captured its `stty size` into CLAUDE_VM_COLUMNS/CLAUDE_VM_LINES;
# apply them to THIS process's controlling tty (hvc1) so the kernel tty reports
# the right size to TIOCGWINSZ -- claude and any child it spawns then render at
# the host terminal's dimensions. One-time: the transport carries no live
# resize. Only run when both are present and numeric (empty when claude-vm was
# not launched from a real terminal -- then the guest keeps its 80x24 default).
if [ -n "${CLAUDE_VM_COLUMNS:-}" ] && [ -n "${CLAUDE_VM_LINES:-}" ] \
   && [ "$CLAUDE_VM_COLUMNS" -gt 0 ] 2>/dev/null \
   && [ "$CLAUDE_VM_LINES" -gt 0 ] 2>/dev/null; then
  stty cols "$CLAUDE_VM_COLUMNS" rows "$CLAUDE_VM_LINES" 2>/dev/null || true
  log "claude-vm: seeded hvc1 tty geometry to ${CLAUDE_VM_COLUMNS}x${CLAUDE_VM_LINES} from the host."
fi

cd "$REPO_MNT"
# shellcheck disable=SC2086
exec "$CLAUDE_BIN" $CLAUDE_ARGS
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
  # carrying boot-launcher.sh as the autologin serial-getty@hvc1 login program
  # (issue #88).
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
