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

# Reuse the launcher's canonical bake-hash helper (issue #105) so the version
# stamped here and the version the launcher compares against are computed by
# the SAME code over the SAME canonical bytes. config.sh is pure/sourceable
# (no VM, no network) -- see its header.
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

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
# Bumped 5 -> 6: identity seed auth (issue #88, pass 1). Real-hardware testing
# established that the interactive TUI does NOT read CLAUDE_CODE_OAUTH_TOKEN
# (that var is scoped to headless `claude -p`), so the setup-token path from
# rev 5 could not deliver zero-touch login and was ripped out. The TUI decides
# "logged in" from on-disk state: the token in ~/.claude/.credentials.json
# (already installed) PLUS identity in ~/.claude.json (`userID` +
# `oauthAccount`). The boot launcher now installs a minimal identity seed
# (claude-json-seed.json from the shred-on-exit claudecreds mount) at
# /root/.claude.json before exec'ing claude, so a fresh guest comes up already
# logged in. The boot-logic change requires old images (stamped 'launcher5')
# to rebuild.
# Bumped 6 -> 7: WIDENED identity seed (issue #88). Real-hardware testing found
# the {userID, oauthAccount} seed from rev 6 was insufficient: the guest TUI
# still hit its onboarding/login wall on every boot because the seed dropped
# `hasCompletedOnboarding`, and with `autoUpdates` unset the guest claude
# immediately tried (and failed) to self-update against its RO-mounted binary in
# the egress-confined VM. The seed now carries four MORE keys synthesized by the
# host launcher -- `hasCompletedOnboarding: true`, `autoUpdates: false`, and
# `lastOnboardingVersion` / `lastReleaseNotesSeen` stamped with the concrete
# resolved claude version -- alongside the host's `userID` / `oauthAccount`.
# machineID is still NOT seeded (the guest mints its own). The seed-install step
# in the boot launcher is UNCHANGED (still a plain cp of the seed to
# /root/.claude.json) -- only the seed's CONTENTS widened, host-side. The
# composite rev still bumps so stale guest images rebuild. The boot-logic change
# requires old images (stamped 'launcher6') to rebuild.
# Bumped 7 -> 8: satisfy claude's startup install-health check (issue #88).
# Real-hardware testing found the otherwise-clean interactive boot still printed two
# "claude command at /root/.local/bin/claude missing or broken · run claude install
# to repair" warnings: claude probes for a working `claude` at the native installer's
# ~/.local/bin/claude, but the guest execs the RO-mounted binary, leaving that path
# empty. The boot launcher now symlinks $CLAUDE_HOME/.local/bin/claude ->
# $CLAUDE_BIN (the verified RO-mounted binary) right after the claude-fetch seam
# validates the binary; the symlink target is the running binary itself, so the
# health check's version comparison passes by construction, and autoUpdates: false
# plus the RO mount prevent any write-through. Empirically confirmed to clear the
# warnings on real hardware. The boot-logic change requires old images (stamped
# 'launcher7') to rebuild.
# Bumped 8 -> 9: CLAUDE_ARGS shell-quoting round-trip (issue #88). Real-hardware
# testing found that a spaced/metacharacter-bearing arg (e.g.
# `--name "foo #7 micro-vm Claude Plugins"`) crashed the guest boot into an
# infinite getty-respawn loop: the old boot launcher exec'd `"$CLAUDE_BIN"
# $CLAUDE_ARGS` (unquoted word-split, SC2086-disabled), and the host wrote
# CLAUDE_ARGS as a flat unquoted join, so sourcing run.env re-split the value
# and tried to EXECUTE the `--name` fragment (with the `#...` comment-stripped).
# The boot launcher now reconstructs argv with `eval "set -- $CLAUDE_ARGS"` then
# `exec "$CLAUDE_BIN" "$@"`, exactly reversing the host's new per-arg-%q +
# outer-%q quoting (claude_vm_quote_args in lib/config.sh). The boot-logic change
# requires old images (stamped 'launcher8') to rebuild.
#
# Bumped 9 -> 10: guest settings.json install (issue #104). The boot launcher now
# installs the host-rendered ~/.claude/settings.json (permissions + defaultMode +
# enabledPlugins) from the claudecreds mount, and treats its ABSENCE as a hard
# abort (it is a security-posture file carrying the deny-list backstop -- booting
# without it would silently drop that backstop). This is a new boot-logic step,
# so old images (stamped 'launcher9') must rebuild to gain it.
# Bumped 10 -> 11: boot-time package install/update through the proxy (issue
# #106). The boot launcher now runs a new BLOCKING phase, right before the
# claude-fetch seam: (1) when CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT=true (the
# run.env default), `apt-get update` + `apt-get -y upgrade`; (2) when
# apt-install.list (from the runconfig mount) is nonempty, render any
# apt-sources.tsv entries into the guest's live /etc/apt (reusing the #105
# render_apt_source shape, now inlined here since the guest has no python3),
# then `apt-get -y install` the listed packages. Both steps proxy through
# Acquire::http::Proxy / Acquire::https::Proxy pointed at the SAME
# HTTP_PROXY/HTTPS_PROXY run.env already carries. A failed install/update
# prints a loud warning to the hvc0 diagnostic log and CONTINUES to claude --
# a failed optional install must never brick an interactive session. This is
# a new boot-logic step, so old images (stamped 'launcher10') must rebuild to
# gain it.
# Bumped 11 -> 12: bake `apt` into the base Packages= list (issue #106 real-run
# fix). A real guest boot found boot_apt_phase (added in the 10 -> 11 bump)
# failing on every apt-get call with "command not found": mkosi installs
# packages from OUTSIDE the image with its own (build-container) apt, so
# nothing ever pulled apt/dpkg tooling INTO the guest rootfs -- the base
# Packages= list (provisioners/podman-mkosi.sh) never named it. `apt` is now
# baked UNCONDITIONALLY, not gated on whether boot-time apt work is
# configured, because packages.update_at_boot defaults to true (so nearly
# every config needs it), the security boundary for a hard-secure all-baked
# config is the egress allowlist (mirrors left unreachable), not the absence
# of the apt binary, and the add_apt_uris_to_allowlist: always mid-session-
# install path is only honest if apt exists. This is a base-image CONTENT
# change (not boot-logic code), but it still must invalidate every cached
# image built before it -- including images already built at rev 11 without
# apt -- so old images (stamped 'launcher11') must rebuild to gain it.
# Bumped 12 -> 13: second real-run pass (issue #106) -- mid-session apt
# proxying, apt metadata/cache diet, and root-partition headroom. A real
# guest boot found THREE more problems past the 11 -> 12 apt-bake fix: (1) an
# INTERACTIVE (not boot-launcher) `apt-get install` got no proxy at all --
# apt honors only lowercase http_proxy/https_proxy (run.env carried only the
# uppercase forms) and curl ignores uppercase HTTP_PROXY for plain http://
# URLs; fixed by exporting lowercase mirrors in run.env (claude-vm.sh) AND
# writing a persistent /etc/apt/apt.conf.d/99claude-vm-proxy from the boot
# launcher so EVERY apt-get for the rest of the boot is proxied regardless of
# environment. (2) boot_apt_phase's apt-get update was re-materializing
# ~250 MB of working set (mkosi's default deb-src/debian-debug/Translation
# lists plus pkgcache.bin/srcpkgcache.bin) on EVERY boot, exhausting the
# small root twice in one session; fixed by a binary-only/no-debug/no-
# Translations apt metadata diet baked into the image (podman-mkosi.sh's
# mkosi.skeleton/ apt sources + apt.conf.d) plus a defensive `apt-get clean`
# at the end of boot_apt_phase, dropping the per-boot working set to
# ~50 MB. (3) the root partition had NO configured minimum size (mkosi's own
# Minimize=guess default, verified against mkosi v26 source), leaving near-
# zero margin for session growth even after the (2) diet; fixed by a new
# image.root_headroom_mb config knob wired into a custom mkosi.repart/ (see
# lib/config.sh, podman-mkosi.sh). (1) and the apt.conf.d half of (2) are
# BOOT-LOGIC changes; (2)'s baked sources/apt.conf.d and (3) are base-image
# CONTENT changes -- all three still require every cached image (baked-apt
# rev 12 included) to rebuild, so old images (stamped 'launcher12') rebuild
# on next use.
LAUNCHER_LOGIC_REV="13"
BASE_PINNED_VERSION="${BASE_OS_REV}+launcher${LAUNCHER_LOGIC_REV}"

# ---------------------------------------------------------------------
# Bake-hash image variants (issue #105).
#
# The base version above pins the OS + launcher logic. On top of it, the
# guest image now bakes packages.bake (extra apt packages) and renders
# packages.apt_sources (third-party apt repos) into the build. Two configs
# that bake different things must produce DIFFERENT images, so the version --
# which is the image cache key -- gains a bake-hash SEGMENT derived from the
# bake-relevant config.
#
# The launcher passes the CANONICAL bake config (claude_vm_bake_config_json,
# order-normalized compact JSON) in CLAUDE_VM_BAKE_CONFIG. We hash it with the
# SAME helper the launcher uses (claude_vm_bake_hash_from_json), so
# --print-version here and the launcher's variant derivation agree by
# construction. When the bake config is EMPTY (the canonical
# `{"bake":[],"apt_sources":[]}`, i.e. no bake-affecting overrides), NO segment
# is appended -- the version stays the legacy `BASE+launcherN`, so such configs
# share the one global image and never rebuild on this account. A non-empty
# bake config appends `+bake<hash>`, giving that config its own cached variant.
#
# CLAUDE_VM_BAKE_CONFIG unset/empty is treated as "no bake config" -- the base
# version, unchanged. This keeps a bare `build-guest-image.sh --print-version`
# (no launcher, e.g. a smoke test) working and pinned to the legacy version.
CLAUDE_VM_EMPTY_BAKE_CONFIG='{"bake":[],"apt_sources":[]}'

# Root headroom (issue #106 real-run fix). image.root_headroom_mb sizes the
# guest root partition (base usage + this many MiB of free space -- see the
# [Content] mkosi.repart/ definition below), so it changes the CONTENT of the
# produced image just like a bake override does, and must participate in the
# same image cache key: two configs with different headroom must not share a
# cached image (a smaller headroom baked into an already-built larger image
# would just be silently ignored; a larger headroom needs an actual rebuild
# to grow the partition). Kept as its OWN version segment -- not folded into
# CLAUDE_VM_BAKE_CONFIG/the bake-hash -- because the bake-hash's "empty
# config" invariant (a config with no packages.bake/apt_sources ALWAYS
# collides on the one shared image) is load-bearing and exercised by
# extensive existing coverage; adding an unrelated key to that canonical form
# risks disturbing it. CLAUDE_VM_ROOT_HEADROOM_MB unset/empty defaults to the
# launcher's own default (CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB in
# lib/config.sh) so a bare --print-version smoke test (no launcher) still
# resolves to a concrete value. Mirrors the bake-hash's own "no segment for
# the common/default case" shape: only a headroom that DIFFERS from the
# default appends a `+headroomN` segment, so the overwhelming common case
# (nobody overrides the default) keeps sharing the one legacy-named image.
CLAUDE_VM_DEFAULT_ROOT_HEADROOM_MB="$CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB"
ROOT_HEADROOM_MB="${CLAUDE_VM_ROOT_HEADROOM_MB:-$CLAUDE_VM_DEFAULT_ROOT_HEADROOM_MB}"
case "$ROOT_HEADROOM_MB" in
  ''|*[!0-9]*)
    echo "build-guest-image: CLAUDE_VM_ROOT_HEADROOM_MB must be a positive integer (MiB), got '$ROOT_HEADROOM_MB'" >&2
    exit 1
    ;;
esac

compute_pinned_version() {
  local bake_config="${CLAUDE_VM_BAKE_CONFIG:-}"
  local version="$BASE_PINNED_VERSION"
  if [ -n "$bake_config" ] && [ "$bake_config" != "$CLAUDE_VM_EMPTY_BAKE_CONFIG" ]; then
    local hash
    hash="$(claude_vm_bake_hash_from_json "$bake_config")" || return 1
    version="${version}+bake${hash}"
  fi
  if [ "$ROOT_HEADROOM_MB" != "$CLAUDE_VM_DEFAULT_ROOT_HEADROOM_MB" ]; then
    version="${version}+headroom${ROOT_HEADROOM_MB}"
  fi
  printf '%s\n' "$version"
}
PINNED_VERSION="$(compute_pinned_version)" \
  || { echo "build-guest-image: failed to compute bake-hash version" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage:
  build-guest-image.sh --print-version
  build-guest-image.sh --output <image-path>

The bake-relevant config (canonical JSON from the launcher) is read from the
CLAUDE_VM_BAKE_CONFIG environment variable; unset/empty means no baked
packages (the legacy base image). The root-partition headroom (MiB) is read
from CLAUDE_VM_ROOT_HEADROOM_MB; unset/empty defaults to
CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB (lib/config.sh).
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
# operator (issue #50) AND the host's identity seed (userID + oauthAccount +
# synthesized onboarding/auto-update/version keys, benign host UI keys, and a
# /mnt/repo projects entry that skips the trust dialog) into $HOME/.claude.json
# so the interactive TUI comes up already onboarded + logged in (issue #88) AND
# the host-rendered settings.json (permissions allow/ask/deny + defaultMode +
# enabledPlugins) into $HOME/.claude/settings.json (issue #104), seeds
# the tty geometry from the host (issue #88), then
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
# The dir of ALL host-rendered guest ~/.claude files, shared RO under tag
# 'claudecreds' and mounted here by the guest fstab. It carries the OAuth
# credential (.credentials.json, a SECRET), the identity seed
# (claude-json-seed.json, account identity), and the rendered settings.json
# (permissions + enabledPlugins, NOT a secret) -- not credentials alone. The
# boot launcher installs each into $HOME/.claude/ below.
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
# Auth: install the host's identity seed (issue #88).
#
# The mounted ~/.claude/.credentials.json above is only the BEARER TOKEN. The
# interactive guest TUI also decides "am I onboarded / logged in" from state in
# ~/.claude.json. A fresh throwaway guest lacks it, so without this seed every
# launch shows the onboarding/login wall despite the credential. The host built
# the seed from its own ~/.claude.json -- selecting `userID` + `oauthAccount`,
# synthesizing `hasCompletedOnboarding: true` (skip the wall), `autoUpdates:
# false` (no self-update in the egress-confined guest against the RO-mounted
# binary), and `lastOnboardingVersion` / `lastReleaseNotesSeen` stamped with the
# resolved claude version; additively carrying benign host UI keys when present
# (installMethod, hasSeenTasksHint, hasUsedStash, tipsHistory); and seeding a
# `projects` entry for /mnt/repo with hasTrustDialogAccepted /
# hasCompletedProjectOnboarding forced true so the guest skips the "trust this
# folder?" dialog -- and shared that object into the SAME shred-on-exit
# claudecreds mount (mountTag=claudecreds) as the credential above, NOT via
# run.env, honoring the launcher's "secrets never ride in run.env" invariant.
# machineID is NOT in the seed -- the guest mints its own on first run. Install
# it at $CLAUDE_HOME/.claude.json (mode 0600) before the `exec` below.
# /root/.claude.json does not exist on a fresh guest, so this is a plain create
# of the object (no merge). The seed's CONTENTS are the host's business; this
# step just copies whatever the host emitted.
#
# ADDITIVE: unlike the credential above (a hard requirement), a missing seed is
# logged and tolerated -- the guest still boots (it just shows the onboarding/
# login wall). The host launcher gates on the seed being present (preflight),
# so its absence here is unexpected but not worth aborting an otherwise-bootable
# guest.
MOUNTED_CLAUDE_JSON_SEED="$CLAUDECREDS_MNT/claude-json-seed.json"
if [ -s "$MOUNTED_CLAUDE_JSON_SEED" ]; then
  cp "$MOUNTED_CLAUDE_JSON_SEED" "$CLAUDE_HOME/.claude.json"
  chmod 600 "$CLAUDE_HOME/.claude.json"
  log "claude-vm: installed host identity seed at $CLAUDE_HOME/.claude.json (identity + onboarding state)."
else
  log "claude-vm: no identity seed found at $MOUNTED_CLAUDE_JSON_SEED (mountTag=claudecreds);"
  log "claude-vm: continuing without it -- claude may show its onboarding/login wall on this console."
fi

# ---------------------------------------------------------------------
# Settings: install the host-rendered guest settings.json (issue #104).
#
# The host rendered /root/.claude/settings.json from the merged claude-vm config
# -- the permission allow/ask/deny lists, permissions.defaultMode
# (claude.permission_mode, YOLO-by-default bypassPermissions), and the
# enabledPlugins object (every claude.plugins.bake ++ install_at_boot ref
# defaults enabled; claude.plugins.enabled overrides per plugin) -- and shared it
# into the SAME claudecreds mount as the credential + seed above. Those
# permissions come from the claude-vm configs ONLY; the host's
# ~/.claude/settings.json is never consulted (the VM deliberately runs its own,
# possibly riskier, posture). claude reads its settings from
# $HOME/.claude/settings.json, so copy the mounted file there. The RO virtio-fs
# mount cannot BE that file, so copy (don't symlink), the same as the credential
# above. $CRED_DIR ($CLAUDE_HOME/.claude) already exists from the credential
# install above.
#
# HARD ABORT when absent, exactly like the credential above (NOT tolerated). The
# rendered settings.json is a SECURITY-POSTURE file: it carries the deny-list
# backstop that constrains the guest even under bypassPermissions. Booting
# without it silently drops that backstop -- claude would fall back to its own
# built-in defaults with no configured allow/ask/deny -- which is exactly the
# unsafe state this guest must never enter. The host launcher always renders one,
# so absence here means something is wrong upstream; refuse to boot rather than
# run the guest with a weaker posture than the operator configured.
MOUNTED_GUEST_SETTINGS="$CLAUDECREDS_MNT/settings.json"
if [ ! -s "$MOUNTED_GUEST_SETTINGS" ]; then
  log "claude-vm: no rendered settings.json found at $MOUNTED_GUEST_SETTINGS"
  log "claude-vm: (mountTag=claudecreds). This is a security-posture file (the deny-list"
  log "claude-vm: backstop); refusing to boot without it. The host launcher should always"
  log "claude-vm: render one -- this indicates a launcher fault."
  exit 1
fi
cp "$MOUNTED_GUEST_SETTINGS" "$CRED_DIR/settings.json"
chmod 600 "$CRED_DIR/settings.json"
log "claude-vm: installed host-rendered guest settings at $CRED_DIR/settings.json (permissions + enabledPlugins)."

# ---------------------------------------------------------------------
# Boot-time package install/update through the proxy (issue #106).
#
# BLOCKING, before claude execs (agreed in the issue: if a package is too
# slow to install at boot, the user moves it from install_at_boot to bake).
#
#   1. CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT=true (run.env, default true):
#      `apt-get update` + `apt-get -y upgrade`.
#   2. apt-install.list (runconfig mount) nonempty: render any
#      apt-sources.tsv entries into the guest's LIVE /etc/apt (reusing the
#      #105 render_apt_source shape -- inlined here, not sourced, because the
#      guest has no python3/jq to parse a JSON manifest; see the [Content]
#      Packages= list in provisioners/podman-mkosi.sh), then
#      `apt-get -y install <list>`.
#
# Both apt-get invocations proxy through Acquire::http::Proxy /
# Acquire::https::Proxy pointed at the SAME HTTP_PROXY/HTTPS_PROXY run.env
# already exported above (set -a), rather than relying on apt's env-var
# pickup, which is not guaranteed across apt versions -- an explicit -o flag
# always wins.
#
# PERSISTENT proxy drop-in (issue #106 real-run fix). The -o flags above only
# cover apt-get invocations THIS phase makes; a real guest boot found a
# MID-SESSION `apt-get install` (run interactively by the in-guest claude,
# not by this launcher) got NO proxy at all -- run.env carried only uppercase
# HTTP_PROXY/HTTPS_PROXY, which apt-get never reads (it honors only lowercase
# http_proxy/https_proxy, and even that env pickup is not guaranteed across
# apt versions per the comment above). The host now also exports lowercase
# http_proxy/https_proxy/no_proxy in run.env (claude-vm.sh), but that still
# only helps a shell that re-sources run.env -- an interactive login shell on
# hvc1 does not. Write a real apt.conf.d drop-in so EVERY apt-get invocation
# for the rest of this boot -- this phase's, and any later interactive one --
# is proxied regardless of environment. Written before boot_apt_phase runs so
# its own apt-get calls also pick it up (making the -o flags above redundant
# but harmless defense-in-depth, kept as-is as agreed).
if [ -n "${HTTP_PROXY:-}" ] || [ -n "${HTTPS_PROXY:-}" ]; then
  {
    [ -n "${HTTP_PROXY:-}" ]  && printf 'Acquire::http::Proxy "%s";\n' "$HTTP_PROXY"
    [ -n "${HTTPS_PROXY:-}" ] && printf 'Acquire::https::Proxy "%s";\n' "$HTTPS_PROXY"
  } > /etc/apt/apt.conf.d/99claude-vm-proxy
  log "claude-vm: wrote persistent apt proxy config to /etc/apt/apt.conf.d/99claude-vm-proxy."
fi
#
# FAILURE POLICY: a failed update/install prints a loud warning to the hvc0
# diagnostic log (log(), same as every other boot diagnostic) and CONTINUES
# -- a failed optional install must never brick an interactive session. This
# whole phase is therefore wrapped so no `apt-get` exit status escapes under
# `set -e`.
APT_INSTALL_LIST="$RUNCONFIG_MNT/apt-install.list"
APT_SOURCES_TSV="$RUNCONFIG_MNT/apt-sources.tsv"
APT_PROXY_OPTS=()
if [ -n "${HTTP_PROXY:-}" ]; then
  APT_PROXY_OPTS+=(-o "Acquire::http::Proxy=$HTTP_PROXY")
fi
if [ -n "${HTTPS_PROXY:-}" ]; then
  APT_PROXY_OPTS+=(-o "Acquire::https::Proxy=$HTTPS_PROXY")
fi

# render_apt_source_boot: the #105 keyring-fetch + sources.list.d-write unit
# (podman-mkosi.sh's render_apt_source), reused against the guest's LIVE
# /etc/apt at boot instead of a build-time mkosi sandbox tree -- the reuse
# the #105 comment on render_apt_source names this slice by issue number.
# Same case matrix (no [options] block / block without signed-by / block
# WITH signed-by already pinned / no key / non-deb line), same name/path
# validation (charset-safe name; a pinned signed-by path is constrained to
# /etc/apt/keyrings or /usr/share/keyrings with a charset-safe filename and
# no '..' segment) -- ported to plain bash (no python3 in the guest) and
# collapsed to ONE directory tree (keyrings_dir == sources_dir's sibling ==
# the live runtime path) since there is no staging/runtime split at boot.
render_apt_source_boot() {
  local name="$1" repo="$2" key_url="$3"
  local keyrings_dir="/etc/apt/keyrings" sources_dir="/etc/apt/sources.list.d"
  if [ -z "$name" ] || [ -z "$repo" ]; then
    log "claude-vm: boot apt_source entry missing name or repo; skipping"
    return 1
  fi
  case "$name" in
    *[!A-Za-z0-9._-]*)
      log "claude-vm: boot apt_source name '$name' contains characters outside [A-Za-z0-9._-]; skipping"
      return 1
      ;;
  esac
  mkdir -p "$keyrings_dir" "$sources_dir"
  local keyring_path="$keyrings_dir/${name}.asc"

  local is_deb_line=0 has_block=0 block_has_signed_by=0 existing_signed_by=""
  if [[ "$repo" =~ ^(deb|deb-src)([[:space:]]+)\[([^]]*)\](.*)$ ]]; then
    is_deb_line=1
    has_block=1
    local block_body="${BASH_REMATCH[3]}"
    if [[ "$block_body" =~ (^|[[:space:]])signed-by=([^[:space:]]+) ]]; then
      block_has_signed_by=1
      existing_signed_by="${BASH_REMATCH[2]}"
    fi
  elif [[ "$repo" =~ ^(deb|deb-src)[[:space:]] ]]; then
    is_deb_line=1
  fi

  local have_key=0
  if [ -n "$key_url" ]; then
    if [ "$is_deb_line" -eq 1 ] && [ "$has_block" -eq 1 ] && [ "$block_has_signed_by" -eq 1 ]; then
      case "$existing_signed_by" in
        /*) : ;;
        *)
          log "claude-vm: boot apt_source '$name' signed-by path '$existing_signed_by' is not absolute; skipping"
          return 1
          ;;
      esac
      case "$existing_signed_by" in
        *[[:space:]]*|*']'*)
          log "claude-vm: boot apt_source '$name' signed-by path '$existing_signed_by' contains disallowed characters; skipping"
          return 1
          ;;
      esac
      local seg
      local old_ifs="$IFS"
      IFS=/
      for seg in $existing_signed_by; do
        if [ "$seg" = ".." ]; then
          IFS="$old_ifs"
          log "claude-vm: boot apt_source '$name' signed-by path '$existing_signed_by' contains a '..' path segment; skipping"
          return 1
        fi
      done
      IFS="$old_ifs"
      case "$existing_signed_by" in
        /etc/apt/keyrings/*|/usr/share/keyrings/*)
          local kr_file="${existing_signed_by##*/}"
          case "$kr_file" in
            *[!A-Za-z0-9._-]*|"")
              log "claude-vm: boot apt_source '$name' signed-by path '$existing_signed_by' has a filename outside [A-Za-z0-9._-]; skipping"
              return 1
              ;;
          esac
          local kr_parent="${existing_signed_by%/*}"
          if [ "$kr_parent" != "/etc/apt/keyrings" ] && [ "$kr_parent" != "/usr/share/keyrings" ]; then
            log "claude-vm: boot apt_source '$name' signed-by path '$existing_signed_by' is not directly under an allowed keyrings directory; skipping"
            return 1
          fi
          ;;
        *)
          log "claude-vm: boot apt_source '$name' signed-by path '$existing_signed_by' is outside the allowed keyrings directories (/etc/apt/keyrings, /usr/share/keyrings); skipping"
          return 1
          ;;
      esac
      mkdir -p "$(dirname "$existing_signed_by")"
      keyring_path="$existing_signed_by"
    fi
    # curl (unlike apt-get) does not take -o Acquire::...=... proxy flags; it
    # already honors the HTTP_PROXY/HTTPS_PROXY env vars run.env exported
    # above (set -a), so no explicit proxy flag is needed here.
    if ! curl -fsSL "$key_url" -o "$keyring_path"; then
      log "claude-vm: failed to fetch boot apt_source key for '$name' from $key_url"
      return 1
    fi
    have_key=1
  fi

  local line
  if [ "$have_key" -eq 1 ] && [ "$is_deb_line" -eq 1 ] && [ "$has_block" -eq 1 ] && [ "$block_has_signed_by" -eq 1 ]; then
    line="$repo"
  elif [ "$have_key" -eq 1 ] && [ "$is_deb_line" -eq 1 ] && [ "$has_block" -eq 1 ]; then
    if [[ "$repo" =~ ^(deb|deb-src)([[:space:]]+)\[([^]]*)\](.*)$ ]]; then
      local tok="${BASH_REMATCH[1]}" ws="${BASH_REMATCH[2]}" body="${BASH_REMATCH[3]}" rest="${BASH_REMATCH[4]}"
      line="${tok}${ws}[${body} signed-by=${keyring_path}]${rest}"
    else
      line="$repo"
    fi
  elif [ "$have_key" -eq 1 ] && [ "$is_deb_line" -eq 1 ]; then
    line="$(printf '%s' "$repo" | awk -v sb="$keyring_path" '{
      printf "%s [signed-by=%s]", $1, sb; for(i=2;i<=NF;i++) printf " %s", $i; print ""
    }')"
  else
    line="$repo"
  fi
  printf '%s\n' "$line" > "$sources_dir/${name}.list"
  log "claude-vm: rendered boot apt_source '$name' -> $sources_dir/${name}.list"
}

boot_apt_phase() {
  local did_update=0

  if [ "${CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT:-true}" = "true" ]; then
    log "claude-vm: boot-time apt: running 'apt-get update' + 'apt-get -y upgrade' (packages.update_at_boot)."
    if apt-get "${APT_PROXY_OPTS[@]+"${APT_PROXY_OPTS[@]}"}" update -qq \
        && DEBIAN_FRONTEND=noninteractive apt-get "${APT_PROXY_OPTS[@]+"${APT_PROXY_OPTS[@]}"}" -y -qq upgrade; then
      did_update=1
    else
      log "claude-vm: WARNING -- boot-time 'apt-get update/upgrade' failed; continuing to claude with the image as-is."
    fi
  fi

  if [ -s "$APT_INSTALL_LIST" ]; then
    log "claude-vm: boot-time apt: rendering apt_sources for install_at_boot."
    if [ -s "$APT_SOURCES_TSV" ]; then
      while IFS=$'\t' read -r as_name as_repo as_key_url; do
        [ -n "$as_name" ] || continue
        render_apt_source_boot "$as_name" "$as_repo" "$as_key_url" || true
      done < "$APT_SOURCES_TSV"
      if [ "$did_update" -eq 0 ]; then
        # A newly-rendered apt_source needs its own index fetched before
        # install can see its packages, even when update_at_boot is false.
        apt-get "${APT_PROXY_OPTS[@]+"${APT_PROXY_OPTS[@]}"}" update -qq \
          || log "claude-vm: WARNING -- boot-time 'apt-get update' (for newly rendered apt_sources) failed; install below may fail to find those packages."
      fi
    fi
    local install_packages=()
    while IFS= read -r pkg; do
      [ -n "$pkg" ] && install_packages+=("$pkg")
    done < "$APT_INSTALL_LIST"
    if [ "${#install_packages[@]}" -gt 0 ]; then
      log "claude-vm: boot-time apt: installing packages.install_at_boot: ${install_packages[*]}"
      if ! DEBIAN_FRONTEND=noninteractive apt-get "${APT_PROXY_OPTS[@]+"${APT_PROXY_OPTS[@]}"}" -y -qq install "${install_packages[@]}"; then
        log "claude-vm: WARNING -- boot-time 'apt-get install' failed for one or more of: ${install_packages[*]}; continuing to claude without them."
      fi
    fi
  fi

  # `apt-get clean` (issue #106 real-run fix). Empirically verified (real
  # `apt-get update` + install + clean, in a throwaway Debian container, with
  # the docker-supplied Dir::Cache::pkgcache override removed so the test sees
  # native apt behavior): `apt-get clean` deletes every fetched .deb under
  # /var/cache/apt/archives/ AND both /var/cache/apt/pkgcache.bin and
  # srcpkgcache.bin (36 MB each in that test) -- the exact ~88 MB pkgcache
  # working set that reappears on every `apt-get update`/`install` call
  # regardless of the Dir::Cache::pkgcache "" drop-in baked into the image
  # (podman-mkosi.sh): that drop-in stops the .bin files from being WRITTEN in
  # the first place, but a defensive `clean` here still catches anything that
  # slips through (e.g. an operator override of the drop-in). `clean` does NOT
  # touch /var/lib/apt/lists (verified same test: unchanged before/after) --
  # that ~50 MB (post apt-diet) is the index data apt needs for the NEXT
  # `apt-get install` to resolve packages without re-running `update`, so it
  # must survive to the interactive session. Run unconditionally (whether or
  # not update/install actually ran above) and outside the `if` gates so a
  # stray .bin regenerated by an earlier failed/partial call is still swept;
  # `|| true` keeps this from ever escaping under `set -e` (same failure
  # policy as the rest of this phase -- boot must never brick on a cleanup
  # step).
  apt-get clean || true
}
boot_apt_phase

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

# Satisfy claude's startup install-health check (issue #88). claude probes for a
# working `claude` at the native installer's location ~/.local/bin/claude; the
# guest execs the RO-mounted binary instead, so that path is empty and the TUI
# prints "claude command at /root/.local/bin/claude missing or broken · run
# claude install to repair" warnings on startup. Point the native-install path at
# the verified RO-mounted binary: the symlink target IS the running binary, so any
# version comparison passes by construction, and the seeded autoUpdates: false plus
# the RO mount prevent write-through. ln -sf (not bare -s) because this launcher
# re-runs on every getty respawn within a VM run and the link may already exist.
# Empirically confirmed to clear the warnings on real hardware (issue #88).
mkdir -p "$CLAUDE_HOME/.local/bin"
ln -sf "$CLAUDE_BIN" "$CLAUDE_HOME/.local/bin/claude"
log "claude-vm: linked native-install path $CLAUDE_HOME/.local/bin/claude -> $CLAUDE_BIN (install-health check)."

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
# Reconstruct claude's argv from CLAUDE_ARGS (issue #88). The host launcher
# (claude-vm.sh) writes CLAUDE_ARGS via claude_vm_quote_args (lib/config.sh):
# each original arg is %q-quoted and space-joined, then the whole run.env LINE
# is %q-quoted again so `set -a; . run.env` above assigns CLAUDE_ARGS to
# EXACTLY that per-arg-%q string (no re-splitting, no `#` comment-stripping).
# `eval set --` re-parses those tokens back into the original argv -- exactly
# reversing the host's quoting -- so args with spaces / shell metacharacters /
# `#` (e.g. --name "foo #7 micro-vm Claude Plugins") round-trip intact instead
# of crashing the getty login program into an agetty respawn loop. An empty
# CLAUDE_ARGS ('') yields `set -- ` -> zero argv. The two halves of this
# contract are kept in lockstep with the claude_vm_quote_args comment.
eval "set -- ${CLAUDE_ARGS:-}"
exec "$CLAUDE_BIN" "$@"
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
  # duplicating the version. Export the CANONICAL bake config (issue #105) so
  # the provisioner renders packages.bake into the mkosi Packages= list and
  # packages.apt_sources into keyring + sources.list.d drop-ins -- it hashed
  # into PINNED_VERSION above, so the built image's contents and its stamped
  # version stay in lockstep. Unset/empty means no baked packages. Export the
  # resolved root headroom (issue #106 real-run fix) so the provisioner sizes
  # the root partition's mkosi.repart/ SizeMinBytes= from it -- it also hashed
  # into PINNED_VERSION above (when non-default), so a headroom change forces
  # a rebuild the same way a bake change does.
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
  CLAUDE_VM_BAKE_CONFIG="${CLAUDE_VM_BAKE_CONFIG:-}" \
  CLAUDE_VM_ROOT_HEADROOM_MB="$ROOT_HEADROOM_MB" \
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
