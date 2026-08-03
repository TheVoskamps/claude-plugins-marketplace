#!/usr/bin/env bash
#
# claude-vm.sh -- launch Claude Code inside an isolated Linux micro-VM on macOS.
#
# Config-driven replacement for the original env-var launcher. Every
# non-secret operational knob (cpus, mem, guest_image, proxy, egress
# allowlist, extra mounts, repo mount strategy) comes from FOUR optional YAML
# files (issue #179): a bake file and a boot file per tier --
#
#   global bake: ~/.config/claude-vm/config-bake.yml   (machine-wide, image bytes)
#   global boot: ~/.config/claude-vm/config-boot.yml   (machine-wide, run time)
#   repo   bake: <repo>/.claude-vm/config-bake.yml     (project-specific, image bytes)
#   repo   boot: <repo>/.claude-vm/config-boot.yml     (project-specific, run time)
#
# A key that changes bytes in the guest .raw image lives in a bake file; a key
# applied at run time lives in a boot file. Scalars: repo overrides global.
# Lists (egress.allow, mounts): union. A legacy single-file config.yml (either
# tier) is not read -- see claude_vm_detect_legacy_config below. See
# payload/lib/config.sh for the layering implementation and
# skills/claude-vm/SKILL.md for the full config schema.
#
# AUTH: the guest authenticates with the HOST's live claude.ai OAuth
# credential, not a scoped API token. At launch the launcher reads the
# raw blob from the macOS login Keychain
# (`security find-generic-password -s "Claude Code-credentials" -w`) and
# selects ONLY the `claudeAiOauth` key from it (the blob can also carry
# unrelated `mcpOAuth` MCP-server credentials, which are dropped -- see
# the selection block below). The selected `{"claudeAiOauth": {...}}` is
# written to a transient, owner-only tmpfile and shared RO into the guest
# so it lands at the guest user's ~/.claude/.credentials.json. This gives
# the guest the host operator's full-scope claude.ai login, which Remote
# Control requires. The credential is NEVER written to config, to the
# verified-binary cache, or into run.env, and the tmpfile is removed on exit.
#
# IDENTITY SEED (issue #88): the mounted ~/.claude/.credentials.json bearer
# token alone does NOT make the interactive guest TUI treat itself as onboarded
# + logged in -- it also needs the right ~/.claude.json state, which a fresh
# throwaway guest lacks, so every launch shows the onboarding/login wall. So
# the launcher ALSO builds a seed from the host's ~/.claude.json: it selects
# ONLY `userID` + `oauthAccount` from the host and synthesizes four more keys
# -- `hasCompletedOnboarding: true` (skip the wall), `autoUpdates: false` (no
# self-update in the egress-confined guest), and `lastOnboardingVersion` /
# `lastReleaseNotesSeen` stamped with the concrete resolved claude version.
# machineID is NOT seeded -- the guest mints its own. The resulting 6-key object
# is delivered to the guest the SAME transient RO shred-on-exit way as the
# keychain credential (via the claudecreds mount, NEVER via run.env). The guest
# boot launcher installs it at /root/.claude.json before launching claude. This
# seed is ADDITIVE and layered alongside the keychain credential mount above.
#
# Usage:
#   claude-vm.sh <repo-path> [claude args...]
#
# Requires: yq, git, gvproxy, vfkit, podman (with a started machine),
# and a forward proxy (proxy.cmd; the bundled default needs tinyproxy).
# gvproxy is resolved from podman's libexec, not required on PATH (it
# ships inside the podman formula and is off PATH after a stock
# 'brew install podman'). A dependency preflight checks all of these up
# front. A real boot needs macOS virtualization tooling; this script is
# structured so the config-resolution half is exercisable without it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/claude-cache.sh
. "$SCRIPT_DIR/lib/claude-cache.sh"
# shellcheck source=lib/credential.sh
. "$SCRIPT_DIR/lib/credential.sh"
# shellcheck source=lib/endpoint.sh
. "$SCRIPT_DIR/lib/endpoint.sh"

# ---------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------
REPO_SRC="${1:?usage: claude-vm <repo-path> [claude args...]}"
shift
CLAUDE_ARGS=("$@")

# claude-vm has NO own-flags: every post-repo arg is forwarded to the guest
# claude verbatim (the #51 launcher contract). The guest's plugin enable/disable
# state comes from the config files (claude.plugins.enabled), not from CLI flags.

# Resolve to an absolute repo root so per-repo config and clone work
# regardless of the caller's cwd.
REPO_SRC="$(cd "$REPO_SRC" && git rev-parse --show-toplevel 2>/dev/null || (cd "$REPO_SRC" && pwd))"

# The fixed guest-side mount point the boot launcher cd's into (build-guest-
# image.sh's boot launcher sets REPO_MNT=/mnt/repo and the guest fstab mounts
# the repo share there). The identity seed keys its projects{} entry on THIS
# path so the guest skips the "trust this folder?" dialog for /mnt/repo (issue
# #88). Keep in lockstep with REPO_MNT in build-guest-image.sh.
GUEST_REPO_MNT="/mnt/repo"

claude_vm_require_yq || exit 1
command -v git >/dev/null 2>&1 || { echo "claude-vm: git is required" >&2; exit 1; }

# ---------------------------------------------------------------------
# Resolve effective config (issue #179: FOUR bake/boot files, all optional).
#
#   global bake: ~/.config/claude-vm/config-bake.yml
#   global boot: ~/.config/claude-vm/config-boot.yml
#   repo   bake: <repo>/.claude-vm/config-bake.yml
#   repo   boot: <repo>/.claude-vm/config-boot.yml
#
# A key that changes image BYTES lives in a bake file; a key applied at run
# time lives in a boot file. Effective config = union of all four with the
# existing merge semantics. The two BAKE files feed the image identity (whole-
# file, raw-byte hash -- see lib/config.sh); the boot files never do.
# ---------------------------------------------------------------------
GLOBAL_BAKE_CONFIG="$CLAUDE_VM_GLOBAL_BAKE_CONFIG"
GLOBAL_BOOT_CONFIG="$CLAUDE_VM_GLOBAL_BOOT_CONFIG"
REPO_BAKE_CONFIG="${CLAUDE_VM_REPO_BAKE_CONFIG:-$REPO_SRC/.claude-vm/config-bake.yml}"
REPO_BOOT_CONFIG="${CLAUDE_VM_REPO_BOOT_CONFIG:-$REPO_SRC/.claude-vm/config-boot.yml}"

# Migration guard (issue #179): a legacy single-file config.yml where a
# bake/boot pair is now expected is NOT silently read (that would drop knobs
# whose bake/boot placement it cannot express). Abort with a migration message
# instead. Checked for BOTH tiers.
claude_vm_detect_legacy_config "global" "$CLAUDE_VM_GLOBAL_LEGACY_CONFIG" "$CLAUDE_VM_GLOBAL_CONFIG_DIR" \
  || { echo "claude-vm: aborting -- migrate your global config to the bake/boot pair (see above)." >&2; exit 1; }
REPO_LEGACY_CONFIG="${CLAUDE_VM_REPO_LEGACY_CONFIG:-$REPO_SRC/.claude-vm/config.yml}"
claude_vm_detect_legacy_config "repo ($(basename "$REPO_SRC"))" "$REPO_LEGACY_CONFIG" "$REPO_SRC/.claude-vm" \
  || { echo "claude-vm: aborting -- migrate this repo's config to the bake/boot pair (see above)." >&2; exit 1; }

# NOTE: the merged-config temp file is removed by cleanup() (the
# consolidated EXIT/INT/TERM trap installed below). A narrow interim trap is
# armed earlier (right after the OAuth credential is written) to cover the
# clone window; it also removes this file, and the consolidated
# `trap cleanup EXIT INT TERM` REPLACES it once the full run state exists. Do
# NOT add yet another `trap ... EXIT` here -- a later trap installation would
# replace whatever was set, leaking this file on every run.
# Two per-tier documents, each in its FILE schema (issue #179): bake files
# merge into MERGED_BAKE, boot files into MERGED_BOOT. There is no combined
# cross-tier document and no schema translation -- bake consumers read
# bake-schema paths from MERGED_BAKE, boot consumers read boot-schema paths
# from MERGED_BOOT, exactly as documented in the example files.
MERGED_BAKE="$(claude_vm_mktemp claude-vm-merged-bake)"
MERGED_BOOT="$(claude_vm_mktemp claude-vm-merged-boot)"
claude_vm_merge_config "$GLOBAL_BAKE_CONFIG" "$REPO_BAKE_CONFIG" > "$MERGED_BAKE" \
  || { echo "claude-vm: could not resolve effective bake config" >&2; exit 1; }
claude_vm_merge_config "$GLOBAL_BOOT_CONFIG" "$REPO_BOOT_CONFIG" > "$MERGED_BOOT" \
  || { echo "claude-vm: could not resolve effective boot config" >&2; exit 1; }
# Same apt_sources name with differing content anywhere across the two tiers
# is a silent-shadowing hazard -- abort loudly instead.
claude_vm_check_apt_sources_conflicts "$MERGED_BAKE" "$MERGED_BOOT" || exit 1
# Same guard for claude.marketplaces (issue #107): one name with two urls would
# silently decide which code a `plugin@marketplace` ref resolves to.
claude_vm_check_marketplace_conflicts "$MERGED_BAKE" "$MERGED_BOOT" || exit 1
# claude.plugins is the one map that legitimately appears in BOTH file types
# (bake refs in a bake file; install_at_boot/update_at_boot/enabled in a boot
# file), which makes a misplaced sub-key easy to write and -- absent this guard
# -- silently ignored. Abort loudly instead (issue #107).
claude_vm_check_plugin_key_placement "$MERGED_BAKE" "$MERGED_BOOT" \
  || { echo "claude-vm: aborting -- move the misplaced claude.plugins key(s) as described above." >&2; exit 1; }

VM_CPUS="$(claude_vm_scalar "$MERGED_BOOT" '.cpus' "$CLAUDE_VM_DEFAULT_CPUS")"
VM_MEM="$(claude_vm_scalar "$MERGED_BOOT" '.mem' "$CLAUDE_VM_DEFAULT_MEM")"
REPO_MOUNT="$(claude_vm_scalar "$MERGED_BOOT" '.repo.mount' "$CLAUDE_VM_DEFAULT_REPO_MOUNT")"
COPY_BACK="$(claude_vm_scalar "$MERGED_BOOT" '.repo.copy_back' "$CLAUDE_VM_DEFAULT_REPO_COPY_BACK")"
PROXY_PORT="$(claude_vm_scalar "$MERGED_BOOT" '.proxy.port' "$CLAUDE_VM_DEFAULT_PROXY_PORT")"
GVPROXY_HOST_ALIAS="$(claude_vm_scalar "$MERGED_BOOT" '.proxy.host_alias' "$CLAUDE_VM_DEFAULT_PROXY_HOST_ALIAS")"
# proxy.cmd: when unset in BOTH config layers, default to the bundled
# tinyproxy launcher (the chosen forward proxy). It reads the egress
# allowlist from $CLAUDE_VM_EGRESS_ALLOWLIST and binds $CLAUDE_VM_PROXY_PORT,
# both exported below. An explicit proxy.cmd in config still overrides it.
DEFAULT_PROXY_CMD="$SCRIPT_DIR/proxy/tinyproxy-launch.sh"
PROXY_CMD="$(claude_vm_scalar "$MERGED_BOOT" '.proxy.cmd' "$DEFAULT_PROXY_CMD")"

# Boot-time apt update flag (issue #106): resolved once here so both the
# run.env write and the derived-egress gate (claude_vm_boot_apt_egress_needed,
# below) read the SAME value the boot launcher will act on.
PACKAGES_UPDATE_AT_BOOT="$(claude_vm_bool_scalar "$MERGED_BOOT" '.update_at_boot' "$CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT")"

# Boot-time plugin update flag (issue #107): the plugin-side sibling of
# PACKAGES_UPDATE_AT_BOOT above. Baked plugins are frozen at image-build time
# and the image-identity hash deliberately excludes marketplace HEAD, so this
# knob is the freshness mechanism for baked plugins -- with it true, a
# marketplace bump is picked up at the next boot with no image rebuild.
# Resolved once here so the run.env write and the derived-egress gate
# (claude_vm_boot_marketplace_egress_needed) act on the same value.
PLUGINS_UPDATE_AT_BOOT="$(claude_vm_bool_scalar "$MERGED_BOOT" '.claude.plugins.update_at_boot' "$CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_UPDATE_AT_BOOT")"

# guest_image: a normal scalar. When SET, it is used as-is -- an explicit
# operator override that opts OUT of variant derivation (issue #105, extended
# by the #106 root-headroom knob): the operator owns that path and its
# contents, so we neither hash nor rewrite it. When UNSET, the launcher
# DERIVES the image path from the image-identity segments below, defaulting
# into the cache dir alongside the global config.
#
# Image identity (issue #105 bake-hash, redesigned by #106, re-redesigned by
# #179 to a whole-file raw-byte hash). The image's CONTENT is determined by
# build-relevant config -- a bake file's packages: + apt_sources: (baked in)
# and image.root_headroom_mb (root partition size). Its IDENTITY (cache key +
# filename) is a whole-file, raw-byte hash of the two BAKE FILES (no
# key-picking, no canonicalization -- see claude_vm_file_identity_hash), so the
# filename is self-documenting:
#
#   - no repo-bake file:    guest+global<globalhash>.raw
#   - repo with a bake file: guest+global<globalhash>+<reponame>-<repohash>.raw
#
# Every repo WITHOUT a .claude-vm/config-bake.yml shares one image keyed on the
# global bake hash; a repo WITH a repo-bake file gets its own image,
# disambiguated by NAME (two repos with byte-identical repo-bake files still
# get two images -- legibility over dedup, the human's explicit choice). The
# segments are computed ONCE here (claude_vm_image_identity_segments) and
# passed to build-guest-image.sh via CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS for both
# --print-version and --output, so the version it stamps and the version we
# compare against are the SAME string; the MERGED bake config and MERGED
# headroom flow separately (CLAUDE_VM_BAKE_CONFIG / CLAUDE_VM_ROOT_HEADROOM_MB)
# as the image build CONTENT.
DEFAULT_IMAGE_DIR="$CLAUDE_VM_GLOBAL_CONFIG_DIR/images"
CLAUDE_VM_BAKE_CONFIG="$(claude_vm_bake_config_json "$MERGED_BAKE")" \
  || { echo "claude-vm: could not canonicalize the bake config" >&2; exit 1; }
export CLAUDE_VM_BAKE_CONFIG

# Baked marketplaces + plugins (issue #107). The build CONTENT sibling of
# CLAUDE_VM_BAKE_CONFIG: the marketplaces the image build registers -- the
# bake-declared ones as a hard requirement, the boot-declared ones best-effort
# (issue #226, and each entry carries the `origin` that says which) -- and the
# claude.plugins.bake refs it must install into /root/.claude/plugins. Like
# CLAUDE_VM_BAKE_CONFIG this is CONTENT, not the cache key -- the cache key is
# the whole-file raw-byte hash of the BAKE FILES, which already covers
# claude.marketplaces + claude.plugins.bake now that issue #107 places them
# there. That placement IS the "extend the bake-hash with marketplace/plugin
# refs" the issue asks for; it costs no new key-picked hash and it means the
# one-time rebuild lands the moment an operator moves the keys into their bake
# file.
CLAUDE_VM_BAKE_PLUGINS="$(claude_vm_bake_plugins_json "$MERGED_BAKE" "$MERGED_BOOT")" \
  || { echo "claude-vm: could not canonicalize the bake plugin manifest" >&2; exit 1; }
export CLAUDE_VM_BAKE_PLUGINS

# image.root_headroom_mb (issue #106 real-run fix): extra MiB the guest root
# partition is sized above its base content, so a live session has room to grow
# without hitting ENOSPC (see lib/config.sh's
# CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB for the default's justification). A
# normal scalar (repo overrides global), resolved once here as the MERGED,
# default-filled value and exported so build-guest-image.sh forwards it to the
# provisioner as the actual partition size. Validated as a positive integer up
# front (a typo here should abort the launch, not silently fall through to
# whatever the provisioner does with garbage). This is the BUILD input; the
# cache key is the identity segment below, which covers headroom per LAYER.
CLAUDE_VM_ROOT_HEADROOM_MB="$(claude_vm_scalar "$MERGED_BAKE" '.image.root_headroom_mb' "$CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB")"
case "$CLAUDE_VM_ROOT_HEADROOM_MB" in
  ''|*[!0-9]*)
    echo "claude-vm: image.root_headroom_mb must be a positive integer (MiB), got '$CLAUDE_VM_ROOT_HEADROOM_MB'" >&2
    exit 1
    ;;
esac
export CLAUDE_VM_ROOT_HEADROOM_MB

# Compose the image-identity segments from the two BAKE FILES (issue #179):
# global-bake + repo-bake, hashed over their RAW BYTES (whole-file, no
# canonicalization). Always yields at least "global<hash>"; a repo that ships a
# config-bake.yml appends "+<reponame>-<repohash>". Boot files never enter this
# computation. Exported so build-guest-image.sh's --print-version and --output
# stamp the exact same version string.
CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS="$(claude_vm_image_identity_segments "$GLOBAL_BAKE_CONFIG" "$REPO_BAKE_CONFIG" "$(basename "$REPO_SRC")")" \
  || { echo "claude-vm: could not compute the guest image identity segments" >&2; exit 1; }
export CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS

_explicit_guest_image="$(claude_vm_scalar "$MERGED_BOOT" '.guest_image' "")"
if [ -n "$_explicit_guest_image" ]; then
  # Explicit override: use verbatim, opting out of variant derivation.
  GUEST_IMAGE="$_explicit_guest_image"
else
  # Derive the image filename from the identity segments, so the filename and
  # the stamped version carry the same self-documenting identity. A config-less
  # repo gets guest+global<hash>.raw; a repo with config gets the two-segment
  # name. No special-casing of the "shared default": the global hash is always
  # present, so config-less repos collide on one guest+global<hash>.raw by
  # construction.
  GUEST_IMAGE="$DEFAULT_IMAGE_DIR/guest+${CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS}.raw"
fi
unset _explicit_guest_image

# claude.version: the channel/pin the host-side verified cache fetches
# (stable|latest|<pinned>). The cache resolves a channel to a concrete
# version HOST-SIDE and keys the cache on that version (see lib/claude-cache.sh).
CLAUDE_VERSION="$(claude_vm_scalar "$MERGED_BOOT" '.claude.version' "$CLAUDE_VM_DEFAULT_CLAUDE_VERSION")"

# claude.renderer: which renderer the in-guest claude uses on the byte-pipe
# console (issue #88). The vfkit stdio console is a plain bidirectional byte
# pipe, but the guest's alternate-screen (fullscreen) renderer survives it
# (verified on a real host), so this is a preference, not a workaround:
#   classic    -> CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 (no alt-screen)
#   fullscreen -> CLAUDE_CODE_NO_FLICKER=1               (force alt-screen)
#   unset/""   -> pass nothing; claude uses its own default
# Mapped to the matching env var(s) in run.env below. An unrecognized value
# is rejected up front rather than silently ignored.
CLAUDE_RENDERER="$(claude_vm_scalar "$MERGED_BOOT" '.claude.renderer' "")"
case "$CLAUDE_RENDERER" in
  ""|classic|fullscreen) : ;;
  *)
    echo "claude-vm: unknown claude.renderer '$CLAUDE_RENDERER' (expected classic|fullscreen, or leave unset)" >&2
    exit 1
    ;;
esac

# claude.remote_control: OPT-IN boolean (issue #88) enabling Claude Code's
# Remote Control on this launch. Same layered-scalar resolution as
# claude.renderer (global + per-repo override, repo wins), default false/unset.
# When true, the launcher injects `--remote-control` into the guest's CLAUDE_ARGS
# (unless the CLI args already carry it) and, if Remote Control is in effect but
# no `--name` was given, appends a date-stamped `--name` (issue #88 promises the
# date-stamp default). Validate like the renderer knob: accept true/false/unset;
# anything else aborts up front rather than being silently ignored.
CLAUDE_REMOTE_CONTROL="$(claude_vm_scalar "$MERGED_BOOT" '.claude.remote_control' "")"
case "$CLAUDE_REMOTE_CONTROL" in
  ""|false) CLAUDE_REMOTE_CONTROL="false" ;;
  true)     CLAUDE_REMOTE_CONTROL="true" ;;
  *)
    echo "claude-vm: unknown claude.remote_control '$CLAUDE_REMOTE_CONTROL' (expected true|false, or leave unset)" >&2
    exit 1
    ;;
esac

# Augment the user's post-repo CLI args with the Remote Control opt-in and the
# --name date-stamp default (issue #88). The date stamp uses the '+%b%d-%H:%M'
# format issue #51 plans for run naming (e.g. Jul10-14:30). Computed HOST-SIDE
# here (not in the guest) so the name reflects the launch time on the operator's
# machine. claude_vm_augment_rc_args is pure (stamp passed in) so it is
# unit-tested with a fixed stamp; it emits one arg per line, read back into the
# CLAUDE_ARGS array without re-splitting spaces inside an arg. When the knob is
# false/unset AND no CLI --remote-control is present, the args pass through
# unchanged.
_rc_name_stamp="$(date '+%b%d-%H:%M')"
_augmented_args=()
while IFS= read -r _line; do
  _augmented_args+=("$_line")
done < <(claude_vm_augment_rc_args \
           "$CLAUDE_REMOTE_CONTROL" "$_rc_name_stamp" \
           ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"})
CLAUDE_ARGS=(${_augmented_args[@]+"${_augmented_args[@]}"})
unset _rc_name_stamp _augmented_args _line

# Resolve and enum-guard claude.permission_mode for the rendered guest
# settings.json (issue #104). This is a security-posture value -- it becomes
# permissions.defaultMode in the guest's settings.json -- and there is no
# reasoning model for how the guest claude behaves under an unknown defaultMode,
# so accept ONLY the two known modes and abort on anything else, mirroring the
# scalar-enum validation used for claude.renderer / claude.remote_control above.
# The render (claude_vm_render_guest_settings) re-reads this key with the same
# default, but the authoritative guard is HERE so a typo aborts the launch
# rather than writing an unexpected defaultMode into the guest.
CLAUDE_PERMISSION_MODE="$(claude_vm_scalar "$MERGED_BOOT" '.claude.permission_mode' "$CLAUDE_VM_DEFAULT_CLAUDE_PERMISSION_MODE")"
case "$CLAUDE_PERMISSION_MODE" in
  bypassPermissions|default) : ;;
  *)
    echo "claude-vm: claude.permission_mode must be 'bypassPermissions' or 'default', got '$CLAUDE_PERMISSION_MODE'" >&2
    exit 1 ;;
esac

# claude.signing_key_fingerprint: the claude-code signing key fingerprint
# the operator out-of-band-verified at import time. This PINS the GPG
# verification's root of trust to a specific key -- a bare `gpg --verify`
# trusts ANY key in the keyring, so without this the "valid signature"
# check is not bound to "the claude-code key" (issue #49 review). Exported
# so lib/claude-cache.sh's verify step can enforce it. Empty when unset:
# the cache still requires a VALIDSIG but warns the key is not pinned.
CLAUDE_VM_SIGNING_KEY_FINGERPRINT="$(claude_vm_scalar "$MERGED_BOOT" '.claude.signing_key_fingerprint' "")"
export CLAUDE_VM_SIGNING_KEY_FINGERPRINT

# ---------------------------------------------------------------------
# Trusted-cache + credential PREFLIGHT. Fail FAST on local, instant
# preconditions BEFORE the guest-image build and ANY network/cache/Keychain
# call below. Without this, a cold boot pays for a guest-image build and
# three network fetches (channel pointer + manifest + signature) before
# aborting on a condition that was knowable at startup -- a missing `gpg`,
# an unpinned fingerprint, a pinned-but-unimported key, or a missing
# `python3`. The deep checks in lib/claude-cache.sh (gpg-on-PATH at the
# verify step; unset-pin hard-abort) and lib/credential.sh (python3 at the
# selection step) STAY as defense-in-depth -- this is an ADDITIVE early
# gate, not a replacement. Each failed check prints the EXACT command(s) to
# fix it, not a bare error.
# ---------------------------------------------------------------------
claude_vm_preflight_trust_path() {
  local ok=1

  # (a) gpg must be on PATH to verify the release-manifest signature.
  if ! command -v gpg >/dev/null 2>&1; then
    ok=0
    echo "claude-vm: 'gpg' is required to verify the claude release signature but was not found on PATH." >&2
    echo "claude-vm: install it, then import and pin the claude-code signing key:" >&2
    echo "claude-vm:   brew install gnupg" >&2
    echo "claude-vm:   curl -fsSL $CLAUDE_VM_SIGNING_KEY_URL | gpg --import" >&2
    echo "claude-vm:   gpg --fingerprint claude-code   # verify against the published value, then pin it (see below)" >&2
  fi

  # (b) the signing-key fingerprint MUST be pinned. A valid signature by
  # ANY key in the keyring is not enough -- the trusted cache requires the
  # claude-code key's fingerprint, verified out of band.
  if [ -z "${CLAUDE_VM_SIGNING_KEY_FINGERPRINT// /}" ]; then
    ok=0
    echo "claude-vm: no claude-code signing-key fingerprint is pinned ('claude.signing_key_fingerprint' is unset)." >&2
    echo "claude-vm: a valid signature by ANY key in your keyring is not enough -- the trusted cache requires" >&2
    echo "claude-vm: the fingerprint of the claude-code key you verified out of band. Import and pin it:" >&2
    echo "claude-vm:   curl -fsSL $CLAUDE_VM_SIGNING_KEY_URL | gpg --import" >&2
    echo "claude-vm:   gpg --fingerprint claude-code   # copy the 40-hex fingerprint after verifying it" >&2
    echo "claude-vm: then add to ~/.config/claude-vm/config-boot.yml (or <repo>/.claude-vm/config-boot.yml):" >&2
    echo "claude-vm:   claude:" >&2
    echo "claude-vm:     signing_key_fingerprint: \"<the fingerprint you just verified>\"" >&2
  elif command -v gpg >/dev/null 2>&1; then
    # (c) the pinned fingerprint MUST be present in the keyring. Only checkable
    # when gpg is present AND a fingerprint is pinned; a pinned-but-unimported
    # key otherwise fails late as a generic no-VALIDSIG abort after all
    # downloads. Pass the compact (space-stripped) fingerprint to gpg.
    local fpr="${CLAUDE_VM_SIGNING_KEY_FINGERPRINT// /}"
    if ! gpg --list-keys "$fpr" >/dev/null 2>&1; then
      ok=0
      echo "claude-vm: the pinned signing-key fingerprint $fpr is not present in your gpg keyring." >&2
      echo "claude-vm: import the claude-code signing key (one-time, trust-on-first-use):" >&2
      echo "claude-vm:   curl -fsSL $CLAUDE_VM_SIGNING_KEY_URL | gpg --import" >&2
      echo "claude-vm:   gpg --fingerprint claude-code   # confirm it matches the pinned value $fpr" >&2
    fi
  fi

  # (d) python3 must be on PATH to select the claudeAiOauth credential.
  if ! command -v python3 >/dev/null 2>&1; then
    ok=0
    echo "claude-vm: python3 is required to select the claude.ai OAuth credential but was not found on PATH." >&2
    echo "claude-vm: python3 ships with macOS; if missing, install it, then retry:" >&2
    echo "claude-vm:   xcode-select --install        # provides /usr/bin/python3 on macOS" >&2
  fi

  [ "$ok" -eq 1 ]
}
claude_vm_preflight_trust_path \
  || { echo "claude-vm: trust-path preflight failed; see the messages above." >&2; exit 1; }

# ---------------------------------------------------------------------
# Identity-seed PREFLIGHT (issue #88). The interactive Claude Code TUI in the
# guest decides "am I onboarded / logged in" from ON-DISK state: the bearer
# token in ~/.claude/.credentials.json (installed below from the Keychain,
# via the claudecreds mount) PLUS identity AND onboarding state in
# ~/.claude.json. A fresh throwaway guest lacks that state, so without a seed
# every launch shows the onboarding/login wall regardless of the mounted
# credential. The launcher seeds a /root/.claude.json into the guest carrying
# the host's `userID`/`oauthAccount` PLUS synthesized `hasCompletedOnboarding`/
# `autoUpdates`/`lastOnboardingVersion`/`lastReleaseNotesSeen` (see the
# "identity seed" block below).
#
# Gate here, FAST, before any build/boot work: if the host ~/.claude.json is
# missing, or lacks a usable `userID` or `oauthAccount`, abort with an
# actionable, claude-vm-branded message. Guarded ${...:-} so an unset $HOME
# does not trip `set -u`. The full selection (which validates and reserializes
# the two keys) runs later against $CREDS_DIR; this is the cheap early gate on
# the same preconditions.
# ---------------------------------------------------------------------
HOST_CLAUDE_JSON="${HOME:-}/.claude.json"
if [ ! -s "$HOST_CLAUDE_JSON" ]; then
  echo "claude-vm: no ~/.claude.json found on the host (looked at '$HOST_CLAUDE_JSON')." >&2
  echo "claude-vm: the guest seeds its identity (userID + oauthAccount) from your host's" >&2
  echo "claude-vm: ~/.claude.json so the in-guest claude comes up already logged in. That" >&2
  echo "claude-vm: file only exists once you have logged in to Claude Code on this host." >&2
  echo "claude-vm: run 'claude' once and complete the claude.ai login, then retry." >&2
  exit 1
fi
# The version arg here is best-effort ($CLAUDE_VERSION, the raw channel/pin):
# this preflight only validates that userID/oauthAccount are present and
# discards stdout, so the version fields it would emit are not load-bearing.
# The authoritative concrete version is resolved later (after the cache-ensure
# block) and passed to the REAL seed write below (~line 588). Resolving a
# channel here would force a premature network fetch in the fast preflight.
if ! claude_vm_select_claude_json_seed "$CLAUDE_VERSION" "$REPO_SRC" "$GUEST_REPO_MNT" < "$HOST_CLAUDE_JSON" >/dev/null 2>&1; then
  echo "claude-vm: your host ~/.claude.json ('$HOST_CLAUDE_JSON') has no usable identity state" >&2
  echo "claude-vm: (a 'userID' string and an 'oauthAccount' object). The guest seeds these two" >&2
  echo "claude-vm: keys so the in-guest claude comes up already logged in. This usually means" >&2
  echo "claude-vm: you are not (fully) logged in to Claude Code on this host: run 'claude' once" >&2
  echo "claude-vm: and complete the claude.ai login, then retry. (python3, which ships with" >&2
  echo "claude-vm: macOS, is required to select the seed.)" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Dependency preflight for the VM toolchain. Fail FAST here -- before any
# build/boot work -- with one actionable remediation per missing piece,
# rather than dying deep in the boot sequence with an opaque error (e.g.
# "gvproxy socket never appeared" when gvproxy is merely off PATH). The
# tinyproxy check is included only when the bundled default proxy is in
# use; a custom proxy.cmd owns its own dependencies.
# ---------------------------------------------------------------------
if [ "$PROXY_CMD" = "$DEFAULT_PROXY_CMD" ]; then
  PREFLIGHT_PROXY_MODE="default-proxy"
else
  PREFLIGHT_PROXY_MODE="custom-proxy"
fi
claude_vm_preflight_toolchain "$PREFLIGHT_PROXY_MODE" \
  || { echo "claude-vm: dependency preflight failed; see the messages above." >&2; exit 1; }

# Resolve gvproxy once, up front. The preflight above already confirmed
# it is resolvable; capture the absolute path so the launch step below
# does not depend on gvproxy being on PATH (it ships inside podman's
# libexec and is not on PATH after a stock 'brew install podman').
GVPROXY_BIN="$(claude_vm_resolve_gvproxy)"

# ---------------------------------------------------------------------
# Resolve `claude` via the host-side, GPG-verified cache (issue #49).
#
# The host resolves the requested channel/pin to a concrete version,
# downloads that version's GPG-signed manifest, verifies the signature
# against the operator's pinned key, checksum-verifies the downloaded
# binary against the verified manifest, and caches it keyed on the
# resolved version. The verified binary is then mounted RO into the guest
# (mountTag=claudebin) and run at the boot-launcher seam.
#
# SECURITY: a failed gpg --verify or a checksum mismatch ABORTS here --
# the launcher never boots the guest with an unverified binary. There is
# ONE trusted path and no install.sh fallback: an unpinned/unimported
# signing key or a verification failure aborts the run, it does NOT
# downgrade to a lower-trust install (see lib/claude-cache.sh and the README).
#
# Warm boot: when the resolved version is already cached, no binary is
# re-downloaded and gpg is not re-run (verification happened when it was
# first cached), so the heavy network fetch is skipped. The launcher reads
# CLAUDE_VM_CACHE_NETWORK to drop claude.ai/downloads.claude.ai from the
# egress allowlist when the binary did not need fetching this run.
# ---------------------------------------------------------------------
# claude_cache_ensure runs in a command substitution below, so it cannot
# hand back its network-state via an exported var (a subshell export does
# not propagate to this parent). It writes the state to this file instead,
# which we read after the substitution to drive the warm-boot allowlist
# tightening. A unique per-process path keeps concurrent launches from
# racing on a shared default.
CACHE_STATE_FILE="$(claude_vm_mktemp claude-vm-cachestate)"
export CLAUDE_VM_CACHE_STATE_FILE="$CACHE_STATE_FILE"
CLAUDE_VM_CACHE_NETWORK=""
CLAUDE_BIN_HOST=""
CLAUDE_BIN_HOST="$(claude_cache_ensure "$CLAUDE_VERSION")" || {
  echo "claude-vm: could not obtain a verified 'claude' binary for claude.version='$CLAUDE_VERSION'." >&2
  echo "claude-vm: see the messages above. The trusted path aborts rather than running unverified code." >&2
  rm -f "$CACHE_STATE_FILE"
  exit 1
}
CLAUDE_VM_CACHE_NETWORK="$(cat "$CACHE_STATE_FILE" 2>/dev/null || true)"
rm -f "$CACHE_STATE_FILE"
echo "claude-vm: using verified claude binary: $CLAUDE_BIN_HOST (fetch=${CLAUDE_VM_CACHE_NETWORK:-unknown})" >&2

# Resolve the channel/pin ($CLAUDE_VERSION, e.g. stable|latest|2.1.172) to a
# concrete dotted version for the identity seed (issue #88). The widened seed
# stamps this into lastOnboardingVersion / lastReleaseNotesSeen so the guest
# TUI's onboarding-version / release-notes gates read as satisfied. A pinned
# version resolves to itself with no network; stable|latest fetch the channel
# pointer. We resolve here -- AFTER claude_cache_ensure, which already did any
# channel-pointer fetch a few lines up -- so this is a warm/no-op resolution
# with no extra network round-trip, and it is captured ONCE and reused at the
# real seed write below (~line 588). On the unexpected event that resolution
# fails, fall back to the raw channel/pin string: the seed's version fields are
# a best-effort onboarding hint, not a correctness gate, and must not block an
# otherwise-bootable guest.
CLAUDE_VERSION_RESOLVED="$(claude_cache_resolve_version "$CLAUDE_VERSION" 2>/dev/null || true)"
[ -n "$CLAUDE_VERSION_RESOLVED" ] || CLAUDE_VERSION_RESOLVED="$CLAUDE_VERSION"

# ---------------------------------------------------------------------
# Ensure guest image exists and matches the pinned version. Build on
# demand rather than erroring. The base is version-pinned; claude is
# NOT baked in -- it is fetched at boot through the egress allowlist.
# The image-identity segments (issue #106) flow into BOTH the --print-version
# below and the --output build through the exported
# CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS (set above), so the version stamped in
# <img>.version and the version we compare against are the SAME string. A
# config-less repo stamps/compares BASE+launcherN+global<hash> and shares that
# one image; a repo with build-relevant config stamps its own
# BASE+launcherN+global<hash>+<reponame>-<repohash> and rebuilds only when its
# global or repo build-relevant config changes.
#
# ORDERED AFTER the verified-cache block above (issue #107). The bake path now
# runs the GUEST-PLATFORM (linux-arm64) `claude` binary inside the build
# container to install claude.plugins.bake -- `claude plugin marketplace add` /
# `claude plugin install` with HOME pointed at the image root -- so the
# verified binary must already exist when the build starts. It is passed in via
# CLAUDE_VM_GUEST_CLAUDE_BIN below. Two happy side effects of the reorder: a
# signature/checksum failure now aborts BEFORE a multi-minute image build
# rather than after it, and the build reuses the exact binary the guest will
# run, so bake-time and boot-time plugin handling can never be done by two
# different claude versions.
# ---------------------------------------------------------------------
export CLAUDE_VM_GUEST_CLAUDE_BIN="$CLAUDE_BIN_HOST"
PINNED_VERSION="$("$SCRIPT_DIR/build-guest-image.sh" --print-version)"
ensure_guest_image() {
  local img="$1" want="$2" have=""
  if [ -f "$img" ] && [ -f "$img.version" ]; then
    have="$(cat "$img.version" 2>/dev/null || true)"
  fi
  if [ "$have" = "$want" ]; then
    return 0
  fi
  echo "claude-vm: guest image missing or version-mismatched (have='${have:-none}', want='$want'); building..." >&2
  mkdir -p "$(dirname "$img")"
  "$SCRIPT_DIR/build-guest-image.sh" --output "$img"
}
ensure_guest_image "$GUEST_IMAGE" "$PINNED_VERSION"

# ---------------------------------------------------------------------
# Run directory + repo mount strategy
# ---------------------------------------------------------------------
# A persistent run id and run dir. When launched from inside a repo,
# the run dir lives under <repo>/.claude/tmp/<runid>/ (git-ignored, and
# persistent so the companion diff/apply skills can extract results).
# Otherwise it falls back to a mktemp dir under TMPDIR.
#
# The run dir and the config dir hold the token-bearing run.env, so they
# must not be world-traversable to that secret. Create them with a
# tightened umask (077 -> drwx------) so the secret's parent dirs are
# owner-only from creation. The umask is restored immediately afterward
# so the umask does NOT bleed into the `git clone` below: a clone under
# umask 077 checks out worktree files as -rw-------, and the later
# copy-back (rsync -a, which preserves perms) would then push 0600 onto
# the user's source files, silently tightening their permissions. Only
# the run.env write itself re-tightens the umask (in a subshell) so the
# secret file is never world-readable, not even momentarily.
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
OLD_UMASK="$(umask)"
umask 077
if git -C "$REPO_SRC" rev-parse --show-toplevel >/dev/null 2>&1; then
  RUN="$REPO_SRC/.claude/tmp/$RUN_ID"
  mkdir -p "$RUN"
else
  RUN="$(claude_vm_mktemp -d claude-vm)"
fi

# gvproxy unix socket -- sited under a SHORT $TMPDIR path, NOT under $RUN
# (issue #88, Finding 7). The AF_UNIX sun_path limit is ~104 bytes, and
# vfkit derives a child socket name (e.g. vfkit-<hex>-<num>.sock, ~20 bytes)
# in the SAME directory as the socket we pass it. With $RUN under
# <repo>/.claude/tmp/<runid>/ the base socket path is already ~118 bytes on a
# normally-nested repo -- and the derived child path ~124 -- so BOTH overflow
# and `claude-vm <repo>` cannot boot. The run dir must stay under the repo
# (the diff/apply skills depend on its location), but the socket location is
# independent of it: site it under a short mktemp dir under $TMPDIR (resulting
# child path ~79 bytes, well under the limit). $TMPDIR is used BARE: it is
# always set on macOS (the only platform claude-vm targets), is a per-user
# owner-only dir (matches the launcher's credential posture, unlike
# world-writable /tmp), and a user can override with TMPDIR=... claude-vm ...
# If it is somehow unset, fail with a clear claude-vm message rather than a
# raw `set -u` error or a silent downgrade to /tmp. The socket dir is removed
# by cleanup() on exit.
if [ -z "${TMPDIR:-}" ]; then
  echo "claude-vm: \$TMPDIR is not set. claude-vm sites the gvproxy unix socket under a short" >&2
  echo "claude-vm: \$TMPDIR path to stay under the ~104-byte AF_UNIX limit. macOS always sets" >&2
  echo "claude-vm: \$TMPDIR; if it is unset, set it (e.g. TMPDIR=/tmp claude-vm ...) and retry." >&2
  exit 1
fi
SOCK_DIR="$(claude_vm_mktemp -d claude-vm-sock)"
GVPROXY_SOCK="$SOCK_DIR/net.sock"
# NO vfkit REST control socket (issue #179): the guest powers ITSELF off when
# claude quits (the guest boot launcher starts systemd's poweroff on claude's
# exit 0), so there is no host->guest shutdown channel to open. vfkit runs
# foreground and exits on its own when the guest halts; its status lands in
# the launcher's own `$?`.
# Per-run SSH-forward TCP port for gvproxy (issue #179). gvproxy ALWAYS binds
# an -ssh-port (default 2222); if every run took 2222 a second concurrent run
# would fail with `bind: address already in use` and never come up. Acquired
# race-safely just before the gvproxy launch (bind :0, read assigned port) so
# N concurrent runs each get their own free port. Declared empty here so the
# cleanup() trap's guards are well-defined if a signal fires before it is set.
SSH_PORT=""
PCAP="$RUN/egress.pcap"
# Retained log files for the two host-side background processes (issue #88).
# Both are sited under $RUN (the persistent run dir) and their stdout+stderr
# are redirected here at launch so their chatty diagnostics do NOT flood the
# interactive hvc1 terminal. Retained (not /dev/null) so failures stay
# diagnosable, matching $GUEST_CONSOLE_LOG.
GVPROXY_LOG="$RUN/gvproxy.log"
PROXY_LOG="$RUN/proxy.log"
# Host-side capture of the guest's BOOT virtio-console (/dev/hvc0 in the
# guest). The recipe's KernelCommandLine sets console=hvc0
# (provisioners/podman-mkosi.sh, issue #71), so all kernel + systemd boot
# output -- and the boot launcher's claude-vm: diagnostic/seam lines, which it
# writes explicitly to /dev/console -- land on this stream. Capturing it here
# (issue #87) makes an otherwise-black-box boot observable from the host.
#
# Dual-console topology (issue #88): hvc0 is the FIRST virtio-serial device
# (boot capture, logFilePath below); a SECOND virtio-serial device is attached
# in `stdio` mode -> guest hvc1, the INTERACTIVE console the launching terminal
# bridges to. Device order is deterministic (1st -> hvc0, 2nd -> hvc1). claude
# runs on hvc1 via an autologin getty (see build-guest-image.sh /
# provisioners/podman-mkosi.sh), so boot diagnostics (hvc0 capture) stay off
# the interactive terminal (hvc1).
GUEST_CONSOLE_LOG="$RUN/guest-console.log"
WORKTREE="$RUN/worktree"
CONFIG_DIR="$RUN/config"
EFISTORE="$RUN/efistore"
# Per-run guest image clone (issue #179). The cached base $GUEST_IMAGE is
# IMMUTABLE and is NEVER attached to a VM: each run APFS-clones it (cp -c, an
# instant zero-copy copy-on-write clone on APFS) into this run-dir path and
# boots the CLONE. N concurrent sessions then cost one base image plus each
# session's own written blocks -- no cross-session leakage, no multi-writer
# corruption on a shared ext4 image. The clone is discarded by cleanup() on a
# CLEAN exit and RETAINED on an abnormal exit (nonzero vfkit status / signal)
# for forensics. Set here (empty) so cleanup()'s guard is well-defined even if
# a signal fires before the clone is created just above the vfkit launch.
GUEST_IMAGE_CLONE="$RUN/guest-clone.raw"
# The credential lives in its OWN dir, NOT in CONFIG_DIR: CONFIG_DIR is
# shared into the guest under mountTag=runconfig, and the secret-bearing
# OAuth credential must never travel in the run.env share. Its own dir is
# shared under a separate tag (claudecreds) so only the credential file is
# exposed. The identity seed (issue #88, claude-json-seed.json) is written
# into this SAME dir for the same reason -- it carries account identity and
# must not ride in run.env either. Both dirs are created under the tightened
# umask (077) so they are drwx------ from creation -- the secrets are not
# world-traversable.
CREDS_DIR="$RUN/creds"
mkdir -p "$CONFIG_DIR" "$CREDS_DIR"

# ---------------------------------------------------------------------
# Render the guest Claude settings.json (issue #104).
#
# Host-side render of /root/.claude/settings.json from the merged config: the
# permission allow/ask/deny lists, the permission defaultMode
# (claude.permission_mode, default bypassPermissions, enum-guarded above), and
# the enabledPlugins object (every ref in claude.plugins.bake ++ install_at_boot
# defaults true, then claude.plugins.enabled overrides per key). BOTH merged
# documents are passed since issue #107 (bake refs live in the BAKE file, every
# other key it reads is a BOOT key). The permissions
# come from the claude-vm configs ONLY -- the host's ~/.claude/settings.json is
# NEVER read, so the guest's Claude surface is defined entirely by claude-vm, per
# the issue's product intent. The render also VALIDATES claude.plugins.enabled
# (boolean values, keys must name installed plugins) and returns non-zero on a
# typo, so a bad enabled map aborts the launch here.
#
# It rides the SAME transient claudecreds mount ($CREDS_DIR, mountTag=claudecreds)
# as the credential and identity seed, and the guest boot launcher installs it at
# $HOME/.claude/settings.json. settings.json is NOT a secret, but sharing it via
# the existing claudecreds mount avoids adding another virtio-fs device and keeps
# every host-rendered guest ~/.claude file arriving over one dir. Written now,
# still inside the umask-077 window, so it lands 0600 like its dir-mates; the
# chmod 600 is belt-and-braces.
GUEST_SETTINGS="$CREDS_DIR/settings.json"
claude_vm_render_guest_settings "$MERGED_BOOT" "$MERGED_BAKE" > "$GUEST_SETTINGS" \
  || { echo "claude-vm: failed to render the guest settings.json" >&2; exit 1; }
chmod 600 "$GUEST_SETTINGS"

# ---------------------------------------------------------------------
# Host claude.ai OAuth credential -> transient, owner-only tmpfile.
#
# The guest authenticates with the HOST operator's live claude.ai login
# (full-scope OAuth), which Remote Control requires. Extract that
# credential from the macOS login Keychain by SERVICE NAME ALONE.
#
# SELECTION (issue #50 review): the Keychain item named "Claude Code-
# credentials" is NOT only the claude.ai login. On a real host its JSON has
# sibling top-level keys -- `claudeAiOauth` (the intended login) AND
# `mcpOAuth` (per-MCP-server OAuth, e.g. a Sentry MCP token). A verbatim copy
# would mount those unrelated MCP credentials into the guest -- a scope leak.
# So we extract ONLY `claudeAiOauth` and write the file in the shape claude
# expects, `{"claudeAiOauth": { ... }}`, dropping mcpOAuth and any other
# siblings. The selection runs via claude_vm_select_claude_credential (see
# lib/credential.sh) and is unit-tested in payload/test/credential-test.sh.
# This means the credential is parsed and reserialized -- it is NOT a byte-
# for-byte copy. The subset is the point.
#
# Window discipline: `security ... -w` emits the FULL raw blob. We capture it
# into a transient RAW tmpfile ($RAW_CREDENTIAL, OUTSIDE the claudecreds
# share dir so the full blob is never mounted), select claudeAiOauth from it
# into the mounted file ($HOST_CREDENTIAL), then remove the raw tmpfile
# immediately -- the full blob does not survive past the selection. All under
# umask 077, so both files are created -rw------- with no world-readable
# window; the chmod 600 afterward is belt-and-suspenders. The credential dir
# is removed by cleanup() on exit and is NEVER persisted to config, to
# run.env, or to the verified-binary cache.
#
# macOS-only: `security` is a macOS binary. Fail fast with an actionable
# message, but DISTINGUISH the two failure modes so an operator can diagnose:
#
#   - The COMMON case -- no such credential (errSecItemNotFound, exit 44), an
#     empty blob, OR a blob with no usable `claudeAiOauth` key -- means the
#     operator simply is not (usably) logged in to claude.ai. Show the
#     friendly "log in" guidance. `security`'s own stderr here is just
#     "could not be found in the keychain", which adds nothing, so it is hidden.
#   - Any OTHER failure (exit non-zero AND not 44) -- a LOCKED keychain, a
#     `security` tool error, a permissions denial -- is NOT a "log in" problem.
#     Hiding it behind the friendly message sent operators chasing the wrong
#     fix. Surface `security`'s real stderr so the actual error is visible.
# ---------------------------------------------------------------------
KEYCHAIN_SERVICE="Claude Code-credentials"
HOST_CREDENTIAL="$CREDS_DIR/.credentials.json"
# The FULL raw blob lands here -- OUTSIDE $CREDS_DIR (the claudecreds share)
# so the unselected blob is never exposed to the guest -- and is removed
# immediately after selection. The narrow interim trap below also rm's it.
RAW_CREDENTIAL="$RUN/.keychain-blob.raw.json"
SEC_STDERR="$RUN/.security.stderr"
# Arm the NARROW interim trap BEFORE the `security` write below, so a Ctrl-C (or
# other signal) anywhere from the credential write through the potentially-slow
# `git clone` does NOT leak the full-scope OAuth credential at
# $CREDS_DIR/.credentials.json. This is deliberately minimal (remove the
# credential dir + the merged-config temp file) rather than the full cleanup():
# cleanup() runs copy_back, which expects $WORKTREE to exist -- but the worktree
# is not created until the clone below, so installing the full trap here would
# fire copy-back against a missing worktree. It still removes the merged
# config docs so the
# merged-config-cleanup guarantee holds even if a signal fires in this window.
# The full `trap cleanup EXIT INT TERM` REPLACES this interim trap at its
# existing site once the worktree, proxy, and gvproxy state all exist. Guarded
# with ${CREDS_DIR:-}/${RAW_CREDENTIAL:-}/${MERGED_BAKE:-}/${MERGED_BOOT:-} so
# each rm is a no-op
# under `set -u` even if the trap fires before they are set. RAW_CREDENTIAL is
# included so a signal during the selection window does not leak the FULL blob.
trap 'rm -rf "${CREDS_DIR:-}"; rm -f "${RAW_CREDENTIAL:-}" "${MERGED_BAKE:-}" "${MERGED_BOOT:-}"' EXIT INT TERM
# Run with `set +e` around just this call so a non-zero exit does not trip
# `set -e` before we have inspected the code. Capture stderr to a file (not
# /dev/null) so an unexpected error can be surfaced verbatim below. The FULL
# raw blob lands in RAW_CREDENTIAL (outside the share); selection below writes
# only claudeAiOauth into the mounted HOST_CREDENTIAL.
set +e
security find-generic-password -s "$KEYCHAIN_SERVICE" -w > "$RAW_CREDENTIAL" 2>"$SEC_STDERR"
SEC_RC=$?
set -e
if [ "$SEC_RC" -ne 0 ] && [ "$SEC_RC" -ne 44 ]; then
  # Unexpected failure (locked keychain, tool error, ...). Surface the real
  # error so the operator does not chase a non-existent "not logged in" cause.
  rm -f "$RAW_CREDENTIAL" "$SEC_STDERR"
  umask "$OLD_UMASK"
  echo "claude-vm: reading the claude.ai OAuth credential from the macOS Keychain failed" >&2
  echo "claude-vm: (service '$KEYCHAIN_SERVICE') with an unexpected error (security exit $SEC_RC)." >&2
  echo "claude-vm: this is NOT a 'not logged in' case -- a locked keychain or a 'security' tool" >&2
  echo "claude-vm: error is likely. The underlying error from 'security' was:" >&2
  if [ -s "$SEC_STDERR" ]; then
    sed 's/^/claude-vm:   /' "$SEC_STDERR" >&2
  else
    echo "claude-vm:   (security produced no error output)" >&2
  fi
  exit 1
fi
if [ "$SEC_RC" -eq 44 ] || [ ! -s "$RAW_CREDENTIAL" ]; then
  # Common case: no such credential (or an empty blob) -- operator is not
  # logged in to claude.ai. Show the friendly guidance.
  rm -f "$RAW_CREDENTIAL" "$SEC_STDERR"
  umask "$OLD_UMASK"
  echo "claude-vm: could not read the claude.ai OAuth credential from the macOS Keychain" >&2
  echo "claude-vm: (service '$KEYCHAIN_SERVICE'). The guest authenticates with the host's" >&2
  echo "claude-vm: live claude.ai login, so you must be logged in to Claude Code on this host." >&2
  echo "claude-vm: run 'claude' once and complete the claude.ai login, then retry. (macOS only:" >&2
  echo "claude-vm: this uses 'security find-generic-password', a macOS Keychain tool.)" >&2
  exit 1
fi
rm -f "$SEC_STDERR"

# ---------------------------------------------------------------------
# SELECT only `claudeAiOauth` from the full raw blob (issue #50 review).
#
# Read RAW_CREDENTIAL (the full Keychain blob, possibly carrying mcpOAuth and
# other siblings) and write ONLY {"claudeAiOauth": {...}} to the mounted
# HOST_CREDENTIAL. Then remove the raw blob IMMEDIATELY so the full form does
# not survive on disk past the selection. Still under umask 077, so the
# mounted file is created -rw-------; chmod 600 afterward is belt-and-braces.
#
# Fail-closed: a blob with no usable `claudeAiOauth` key (or invalid JSON)
# means the operator is not usably logged in -- route to the SAME friendly
# "log in" path as the empty-blob case rather than mounting an empty or
# mcpOAuth-only file. A missing python3 (return 2) is surfaced distinctly.
# ---------------------------------------------------------------------
set +e
claude_vm_select_claude_credential < "$RAW_CREDENTIAL" > "$HOST_CREDENTIAL"
SELECT_RC=$?
set -e
# The full raw blob has served its purpose -- remove it now, do not wait for
# cleanup(), so the unselected form's on-disk window is as narrow as possible.
rm -f "$RAW_CREDENTIAL"
if [ "$SELECT_RC" -eq 2 ]; then
  # python3 missing -- an environment problem, not a "log in" problem.
  rm -f "$HOST_CREDENTIAL"
  umask "$OLD_UMASK"
  echo "claude-vm: cannot select the claude.ai OAuth credential: python3 is required but not" >&2
  echo "claude-vm: found on PATH. python3 ships with macOS; ensure it is available, then retry." >&2
  exit 1
fi
if [ "$SELECT_RC" -ne 0 ] || [ ! -s "$HOST_CREDENTIAL" ]; then
  # The blob had no usable claudeAiOauth key (only mcpOAuth, malformed, etc.).
  # Treat exactly like the not-logged-in case: friendly "log in" guidance.
  rm -f "$HOST_CREDENTIAL"
  umask "$OLD_UMASK"
  echo "claude-vm: the macOS Keychain item (service '$KEYCHAIN_SERVICE') has no usable" >&2
  echo "claude-vm: claude.ai OAuth credential ('claudeAiOauth'). The guest authenticates with" >&2
  echo "claude-vm: the host's live claude.ai login, so you must be logged in to Claude Code on" >&2
  echo "claude-vm: this host. Run 'claude' once and complete the claude.ai login, then retry." >&2
  exit 1
fi
chmod 600 "$HOST_CREDENTIAL"

# ---------------------------------------------------------------------
# VALIDATE the selected credential's tokens (issue #88, Gap 1).
#
# The structural selection above accepts a `claudeAiOauth` object that is a
# valid non-empty dict -- but a real host was observed whose PERSISTED Keychain
# entry had gone DEGRADED: a structurally-complete `claudeAiOauth` with EMPTY
# accessToken/refreshToken strings (and expiresAt: 0), while the host's own
# claude sessions kept working via the shared auth daemon's in-memory tokens.
# Copied into the guest, that empty credential boots claude to
# "Not logged in -- Run /login", and an in-guest /login can trip OAuth
# reuse-detection and REVOKE the operator's other live sessions. So fail FAST
# here, steering the operator to re-login on the HOST (which repairs the
# Keychain entry) -- NOT into an in-guest /login.
# ---------------------------------------------------------------------
set +e
claude_vm_validate_claude_credential_tokens < "$HOST_CREDENTIAL"
VALIDATE_RC=$?
set -e
if [ "$VALIDATE_RC" -eq 2 ]; then
  # python3 missing -- an environment problem, not a "log in" problem.
  rm -f "$HOST_CREDENTIAL"
  umask "$OLD_UMASK"
  echo "claude-vm: cannot validate the claude.ai OAuth credential: python3 is required but not" >&2
  echo "claude-vm: found on PATH. python3 ships with macOS; ensure it is available, then retry." >&2
  exit 1
fi
if [ "$VALIDATE_RC" -ne 0 ]; then
  # Degraded Keychain entry: the claudeAiOauth object exists but its
  # accessToken/refreshToken are empty. Abort BEFORE booting a broken guest.
  rm -f "$HOST_CREDENTIAL"
  umask "$OLD_UMASK"
  echo "claude-vm: the macOS Keychain item (service '$KEYCHAIN_SERVICE') has a claude.ai OAuth" >&2
  echo "claude-vm: credential, but its accessToken and refreshToken are EMPTY -- a degraded state" >&2
  echo "claude-vm: that happens when your host claude sessions coast on the shared auth daemon's" >&2
  echo "claude-vm: in-memory tokens while the persisted Keychain entry has gone stale. The guest" >&2
  echo "claude-vm: would boot to 'Not logged in -- Run /login' with this credential. Re-login on" >&2
  echo "claude-vm: THIS HOST to repair the Keychain entry -- run 'claude' then '/login' (or restart" >&2
  echo "claude-vm: Claude Code) -- then retry claude-vm. Do NOT run /login inside the guest: a" >&2
  echo "claude-vm: retried guest login can revoke your other live sessions." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Identity seed -> the SAME shred-on-exit claudecreds mount (issue #88).
#
# The interactive guest TUI treats itself as onboarded + logged in only when
# the bearer token (installed above at ~/.claude/.credentials.json) AND the
# right ~/.claude.json state are present. Build the seed from the host
# ~/.claude.json (preflighted above): select `userID` + `oauthAccount` from the
# host, synthesize `hasCompletedOnboarding: true` (skip the onboarding wall),
# `autoUpdates: false` (don't self-update in the egress-confined guest), and
# `lastOnboardingVersion` / `lastReleaseNotesSeen` stamped with the concrete
# resolved claude version; ADDITIVELY carry benign host UI keys when present
# (installMethod, hasSeenTasksHint, hasUsedStash, tipsHistory); and seed a
# `projects` entry for the guest mount path ($GUEST_REPO_MNT) with
# hasTrustDialogAccepted / hasCompletedProjectOnboarding forced true so the
# guest skips the "trust this folder?" dialog (issue #88, Gap 2). Write that
# object into
# $CREDS_DIR -- the SAME transient owner-only dir shared RO into the guest under
# mountTag=claudecreds and shredded by cleanup() on every exit (EXIT/INT/TERM).
# machineID is NOT seeded -- the guest mints its own. It is NOT named
# .credentials.json (that name is the bearer token's) -- the guest boot launcher
# reads claude-json-seed.json and installs it at /root/.claude.json before
# launching claude (see build-guest-image.sh). The seed carries account identity,
# so it rides the SAME secret posture as the credential (never in run.env, never
# in the verified-binary cache). We are still inside the umask-077 window, so
# the file is created -rw------- with no world-readable moment; the chmod 600 is
# belt-and-braces. Selection is fail-closed and was already validated at the
# preflight; a failure here is unexpected -- abort rather than seed a partial or
# empty file that would drop the guest back to the onboarding/login wall.
# ---------------------------------------------------------------------
HOST_CLAUDE_JSON_SEED="$CREDS_DIR/claude-json-seed.json"
# Authoritative seed write: pass the CONCRETE resolved version (captured after
# the cache-ensure block) so the emitted seed's lastOnboardingVersion /
# lastReleaseNotesSeen carry a real dotted version, not a channel name.
if ! claude_vm_select_claude_json_seed "$CLAUDE_VERSION_RESOLVED" "$REPO_SRC" "$GUEST_REPO_MNT" < "$HOST_CLAUDE_JSON" > "$HOST_CLAUDE_JSON_SEED"; then
  rm -f "$HOST_CLAUDE_JSON_SEED"
  umask "$OLD_UMASK"
  echo "claude-vm: failed to select the identity seed (userID + oauthAccount) from" >&2
  echo "claude-vm: '$HOST_CLAUDE_JSON'. It passed the earlier preflight, so this is unexpected" >&2
  echo "claude-vm: (the file may have changed under us). Re-run 'claude' to confirm you are" >&2
  echo "claude-vm: logged in on the host, then retry." >&2
  exit 1
fi
chmod 600 "$HOST_CLAUDE_JSON_SEED"

# Restore the caller's umask before the clone so cloned worktree files
# keep normal perms (see the umask note above).
umask "$OLD_UMASK"

case "$REPO_MOUNT" in
  clone)
    # Persistent clone -- the guest never touches the live tree or .git.
    git clone --no-hardlinks "$REPO_SRC" "$WORKTREE" >/dev/null
    MOUNT_SHARED_DIR="$WORKTREE"
    ;;
  live)
    # Mount the live repo dir RW directly. Less isolated; opt-in.
    MOUNT_SHARED_DIR="$REPO_SRC"
    ;;
  *)
    echo "claude-vm: unknown repo.mount '$REPO_MOUNT' (expected 'clone' or 'live')" >&2
    exit 1
    ;;
esac

# Record run metadata so companion skills (diff / apply-local /
# apply-remote) can locate the source and worktree after exit.
#
# This writes only the PATH fields, which are all known now. The run's
# network/process endpoints (gvproxy_pid, gvproxy_sock, ssh_port, proxy_pid)
# do NOT exist yet -- they are created further below and APPENDED to run.meta
# by claude_vm_run_meta_put AT THE MOMENT each is created and confirmed live
# (issue #179), so run.meta never names an endpoint that failed to materialize.
# There is no vfkit_rest_uri: the guest powers itself off, so no host->guest
# REST channel exists. run.meta is thus the single source of truth for the
# launcher's own liveness checks and for a separate host-scoped cleanup tool.
RUN_META="$RUN/run.meta"
{
  printf 'run_id=%s\n' "$RUN_ID"
  printf 'repo_src=%s\n' "$REPO_SRC"
  printf 'repo_mount=%s\n' "$REPO_MOUNT"
  printf 'worktree=%s\n' "$MOUNT_SHARED_DIR"
  printf 'copy_back=%s\n' "$COPY_BACK"
} > "$RUN_META"

# Append a single `key=value` line to run.meta. Used to record each per-run
# endpoint (pid / socket / port) the instant it is created and confirmed live,
# rather than batching them at the paths-write above where they do not yet
# exist.
claude_vm_run_meta_put() {
  printf '%s=%s\n' "$1" "$2" >> "$RUN_META"
}

# ---------------------------------------------------------------------
# Guest run.env -- proxy config + mount tags + claude args. It NO LONGER
# carries any secret: the guest authenticates with the host's claude.ai
# OAuth credential, shared in via its own RO mount (mountTag=claudecreds)
# rather than an ANTHROPIC_API_KEY in this file. run.env is still written
# inside a subshell under umask 077 (created -rw------- with no world-
# readable window) and chmod 600'd afterward -- harmless belt-and-braces
# now that it holds no secret, and it keeps the discipline if a secret is
# ever reintroduced here.
# ---------------------------------------------------------------------
# Capture the host terminal geometry (issue #88). The vfkit stdio console is
# a plain byte pipe with NO out-of-band window-size channel, so the guest
# hvc1 tty defaults to a fixed 80x24 regardless of the host window. Seed the
# guest's tty size from the host's `stty size` so claude renders at the host
# terminal's dimensions. The hvc1 getty runs `stty cols/rows` from these env
# values BEFORE launching claude (env alone is insufficient -- programs that
# query the tty via TIOCGWINSZ need the kernel tty geometry set). This is
# one-time: the transport carries no live resize, so this seeds the initial
# size only. `stty size` prints "<rows> <cols>" on the controlling tty; it
# fails when stdin is not a tty (e.g. invoked from a pipe/tool), so guard it
# and leave COLUMNS/LINES empty when unavailable -- the guest then keeps its
# 80x24 default rather than getting a bogus size.
HOST_COLUMNS=""
HOST_LINES=""
# Save the host terminal's line settings so cleanup() can RESTORE them on exit
# (issue #88). Diagnosis (observed on real hardware): vfkit's `virtio-serial,
# stdio` bridge puts the host tty into RAW mode for the interactive guest
# session, and that raw mode SURVIVES vfkit's death -- the terminal is left
# with echo off and ICANON off (Enter sends \r, not \n). The copy-back
# confirmation prompt in copy_back() then hangs: `read -r` never sees a newline,
# typed input is not echoed, and Ctrl-C/Ctrl-D are swallowed. Capturing the
# pristine state here (via `stty -g`) lets cleanup() put the tty back into
# canonical mode BEFORE it prompts. Read from /dev/tty (not stdin) so the save
# works even when stdin is redirected -- the controlling terminal is what vfkit
# corrupts and what the prompt reads/writes. Empty when no controlling tty is
# available (non-interactive launch); cleanup() then skips the restore.
HOST_TTY_STATE=""
if [ -t 0 ]; then
  if _stty_size="$(stty size 2>/dev/null)"; then
    HOST_LINES="${_stty_size%% *}"
    HOST_COLUMNS="${_stty_size##* }"
  fi
fi
if [ -e /dev/tty ] && [ -r /dev/tty ]; then
  HOST_TTY_STATE="$(stty -g < /dev/tty 2>/dev/null || true)"
fi

RUN_ENV="$CONFIG_DIR/run.env"
# run.env value-quoting audit (issue #88). run.env is sourced under `set -a`
# by the guest boot launcher, so EVERY value line must be a safe shell
# assignment. Audited all values written below:
#   - HTTPS_PROXY / HTTP_PROXY (and their lowercase mirrors https_proxy /
#     http_proxy, issue #106 real-run fix -- apt honors only lowercase,
#     curl's plain-http path ignores uppercase): built from
#     $GVPROXY_HOST_ALIAS + $PROXY_PORT, both CONFIG scalars
#     (proxy.host_alias / proxy.port) a user can set to an arbitrary string
#     -> %q-quoted below (arbitrary-string carriers).
#   - CLAUDE_VM_COLUMNS / CLAUDE_VM_LINES: from `stty size` (always "rows cols"
#     numerics on a real tty; empty on a non-tty). Provably-numeric in
#     practice, but %q-quoted defensively since they come from a subprocess.
#   - NO_PROXY / no_proxy, REPO_TAG, POLICY_TAG, CLAUDEBIN_TAG, CLAUDECREDS_TAG,
#     DISABLE_AUTOUPDATER, IS_SANDBOX, and the renderer CLAUDE_CODE_* vars:
#     FIXED LITERALS (or emitted only for a validated enum value) -> provably
#     safe, left as-is.
#   - CLAUDE_ARGS: arbitrary user CLI args -> the per-arg-%q + outer-%q
#     round-trip below (its own dedicated fix).
(
  umask 077
  {
    printf 'HTTPS_PROXY=http://%q:%q\n' "$GVPROXY_HOST_ALIAS" "$PROXY_PORT"
    printf 'HTTP_PROXY=http://%q:%q\n' "$GVPROXY_HOST_ALIAS" "$PROXY_PORT"
    printf 'NO_PROXY=localhost,127.0.0.1\n'
    # Lowercase mirrors of the three vars above (issue #106 real-run fix).
    # apt-get honors ONLY lowercase http_proxy/https_proxy (never the
    # uppercase forms), and curl deliberately ignores uppercase HTTP_PROXY
    # for plain http:// URLs (the well-known "httpoxy" CGI-variable carve-
    # out; it does honor HTTPS_PROXY for https:// URLs). A real guest boot
    # confirmed: bare `apt-get install` mid-session failed to resolve
    # deb.debian.org with only the uppercase vars in run.env; prefixing the
    # SAME command with lowercase http_proxy/https_proxy succeeded. Same
    # value, same %q-quoting -- this is purely an additional-name mirror of
    # the audited HTTPS_PROXY/HTTP_PROXY/NO_PROXY lines above, so the value-
    # quoting audit comment above covers these too.
    printf 'https_proxy=http://%q:%q\n' "$GVPROXY_HOST_ALIAS" "$PROXY_PORT"
    printf 'http_proxy=http://%q:%q\n' "$GVPROXY_HOST_ALIAS" "$PROXY_PORT"
    printf 'no_proxy=localhost,127.0.0.1\n'
    printf 'REPO_TAG=repo\n'
    printf 'POLICY_TAG=policy\n'
    # The host-verified claude binary is shared into the guest under this
    # virtio-fs tag (mounted RO at /mnt/claudebin by the guest fstab); the
    # boot launcher runs /mnt/claudebin/claude against /mnt/repo.
    printf 'CLAUDEBIN_TAG=claudebin\n'
    # The claudecreds dir carries ALL host-rendered guest ~/.claude files --
    # not just credentials: the OAuth credential (.credentials.json, a SECRET),
    # the identity seed (claude-json-seed.json, account identity -- also
    # sensitive), and the rendered settings.json (permissions + enabledPlugins,
    # NOT a secret). Its containing dir is shared under this virtio-fs tag
    # (mounted RO at /mnt/claudecreds by the guest fstab); the boot launcher
    # installs each file into $HOME/.claude/ (mode 0600) so the guest comes up
    # authenticated, onboarded, and under the claude-vm permission posture. One
    # tag for all three avoids adding extra virtio-fs devices; the whole dir is
    # shredded on exit regardless of which files are secret.
    printf 'CLAUDECREDS_TAG=claudecreds\n'
    # Host terminal geometry (issue #88). Empty when not launched from a real
    # terminal; the boot launcher only runs `stty` when both are non-empty.
    # %q-quoted defensively (audit above): empty -> "''", numerics unchanged.
    printf 'CLAUDE_VM_COLUMNS=%q\n' "$HOST_COLUMNS"
    printf 'CLAUDE_VM_LINES=%q\n' "$HOST_LINES"
    # Renderer selection (issue #88) mapped from claude.renderer. The boot
    # launcher exports the matching CLAUDE_CODE_* var when this is set; an
    # empty value leaves claude on its own default.
    case "$CLAUDE_RENDERER" in
      classic)    printf 'CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1\n' ;;
      fullscreen) printf 'CLAUDE_CODE_NO_FLICKER=1\n' ;;
    esac
    # Disable claude's auto-updater in the guest (issue #88). This is the
    # documented Claude Code env knob for suppressing the self-update; the boot
    # launcher sources run.env under `set -a`, so it exports into claude's
    # environment for free. Belt-and-braces with the seeded autoUpdates: false
    # config key: the guest is egress-confined and runs an RO-mounted binary, so
    # an update attempt can only ever fail. Not a secret -- run.env is the right
    # vehicle.
    printf 'DISABLE_AUTOUPDATER=1\n'
    # IS_SANDBOX=1 unconditionally (issue #104). The guest runs claude as ROOT
    # (hvc1 autologin, issue #88), and claude REFUSES to start in
    # bypassPermissions as root unless IS_SANDBOX=1 (or CLAUDE_CODE_BUBBLEWRAP=1)
    # -- confirmed from the claude-code source quoted in anthropics/claude-code
    # #58510. The guest IS the sandbox (the VM is the isolation boundary), so set
    # it always: bypassPermissions is the default guest posture, and even under
    # permission_mode: default this is a correct, harmless assertion (the guest is
    # a sandbox regardless). A FIXED LITERAL -> provably safe under the run.env
    # `set -a` sourcing (value-quoting audit above). The boot launcher sources
    # run.env under `set -a`, so it exports into claude's environment for free.
    printf 'IS_SANDBOX=1\n'
    # Boot-time apt update flag (issue #106): whether the guest boot launcher
    # runs `apt-get update && apt-get -y upgrade` before claude starts. A
    # plain boolean scalar (the boot file's update_at_boot, default true) -> a fixed
    # 'true'/'false' literal is provably safe under the run.env `set -a`
    # sourcing (value-quoting audit above).
    printf 'CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT=%s\n' "$PACKAGES_UPDATE_AT_BOOT"
    # Boot-time plugin update flag (issue #107): whether the guest boot
    # launcher refreshes the marketplaces and updates the installed plugins
    # before claude starts. Same shape and safety argument as the apt flag
    # above -- a plain boolean scalar resolves to a fixed 'true'/'false'
    # literal, provably safe under the run.env `set -a` sourcing.
    printf 'CLAUDE_VM_PLUGINS_UPDATE_AT_BOOT=%s\n' "$PLUGINS_UPDATE_AT_BOOT"
    # CLAUDE_ARGS shell-quoting round-trip (issue #88). A flat unquoted join
    # (`${CLAUDE_ARGS[*]}`) breaks the guest boot the instant any arg carries
    # whitespace or a shell metacharacter: e.g. `--name "foo #7 ..."` sourced
    # as a bare line tries to EXECUTE `--name` (with the `#...` comment-
    # stripped) and the getty login program dies. Pre-#179 that respawned
    # forever; since #179's `Restart=no` it just ends the session -- either way
    # the boot is broken, which is what this quoting prevents.
    # Fix: inner per-arg %q (claude_vm_quote_args) preserves each arg's
    # boundaries; outer %q makes the whole CLAUDE_ARGS=<...> LINE safe to
    # `source` under `set -a`. The guest reverses it with
    # `eval "set -- $CLAUDE_ARGS"` (see build-guest-image.sh boot launcher).
    # Both halves of the contract live together in lib/config.sh's
    # claude_vm_quote_args comment. ZERO args -> the helper prints nothing, so
    # the line is `CLAUDE_ARGS=''` and the guest reconstructs an empty argv.
    # The `[@]+"[@]"` guard expands an EMPTY array to nothing under `set -u`
    # (an unguarded `"${CLAUDE_ARGS[@]}"` on an empty array is an unbound-
    # variable error on bash < 4.4), matching EXTRA_MOUNT_FLAGS below.
    printf 'CLAUDE_ARGS=%q\n' \
      "$(claude_vm_quote_args ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"})"
  } > "$RUN_ENV"
)
chmod 600 "$RUN_ENV"

# ---------------------------------------------------------------------
# Boot-time apt manifest (issue #106): the boot files' `packages:` (install at
# boot) + boot-tier apt_sources, delivered to the guest boot launcher via the SAME
# runconfig share as run.env (mountTag=runconfig -- see the EXTRA_MOUNT_FLAGS
# device list below). Plain newline/TSV files, NOT JSON: the base guest image
# carries no python3/jq (see provisioners/podman-mkosi.sh's minimal
# [Content] Packages= list), so the boot launcher -- plain bash -- parses
# these the same line-oriented way build-guest-image.sh's other manifest
# reads work. Neither file is secret, so no umask/chmod tightening beyond
# what CONFIG_DIR already has.
#
#   apt-install.list  -- one package name per line (the boot files' `packages:`,
#                        from the BOOT files' flattened `packages:`).
#   apt-sources.tsv   -- name<TAB>repo<TAB>key_url per line, the BOOT-tier
#                        apt_sources (issue #179): the merged apt_sources MINUS
#                        any name already baked into the image (claude_vm_boot_apt_sources
#                        filters baked names out -- a baked apt_source is already
#                        in the image's /etc/apt, so re-rendering it at boot is
#                        skipped). Same TSV shape the #105 build-time render
#                        consumes, so both boot-time and bake-time renders read
#                        identically-shaped input.
claude_vm_list_items "$MERGED_BOOT" '.packages' > "$CONFIG_DIR/apt-install.list"
claude_vm_boot_apt_sources "$MERGED_BOOT" "$MERGED_BAKE" > "$CONFIG_DIR/apt-sources.tsv"

# ---------------------------------------------------------------------
# Boot-time plugin manifest (issue #107): the plugin-side sibling of the apt
# manifest above, delivered over the SAME runconfig share, in the same plain
# newline/TSV shape (the guest has no python3/jq -- see the [Content]
# Packages= list in provisioners/podman-mkosi.sh -- so the boot launcher parses
# these line-by-line in plain bash).
#
#   plugin-marketplaces.tsv -- name<TAB>url per line: the EFFECTIVE marketplace
#                              set (bake ++ boot, deduped by name). The build
#                              registers the bake-declared ones (a failure
#                              there aborts it) and pre-registers the
#                              boot-declared ones best-effort (issue #226), so
#                              at boot the launcher only ADDS what the image
#                              turns out not to carry -- a boot-declared
#                              marketplace the build did not pre-register, for
#                              whichever reason the build logged, which is also
#                              why a boot-only marketplace still needs egress.
#   plugin-install.list     -- one `plugin@marketplace` ref per line, from the
#                              BOOT document's claude.plugins.install_at_boot.
#                              The BAKE document's claude.plugins.bake is NOT
#                              here: those are already inside the image, and
#                              re-installing them at boot would defeat the
#                              whole point of baking (and need egress a
#                              hard-secure config deliberately withholds).
claude_vm_effective_marketplaces "$MERGED_BAKE" "$MERGED_BOOT" > "$CONFIG_DIR/plugin-marketplaces.tsv"
claude_vm_list_items "$MERGED_BOOT" '.claude.plugins.install_at_boot' > "$CONFIG_DIR/plugin-install.list"

# ---------------------------------------------------------------------
# Egress allowlist -- write it where the proxy reads it. The proxy.cmd
# is expected to consume CLAUDE_VM_EGRESS_ALLOWLIST (a newline-delimited
# host file) instead of a hand-maintained allowlist baked into the cmd.
# ---------------------------------------------------------------------
EGRESS_ALLOWLIST="$CONFIG_DIR/egress.allow"
claude_vm_egress_hosts "$MERGED_BOOT" > "$EGRESS_ALLOWLIST"

# Warm-boot allowlist tightening (issue #49): the claude binary is fetched
# and verified HOST-SIDE, so the GUEST never reaches claude.ai /
# downloads.claude.ai for it. When the verified binary did NOT need
# fetching this run (warm boot -- already cached), drop those two
# binary-download hosts from the guest's egress allowlist so the guest's
# attack surface shrinks to exactly what the in-VM claude needs at runtime
# (e.g. api.anthropic.com). On a cold boot the binary was already fetched
# by the HOST before this point too, so the guest still does not need them
# -- but we keep them present on cold boots to avoid surprising an operator
# who lists them expecting the first-run fetch to use the guest path. The
# drop is keyed on CLAUDE_VM_CACHE_NETWORK being a warm/cached state.
case "${CLAUDE_VM_CACHE_NETWORK:-}" in
  warm|channel-resolve)
    # Remove claude.ai and downloads.claude.ai (and nothing else) from the
    # effective allowlist for this run. grep -v with anchored, dot-escaped
    # patterns so we do not also strip an unrelated host that contains the
    # substring.
    if [ -s "$EGRESS_ALLOWLIST" ]; then
      TIGHTENED="$CONFIG_DIR/egress.allow.tightened"
      grep -ivE '^[[:space:]]*(claude\.ai|downloads\.claude\.ai)[[:space:]]*$' \
        "$EGRESS_ALLOWLIST" > "$TIGHTENED" || true
      mv -f "$TIGHTENED" "$EGRESS_ALLOWLIST"
      echo "claude-vm: warm boot -- dropped claude.ai/downloads.claude.ai from the guest egress allowlist (binary already cached host-side)." >&2
    fi
    ;;
esac

# ---------------------------------------------------------------------
# Boot-time apt derived egress (issue #106).
#
# Boot-file `packages:` / `update_at_boot` run apt-get INSIDE the
# guest at boot, through this proxy -- so the Debian mirror hosts (and any
# apt_sources hosts, bake or boot) must be reachable. Add them to the allowlist
# iff boot-time apt work actually needs them (claude_vm_boot_apt_egress_needed:
# install_at_boot nonempty, or update_at_boot true, or
# add_apt_uris_to_allowlist: always) -- "auto" (the default) with no boot-time
# apt work derives NOTHING, so a hard-secure all-baked config leaves package
# repos unreachable from the guest, by design. Every derived addition is
# logged (no silent allowlist growth). Runs AFTER the warm-boot tightening
# above so a dropped claude.ai/downloads.claude.ai entry is never
# re-introduced by this step.
if claude_vm_boot_apt_egress_needed "$MERGED_BOOT"; then
  DERIVED_APT_HOSTS="$CLAUDE_VM_DEBIAN_MIRROR_HOSTS $(claude_vm_apt_source_hosts "$MERGED_BAKE" "$MERGED_BOOT" | tr '\n' ' ')"
  EXISTING_HOSTS=" $(tr '\n' ' ' < "$EGRESS_ALLOWLIST" 2>/dev/null) "
  for _host in $DERIVED_APT_HOSTS; do
    case "$EXISTING_HOSTS" in
      *" $_host "*) ;;
      *)
        printf '%s\n' "$_host" >> "$EGRESS_ALLOWLIST"
        EXISTING_HOSTS="${EXISTING_HOSTS}${_host} "
        echo "claude-vm: derived apt egress -- added '$_host' to the guest egress allowlist (boot-time apt work configured)." >&2
        ;;
    esac
  done
  unset _host
fi

# ---------------------------------------------------------------------
# Boot-time marketplace derived egress (issue #107).
#
# The plugin-side sibling of the apt derivation above, with the same auto/always
# semantics. Marketplace URL hosts are added to the allowlist IFF a boot-side
# ensure/install/update will actually run (claude_vm_boot_marketplace_egress_needed:
# a marketplace declared in a boot file whose name is not also bake-declared, a
# nonempty install_at_boot, or update_at_boot true with at least one marketplace
# configured) OR the operator opted in with
# claude.plugins.add_marketplace_uris_to_allowlist: always.
#
# The bake-declared membership test reads the DECLARATION, not the image: since
# issue #226 the build only TRIES to pre-register a boot-declared marketplace, and
# the host cannot know whether it succeeded, so the gate derives the host either
# way.
#
# "auto" (the default) with everything bake-declared and updates off derives
# NOTHING -- and the guest STILL has working plugins, because the baked ones need
# no marketplace at all. That is the hard-secure posture the issue's first
# acceptance criterion names. Every derived addition is logged, so the allowlist
# never grows silently. Runs AFTER the warm-boot tightening so a dropped
# claude.ai/downloads.claude.ai entry is never re-introduced here.
#
# A marketplace whose `url` is not an http(s) URI (the `owner/repo` GitHub
# shorthand, or a local path) derives no host -- claude_vm_marketplace_hosts
# degrades quietly rather than guessing. The shorthand resolves to github.com,
# which the example egress allowlist already carries; a config that uses it
# with github.com removed from egress.allow gets a marketplace add that cannot
# reach its source, so warn once when that combination is actually in play
# rather than silently letting the boot phase fail.
if claude_vm_boot_marketplace_egress_needed "$MERGED_BOOT" "$MERGED_BAKE"; then
  DERIVED_MP_HOSTS="$(claude_vm_marketplace_hosts "$MERGED_BAKE" "$MERGED_BOOT" | tr '\n' ' ')"
  EXISTING_HOSTS=" $(tr '\n' ' ' < "$EGRESS_ALLOWLIST" 2>/dev/null) "
  for _host in $DERIVED_MP_HOSTS; do
    case "$EXISTING_HOSTS" in
      *" $_host "*) ;;
      *)
        printf '%s\n' "$_host" >> "$EGRESS_ALLOWLIST"
        EXISTING_HOSTS="${EXISTING_HOSTS}${_host} "
        echo "claude-vm: derived marketplace egress -- added '$_host' to the guest egress allowlist (boot-time marketplace/plugin work configured)." >&2
        ;;
    esac
  done
  unset _host
  # Name the entries whose url yields no derivable host. Counted PER ENTRY (see
  # claude_vm_marketplaces_without_host) -- comparing marketplace-count against
  # host-count would misfire whenever two marketplaces share a host, which two
  # github.com urls routinely do.
  _mp_nohost="$(claude_vm_marketplaces_without_host "$MERGED_BAKE" "$MERGED_BOOT" | tr '\n' ' ')"
  if [ -n "${_mp_nohost// /}" ]; then
    echo "claude-vm: NOTE -- these claude.marketplaces entries have no http(s) url (e.g. an 'owner/repo' GitHub" >&2
    echo "claude-vm: shorthand), so no egress host could be derived for them: ${_mp_nohost% }" >&2
    echo "claude-vm: such a source resolves against github.com; keep github.com in egress.allow, or give the entry" >&2
    echo "claude-vm: an explicit https:// url so its host is derived automatically." >&2
  fi
  unset _mp_nohost
fi

export CLAUDE_VM_EGRESS_ALLOWLIST="$EGRESS_ALLOWLIST"
# The proxy.cmd must bind the port the guest's HTTPS_PROXY points at (set
# in run.env above). Export it so the bundled tinyproxy launcher -- and any
# override that wants it -- listens on the right port.
export CLAUDE_VM_PROXY_PORT="$PROXY_PORT"

# Guard: an empty effective allowlist means NEITHER config layer set
# egress.allow. Combined with an allow-all proxy default this would
# negate the VM's egress confinement -- the guest could reach anything.
# The proxy.cmd owns the actual fail-open/fail-closed policy, so we do
# not hard-fail here, but the operator must be told egress is unconfined.
if ! grep -q '[^[:space:]]' "$EGRESS_ALLOWLIST" 2>/dev/null; then
  echo "claude-vm: WARNING -- effective egress.allow is EMPTY (no hosts in either config layer)." >&2
  echo "claude-vm: the guest's outbound access is unconfined unless proxy.cmd fails closed on an empty allowlist." >&2
  echo "claude-vm: set egress.allow in ~/.config/claude-vm/config-boot.yml or <repo>/.claude-vm/config-boot.yml to confine egress." >&2
fi

if [ -z "$PROXY_CMD" ]; then
  # proxy.cmd defaults to the bundled tinyproxy launcher; reaching here
  # means a config layer explicitly set proxy.cmd to an empty value.
  echo "claude-vm: proxy.cmd is set to an empty value in config; cannot start the forward proxy." >&2
  echo "claude-vm: leave proxy.cmd unset to use the bundled tinyproxy launcher, or set it" >&2
  echo "claude-vm: to a command that reads \$CLAUDE_VM_EGRESS_ALLOWLIST." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Build extra-mount device flags from config (mounts: list).
# Each entry becomes a virtio-fs device. The repo auto-mount (tag
# 'repo') and the run-config mount (tag 'runconfig') are always added
# below; these are the user's EXTRA mounts.
# ---------------------------------------------------------------------
EXTRA_MOUNT_FLAGS=()
# Split each record BY HAND rather than with 'IFS=<tab> read -r src tag mode'.
# A tab is IFS WHITESPACE, so read collapses a RUN of tabs into one separator:
# an empty MIDDLE field vanishes and every later field shifts left. A mounts
# entry written with an empty tag is emitted as source<TAB><TAB>mode, and the
# collapsing read took the MODE as the mount TAG -- the share went out as
# mountTag=ro (or rw), and two such entries would share that one tag. The
# emitter (claude_vm_mount_specs, via yq @tsv) joins all three fields, so both
# separators are always present and the three expansions below are total.
MOUNT_TAB=$'\t'
while IFS= read -r mount_record; do
  src=${mount_record%%$MOUNT_TAB*}
  mount_rest=${mount_record#*$MOUNT_TAB}
  tag=${mount_rest%%$MOUNT_TAB*}
  mode=${mount_rest#*$MOUNT_TAB}
  [ -z "$src" ] && continue
  # Expand a leading ~ to $HOME (config is YAML, not shell).
  case "$src" in
    "~"/*) src="$HOME/${src#"~/"}" ;;
    "~") src="$HOME" ;;
  esac
  # mode is advisory for virtio-fs share dirs; recorded for the guest
  # mount step. vfkit shares the dir; the guest mounts ro/rw per mode.
  EXTRA_MOUNT_FLAGS+=(--device "virtio-fs,sharedDir=$src,mountTag=$tag")
done < <(claude_vm_mount_specs "$MERGED_BOOT")

# ---------------------------------------------------------------------
# Launch: proxy -> gvproxy -> vfkit. Copy-back on exit (clone mode).
# ---------------------------------------------------------------------
PROXY_PID=""
GV_PID=""
# cleanup() idempotence guard (issue #179): set to 1 the first time cleanup()
# runs so the EXIT trap that follows a signal-triggered INT/TERM trap does not
# run the clone-discard decision and end-of-run prints a second time.
CLEANUP_DONE=""
# Per-run image clone lifecycle state (issue #179). CLONE_CREATED flips to 1
# once the clone is materialized just before vfkit; VM_EXIT_STATUS records
# vfkit's exit code so cleanup() can decide discard (clean) vs retain
# (abnormal). Declared here so cleanup()'s guards are well-defined if a signal
# fires before the clone exists.
CLONE_CREATED=""
VM_EXIT_STATUS=""

# Is the source working tree dirty (uncommitted tracked changes or
# untracked, non-ignored files)? Returns 0 (dirty) / 1 (clean). A
# non-git source or a git failure is treated as "dirty" so we err on
# the side of NOT clobbering unattended.
src_tree_is_dirty() {
  local status
  git -C "$REPO_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  status="$(git -C "$REPO_SRC" status --porcelain 2>/dev/null)" || return 0
  [ -n "$status" ]
}

# Run the rsync that mirrors the guest worktree back over the source,
# excluding .git so local history/branch state is untouched. rsync
# errors are NOT suppressed -- a failure must be visible. Returns
# rsync's exit status.
#
# ADDITIVE-ONLY by design: --delete is deliberately NOT passed, so files the
# guest added or changed are copied back but files the guest DELETED are not
# propagated -- a deletion in the throwaway guest never removes a file from the
# operator's source tree.
#
# --checksum (issue #88): decide "same or different" by CONTENT hash, not the
# default size+mtime heuristic. A clone checkout skews file mtimes relative to
# the source without changing content; without --checksum rsync would rewrite
# those content-identical files (harmless but noisy, and it made the dirty-gate
# preview below flag files the session never touched). --checksum makes the
# real copy-back and its dry-run preview agree on exactly which files changed.
copy_back_rsync() {
  rsync -a --checksum --exclude '.git' "$WORKTREE"/ "$REPO_SRC"/ \
    || { echo "claude-vm: copy-back failed (rsync); worktree retained at $WORKTREE" >&2; return 1; }
}

# Print the rsync itemize lines for CONTENT/STRUCTURAL changes only (issue #88).
# Runs the copy-back as a --checksum dry-run and filters --itemize-changes output
# to lines whose FIRST char is `>` (a file transfer) or `c` (a creation/change of
# a non-regular entry, e.g. a dir or symlink). The `*` in the pattern would match
# a message line such as `*deleting`, but copy_back_rsync is ADDITIVE-ONLY by
# design: it never passes --delete, so rsync never emits a `*deleting` line here
# and guest-side deletions are NOT propagated back to the source. The `*` is kept
# only for defensive completeness should the additive-only choice ever change.
# Lines beginning with `.` are ATTRIBUTE-ONLY (mtime/perm/owner differ but content
# does not) and are DELIBERATELY excluded -- with --checksum a content-identical
# file whose mtime is skewed itemizes as `.f..t......`, which must NOT count as a
# change. Prints nothing (and the caller treats that as "no real changes") when
# only attribute-only or no differences exist. rsync's own errors flow to stderr
# (no 2>/dev/null) so a broken preview is visible.
copy_back_real_changes() {
  rsync -a --checksum --dry-run --itemize-changes --exclude '.git' \
    "$WORKTREE"/ "$REPO_SRC"/ \
    | grep -E '^[>c*]' || true
}

# Re-assert the host terminal's saved line settings on /dev/tty (issue #88).
# Called from both cleanup() (once, at the top of the trap) and copy_back()
# (again, immediately before the confirmation prompt). Same pattern and guards
# in both places: prefer the exact saved state (stty -g captured at launch),
# fall back to `stty sane`, and never let a tty-restore failure abort the
# caller (|| true). Guarded on a non-empty saved state and a writable /dev/tty,
# so it is a no-op for a non-interactive launch (HOST_TTY_STATE empty).
restore_host_tty() {
  if [ -n "${HOST_TTY_STATE:-}" ] && [ -e /dev/tty ] && [ -w /dev/tty ]; then
    stty "$HOST_TTY_STATE" < /dev/tty 2>/dev/null \
      || stty sane < /dev/tty 2>/dev/null \
      || true
  fi
}

copy_back() {
  # Default post-exit behavior: copy the worktree's changes back to the
  # local source. Only meaningful in clone mode (live mode already wrote
  # to the source in place). copy_back=none disables it.
  #
  # Safety: this runs unattended on every trapped exit (including
  # Ctrl-C), so it must never silently clobber uncommitted local edits.
  # It mirrors the safer apply path documented in the
  # claude-vm-apply-local skill: if the local source tree is dirty, it
  # previews what copy-back would change and requires explicit
  # confirmation; if clean, it proceeds (surfacing any rsync error).
  [ "$REPO_MOUNT" = "clone" ] || return 0
  case "$COPY_BACK" in
    none) return 0 ;;
    local|"")
      # Compute the REAL (content/structural) changes ONCE, up front (issue #88).
      # This is the --checksum-based, attribute-only-filtered set (see
      # copy_back_real_changes). It gates BOTH the clean and dirty paths so a
      # tree that differs only by clone-checkout mtime skew -- files the session
      # never touched -- never triggers copy-back or its scary prompt.
      local real_changes
      real_changes="$(copy_back_real_changes)"
      if [ -z "$real_changes" ]; then
        # Nothing of substance to apply: no content added, changed, or removed.
        # Skip BOTH the prompt and the rsync entirely, even when the source tree
        # is otherwise dirty -- there is nothing for copy-back to overwrite.
        echo "claude-vm: copy-back: no content changes to apply." >&2
        return 0
      fi
      if src_tree_is_dirty; then
        echo "claude-vm: WARNING -- local source ($REPO_SRC) has uncommitted changes." >&2
        echo "claude-vm: copy-back would overwrite overlapping files. Content changes it would apply:" >&2
        # Show the FILTERED preview: content/structural changes only. Attribute-
        # only itemize lines (leading `.`, e.g. mtime-only skew) are deliberately
        # excluded here -- they are exactly the noise that made this prompt fire
        # spuriously. real_changes is already that filtered set.
        printf '%s\n' "$real_changes" >&2
        # Require explicit confirmation. Read from the controlling tty so
        # this works even when invoked from the EXIT/INT trap with stdin
        # consumed. If no usable tty is available (non-interactive, or
        # /dev/tty present but not connected to a terminal), default to
        # SKIP rather than clobber.
        #
        # The `< /dev/tty` open happens before `read` runs, so a stray
        # 2>/dev/null on `read` alone would NOT suppress a failed open
        # ("Device not configured" / "no such device or address") -- the
        # shell opens the redirect and reports that error itself. To
        # actually swallow it, the brace group (which includes the
        # redirect) is what gets 2>/dev/null. A failed open then makes the
        # group fail quietly, the `if` takes the else branch, and reply
        # stays empty -- which routes to SKIP. cleanup() restores the host
        # tty to canonical mode BEFORE calling copy_back (issue #88), so this
        # read is not defeated by vfkit's leftover raw-mode terminal.
        #
        # Re-assert the tty state HERE, immediately before the prompt, in
        # addition to cleanup()'s early restore. On real hardware (after the
        # cleanup()-top restore) the tty ended up icanon+echo ON but ICRNL
        # OFF: Enter (\r) neither terminated the read nor translated to \n,
        # and echoed as `^M` -- only a literal newline (Shift+Enter) submitted.
        #
        # Mechanism CONFIRMED (poisoned snapshot): HOST_TTY_STATE is a
        # launch-time snapshot (`stty -g < /dev/tty` at startup) of whatever
        # the terminal already was. If the terminal was ALREADY corrupted at
        # launch, restoring that snapshot faithfully reproduces the corruption.
        # This is a real, confirmed incident: a prior crashed claude-vm run
        # left the user's terminal tab carrying -icrnl, and every subsequent
        # run snapshotted that already-broken state and then "restored" it
        # right here -- the restore worked perfectly, its input was poisoned.
        # (The user's shell masks it between runs because zsh's line editor
        # drives the terminal itself and does not need ICRNL.)
        #
        # So restore_host_tty() is not enough on its own: force the exact
        # termios bits this confirmation read requires, regardless of what the
        # snapshot contained. We need ICRNL (Enter's \r -> \n), ICANON (line
        # discipline), and ECHO (visible typing). Force ONLY those three and
        # leave everything else to the snapshot restore. We do NOT change
        # restore_host_tty() itself: cleanup()'s final restore must keep
        # putting the terminal back to exactly the launch state -- even a weird
        # one -- as its polite contract; the force applies only where WE need
        # specific semantics, i.e. our own prompt.
        restore_host_tty
        # Guard the same way restore_host_tty() does (writable /dev/tty) rather
        # than relying on the redirect failing -- consistent with the sibling.
        if [ -e /dev/tty ] && [ -w /dev/tty ]; then
          stty icrnl icanon echo < /dev/tty 2>/dev/null || true
        fi
        local reply=""
        if [ -t 0 ] || { [ -e /dev/tty ] && [ -r /dev/tty ]; }; then
          printf 'claude-vm: apply copy-back over the dirty source tree? [y/N] ' >&2
          if { read -r reply < /dev/tty; } 2>/dev/null; then :; else reply=""; fi
        fi
        # Belt-and-braces: strip a trailing CR so a raw `y\r` still matches if
        # ICRNL is somehow still off at read time (issue #88).
        reply=${reply%$'\r'}
        case "$reply" in
          y|Y|yes|YES)
            echo "claude-vm: confirmed; copying back to $REPO_SRC..." >&2
            copy_back_rsync || true
            ;;
          *)
            echo "claude-vm: copy-back SKIPPED; worktree retained at $WORKTREE" >&2
            echo "claude-vm: review with /claude-vm-diff and apply with /claude-vm-apply-local when ready." >&2
            ;;
        esac
      else
        # Clean tree AND real content changes exist: apply them (fast path). The
        # copy_back_rsync uses --checksum too, so it rewrites exactly the files
        # in real_changes, not the mtime-skewed identical ones.
        echo "claude-vm: copy-back to local source ($REPO_SRC) from worktree..." >&2
        copy_back_rsync || true
      fi
      ;;
    *)
      echo "claude-vm: unknown repo.copy_back '$COPY_BACK' (expected local|none); skipping" >&2
      ;;
  esac
}

cleanup() {
  # Run at most ONCE (issue #179). cleanup() can be reached twice: a signal
  # (INT/TERM) fires the trap, and then the ensuing `exit` fires the EXIT trap
  # too. The clone-discard decision and the end-of-run prints must happen once.
  # Guard with a done-flag; the second entry is a no-op.
  if [ -n "${CLEANUP_DONE:-}" ]; then
    return 0
  fi
  CLEANUP_DONE=1

  # By the time this runs, vfkit has already exited: bash defers traps while a
  # foreground child runs, so the INT/TERM/EXIT trap cannot fire mid-vfkit
  # (see the comment above the vfkit launch). There is no process to stop or
  # reap here -- cleanup() only tidies state and decides the clone's fate.

  # sync so writes the guest flushed to the attached image (the per-run clone)
  # reach the host filesystem buffers that back the APFS clone's written
  # blocks. With per-run clones the blast radius of a torn write is one
  # throwaway session's clone (discarded on clean exit anyway), never the
  # shared base image; this sync narrows even that window. Cheap, always safe.
  sync 2>/dev/null || true

  # Restore the host terminal first. vfkit's `virtio-serial,stdio` bridge
  # leaves the host tty in RAW mode (echo off, ICANON off -- Enter sends \r
  # not \n), and that state SURVIVES vfkit's death. Without this restore the
  # copy_back() confirmation `read -r` never completes (no newline arrives)
  # and typed input is invisible -- observed hanging on real hardware.
  # restore_host_tty() puts the tty back into canonical mode (operating on
  # /dev/tty, the controlling terminal vfkit corrupted and the prompt uses).
  # copy_back() re-asserts it just before its prompt (see the comment there).
  restore_host_tty

  # Clean-vs-abnormal is driven solely by VM_EXIT_STATUS (issue #179), which
  # reflects vfkit's REAL exit status. A clean guest poweroff yields 0 ->
  # discard the clone. Nonzero -> retain the clone.
  local clean_exit=0
  if [ "${VM_EXIT_STATUS:-}" = "0" ]; then
    clean_exit=1
  fi

  [ -n "$GV_PID" ] && kill "$GV_PID" 2>/dev/null || true
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
  copy_back
  # Remove the merged-config temp files. Guarded for the case where the
  # trap fires before the merged docs are set (unset/empty then). Written as
  # an `if` rather than `[ -n ... ] && rm` so a false guard does not make
  # the function return non-zero and trip `set -e` before the echoes below.
  if [ -n "${MERGED_BAKE:-}" ] || [ -n "${MERGED_BOOT:-}" ]; then
    rm -f "${MERGED_BAKE:-}" "${MERGED_BOOT:-}"
  fi
  # The host claude.ai OAuth credential AND the identity seed (issue #88)
  # are transient secrets sharing this dir: remove it on every exit (including
  # Ctrl-C) so neither lingers after the run. The run dir itself is retained
  # for the companion diff/apply skills, but these secrets must NOT be -- they
  # are never persisted past the live VM. Guarded like the merged docs above so an early
  # trap (before CREDS_DIR is set) is harmless.
  if [ -n "${CREDS_DIR:-}" ]; then
    rm -rf "$CREDS_DIR"
  fi
  # The full raw Keychain blob is normally removed immediately after selection
  # (before this trap is installed), but guard here too: if a signal somehow
  # interleaved, do not let the unselected full blob outlive the run.
  if [ -n "${RAW_CREDENTIAL:-}" ]; then
    rm -f "$RAW_CREDENTIAL"
  fi
  # Remove the short-path gvproxy socket dir (issue #88). It lives under
  # $TMPDIR (not under $RUN), so it is NOT covered by the run-dir retention --
  # remove it here so the socket + vfkit's derived child socket do not linger.
  # Guarded for an early-trap fire (before SOCK_DIR is set).
  if [ -n "${SOCK_DIR:-}" ]; then
    rm -rf "$SOCK_DIR"
  fi
  echo "claude-vm: egress capture retained at: $PCAP" >&2
  if [ -n "${GUEST_CONSOLE_LOG:-}" ]; then
    echo "claude-vm: guest console log retained at: $GUEST_CONSOLE_LOG" >&2
  fi
  # The proxy + gvproxy logs (issue #88) are retained off-terminal so their
  # diagnostics do not flood the interactive session but stay diagnosable.
  # Guarded like the others for an early-trap fire (before they are set).
  if [ -n "${GVPROXY_LOG:-}" ]; then
    echo "claude-vm: gvproxy log retained at: $GVPROXY_LOG" >&2
  fi
  if [ -n "${PROXY_LOG:-}" ]; then
    echo "claude-vm: proxy log retained at: $PROXY_LOG" >&2
  fi
  # Per-run image clone lifecycle (issue #179). On a CLEAN exit, discard the
  # clone -- it is throwaway and reclaiming its written blocks is the whole
  # point of the immutable-base design. On an ABNORMAL exit (nonzero vfkit
  # status or a signal), RETAIN it for forensics and print its path, so a torn
  # or corrupted session's on-disk state can be inspected. Guarded on
  # CLONE_CREATED so an early-trap fire (before the clone is materialized) is a
  # no-op. The immutable BASE image ($GUEST_IMAGE) is never touched here either
  # way -- only the per-run clone.
  if [ -n "${CLONE_CREATED:-}" ] && [ -n "${GUEST_IMAGE_CLONE:-}" ]; then
    if [ "$clean_exit" -eq 1 ]; then
      rm -f "$GUEST_IMAGE_CLONE"
    else
      echo "claude-vm: abnormal exit -- per-run guest image clone RETAINED for forensics at: $GUEST_IMAGE_CLONE" >&2
    fi
  fi
  echo "claude-vm: run dir (persistent): $RUN" >&2
}
# Replace the narrow interim trap (armed right after the OAuth credential was
# written, to cover the clone window) with the full cleanup() now that the
# worktree, proxy, and gvproxy state all exist for copy_back to act on.
trap cleanup EXIT INT TERM

# Start the forward proxy. It reads the allowlist from
# $CLAUDE_VM_EGRESS_ALLOWLIST (exported above).
#
# REDIRECT both host-side background processes' stdout AND stderr to RETAINED
# log files under $RUN (issue #88). Without this they inherit the interactive
# terminal's fd 1/2 (the hvc1 claude session), and their per-request/per-packet
# diagnostics flood and destroy that session: gvproxy's sniffer.go emits a
# continuous stream of `I<ts> ... sniffer.go:NNN recv/send tcp ...` lines, and
# tinyproxy emits `NOTICE ... Proxying refused` lines. Routed off-terminal, but
# RETAINED (not /dev/null) so a proxy/gvproxy failure stays diagnosable --
# matching how the guest boot console is captured to $GUEST_CONSOLE_LOG. The
# paths are echoed in cleanup() alongside the other retained-artifact lines.
eval "$PROXY_CMD" >"$PROXY_LOG" 2>&1 &
PROXY_PID=$!
# Record the forward-proxy pid the moment it is spawned (issue #179): run.meta
# is the single source of truth a separate host-scoped cleanup tool uses to
# find and reap this run's processes.
claude_vm_run_meta_put proxy_pid "$PROXY_PID"

# Clear any stale gvproxy socket corpse before gvproxy tries to bind it (issue
# #179). SOCK_DIR is a fresh per-run mktemp dir so a collision here is unlikely,
# but a unique PATH is not proof the path is bindable: a leftover socket FILE
# with no listener makes bind() fail `address already in use` just like a busy
# port. claude_vm_clear_stale_unix_sock removes a corpse; if a LIVE listener
# somehow held it (a concurrent sibling), it returns 1 and we abort rather than
# stomping the sibling.
if ! claude_vm_clear_stale_unix_sock "$GVPROXY_SOCK"; then
  echo "claude-vm: gvproxy socket path '$GVPROXY_SOCK' is held by a live listener; aborting" >&2
  exit 1
fi

# Acquire a per-run FREE SSH-forward TCP port for gvproxy (issue #179). gvproxy
# always binds -ssh-port (default 2222); passing a kernel-assigned free port
# lets N concurrent runs coexist instead of every run fighting over 2222.
SSH_PORT="$(claude_vm_acquire_free_tcp_port)" || {
  echo "claude-vm: could not acquire a free SSH-forward TCP port for gvproxy" >&2
  exit 1
}

"$GVPROXY_BIN" --listen-vfkit "unixgram://$GVPROXY_SOCK" --ssh-port "$SSH_PORT" \
  --pcap "$PCAP" \
  >"$GVPROXY_LOG" 2>&1 &
GV_PID=$!

# Readiness: wait for a LIVE listener on the gvproxy socket, not merely for the
# socket FILE to exist (issue #179). The old check tested `[ -S "$sock" ]`,
# which a stale corpse from a dead run passes even though gvproxy never came up.
# claude_vm_unix_sock_live confirms a process actually holds the socket open.
for _ in $(seq 1 50); do
  claude_vm_unix_sock_live "$GVPROXY_SOCK" && break
  sleep 0.1
done
if ! claude_vm_unix_sock_live "$GVPROXY_SOCK"; then
  echo "claude-vm: gvproxy socket never came up (no live listener at $GVPROXY_SOCK)" >&2
  exit 1
fi
# gvproxy is confirmed live: record its pid, socket, and ssh-port in run.meta
# now (write-as-you-go), so run.meta only ever names endpoints that materialized.
claude_vm_run_meta_put gvproxy_pid "$GV_PID"
claude_vm_run_meta_put gvproxy_sock "$GVPROXY_SOCK"
claude_vm_run_meta_put ssh_port "$SSH_PORT"

# The verified claude binary is shared into the guest by its CONTAINING
# DIRECTORY (virtio-fs shares a dir, not a single file) under tag
# 'claudebin', mounted RO at /mnt/claudebin in the guest. The guest boot
# launcher runs /mnt/claudebin/claude against /mnt/repo.
CLAUDE_BIN_DIR="$(dirname "$CLAUDE_BIN_HOST")"

# Dual virtio-serial console topology (issue #88). Device ORDER is
# deterministic: the 1st virtio-serial device becomes guest hvc0, the 2nd
# becomes hvc1.
#
#   1st: virtio-serial,logFilePath=$GUEST_CONSOLE_LOG -> hvc0. The kernel
#        cmdline keeps console=hvc0, so all kernel + systemd boot output (and
#        the boot launcher's diagnostics, written to /dev/console) flow to this
#        capture file -- preserving #87's observability and keeping boot noise
#        off the interactive terminal.
#   2nd: virtio-serial,stdio -> hvc1. The launching terminal IS bridged here;
#        the guest runs claude on an autologin getty@hvc1 (so the terminal
#        becomes the interactive claude session). vfkit's stdio attachment is a
#        bidirectional byte pipe that requires a real controlling tty on the
#        host -- so claude-vm must be launched from a terminal, not a pipe.
#
# ---------------------------------------------------------------------
# Per-run immutable-image clone (issue #179). The cached base $GUEST_IMAGE is
# NEVER attached to a VM. APFS-clone it (cp -c) into the run dir and boot the
# CLONE, so N concurrent sessions share one immutable base with no cross-session
# leakage and no multi-writer corruption. cp -c is instant + zero-copy on APFS
# (macOS default fs). If cp -c fails (non-APFS volume, e.g. an operator who put
# their config dir on a case-sensitive HFS+ or exFAT volume), fall back to a
# plain full copy with a warning -- correctness (a per-run image) over speed.
# The .version sidecar is NOT cloned: the clone is throwaway and the base's
# version was already checked by ensure_guest_image above.
# ---------------------------------------------------------------------
if cp -c "$GUEST_IMAGE" "$GUEST_IMAGE_CLONE" 2>/dev/null; then
  CLONE_CREATED=1
elif cp "$GUEST_IMAGE" "$GUEST_IMAGE_CLONE"; then
  CLONE_CREATED=1
  echo "claude-vm: WARNING -- APFS clone (cp -c) of the guest image failed; fell back to a full copy." >&2
  echo "claude-vm: the base image volume may not be APFS. This works but is slower and uses more disk per run." >&2
else
  echo "claude-vm: failed to create a per-run clone of the guest image at $GUEST_IMAGE_CLONE" >&2
  exit 1
fi

# Last host-side context before this terminal becomes the guest console
# (issue #179). Once vfkit launches, the hvc1 stdio bridge owns the screen
# until the session ends, so print the paths an operator needs to inspect the
# LIVE run from a second terminal now -- cleanup() re-lists the retained
# artifacts only after exit, which is too late for mid-session inspection.
echo "claude-vm: run dir:   $RUN" >&2
echo "claude-vm: run.env:   $RUN_ENV" >&2
echo "claude-vm: run.meta:  $RUN_META" >&2
echo "claude-vm: handing this terminal to the guest console (hvc1)..." >&2

# Give Ctrl-C (and Ctrl-Z / Ctrl-\ / Ctrl-S / Ctrl-Q) to the GUEST for the
# session's duration (issue #179 real-boot finding). vfkit's stdio bridge
# leaves the host tty with ISIG ENABLED, so a Ctrl-C raised SIGINT on the
# host -- straight into foreground vfkit, which force-stopped the guest after
# its internal timeout -- and guest claude never saw the keystroke at all
# (observed live: a single Ctrl-C aborted the session instantly instead of
# starting claude's two-press exit dance). Disabling isig/ixon makes those
# control characters plain BYTES: vfkit forwards them down the console, the
# GUEST's line discipline turns ^C into SIGINT for claude inside, and the
# session ends the designed way (claude exits 0 -> guest powers off).
#
# Deliberate consequence: the keyboard can no longer abort a WEDGED guest
# from this terminal -- there is no host signal to send. The recovery path is
# `kill <vfkit pid>` from another terminal (vfkit tears the guest down within
# its own ~5s bound and cleanup() runs normally). restore_host_tty() puts the
# full saved state (including isig/ixon) back on every exit path.
if [ -n "${HOST_TTY_STATE:-}" ] && [ -e /dev/tty ] && [ -w /dev/tty ]; then
  stty -isig -ixon < /dev/tty 2>/dev/null || true
fi

# vfkit runs as a CHILD here (NOT exec'd), so cleanup() (trapped on
# EXIT/INT/TERM) runs the copy-back + clone-lifecycle + socket-dir removal
# when the session ends. Do NOT switch this to `exec vfkit` -- that would
# replace the shell and the trap would never fire.
#
# vfkit runs FOREGROUND (issue #179): no `set -m`, no backgrounding `&`. The
# guest powers ITSELF off when claude quits deliberately (the boot launcher
# starts systemd's poweroff on claude's exit 0), so there is no host->guest
# shutdown to drive -- vfkit exits on its own when the guest halts and its
# status lands in $? right below. Backgrounding vfkit breaks the boot
# outright: a backgrounded vfkit cannot attach its `virtio-serial,stdio`
# console to the terminal (real boot: `Error: operation not supported by
# device` at "Adding stdio console"), which is why the `vfkit ... & / wait $!`
# shape never booted. Foreground is load-bearing, not stylistic.
#
# With isig off (above), every control character is a byte forwarded to the
# guest, so every session end is claude exiting (double Ctrl-C included) and
# the host handles no keyboard signals for it. And bash defers traps while a
# foreground child runs, so cleanup() can only ever run after vfkit has
# already exited (or before it launched) -- there is never a live vfkit for
# cleanup() to deal with, hence no reap code exists.
#
# VM_EXIT_STATUS is initialized to 1 (abnormal) so any interrupted path
# decides RETAIN; the assignment below overwrites it with vfkit's real status
# on every path that reaches it. `set -e` is relaxed so a nonzero vfkit
# status is recorded rather than aborting before the assignment.
VM_EXIT_STATUS=1
set +e
vfkit \
  --cpus "$VM_CPUS" --memory "$VM_MEM" \
  --bootloader "efi,variable-store=$EFISTORE,create" \
  --device "virtio-blk,path=$GUEST_IMAGE_CLONE" \
  --device "virtio-fs,sharedDir=$MOUNT_SHARED_DIR,mountTag=repo" \
  --device "virtio-fs,sharedDir=$CONFIG_DIR,mountTag=runconfig" \
  --device "virtio-fs,sharedDir=$CLAUDE_BIN_DIR,mountTag=claudebin" \
  --device "virtio-fs,sharedDir=$CREDS_DIR,mountTag=claudecreds" \
  ${EXTRA_MOUNT_FLAGS[@]+"${EXTRA_MOUNT_FLAGS[@]}"} \
  --device "virtio-net,unixSocketPath=$GVPROXY_SOCK" \
  --device "virtio-serial,logFilePath=$GUEST_CONSOLE_LOG" \
  --device "virtio-serial,stdio" \
  --device "virtio-rng"
VM_EXIT_STATUS=$?
set -e
exit "$VM_EXIT_STATUS"
