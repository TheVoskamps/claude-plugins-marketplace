#!/usr/bin/env bash
#
# claude-vm.sh -- launch Claude Code inside an isolated macOS VM.
#
# Config-driven replacement for the original env-var launcher. Every
# non-secret operational knob (cpus, mem, guest_image, proxy, egress
# allowlist, extra mounts, repo mount strategy) comes from layered YAML:
#
#   global:   ~/.config/claude-vm/config.yml   (machine-wide defaults)
#   per-repo: <repo>/.claude-vm/config.yml      (project-specific)
#
# Scalars: repo overrides global. Lists (egress.allow, mounts): union.
# See payload/lib/config.sh for the layering implementation and
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
# OAUTH SETUP-TOKEN (issue #88): current Claude Code does NOT treat that
# mounted ~/.claude/.credentials.json as pre-authenticated -- it runs its
# interactive login flow, which is unusable on the guest's byte-pipe console.
# So the guest ALSO authenticates via CLAUDE_CODE_OAUTH_TOKEN, the documented
# headless-auth path from `claude setup-token`. The launcher reads that token
# from its OWN ENVIRONMENT (it does NOT parse .env/.envrc -- the operator
# populates it via direnv or a plain export), gates on it at a preflight, and
# delivers it to the guest the SAME transient RO shred-on-exit way as the
# keychain credential (via the claudecreds mount, NEVER via run.env). The
# guest boot launcher exports it before exec'ing claude. This token path is
# ADDITIVE and layered alongside the keychain credential mount above; a
# follow-up pass will reconcile the two once the token path is verified.
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

# ---------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------
REPO_SRC="${1:?usage: claude-vm <repo-path> [claude args...]}"
shift
CLAUDE_ARGS=("$@")

# Resolve to an absolute repo root so per-repo config and clone work
# regardless of the caller's cwd.
REPO_SRC="$(cd "$REPO_SRC" && git rev-parse --show-toplevel 2>/dev/null || (cd "$REPO_SRC" && pwd))"

claude_vm_require_yq || exit 1
command -v git >/dev/null 2>&1 || { echo "claude-vm: git is required" >&2; exit 1; }

# ---------------------------------------------------------------------
# Resolve effective config (layer global + per-repo)
# ---------------------------------------------------------------------
GLOBAL_CONFIG="$CLAUDE_VM_GLOBAL_CONFIG"
REPO_CONFIG="${CLAUDE_VM_REPO_CONFIG:-$REPO_SRC/.claude-vm/config.yml}"

# NOTE: the merged-config temp file is removed by cleanup() (the
# consolidated EXIT/INT/TERM trap installed below). A narrow interim trap is
# armed earlier (right after the OAuth credential is written) to cover the
# clone window; it also removes this file, and the consolidated
# `trap cleanup EXIT INT TERM` REPLACES it once the full run state exists. Do
# NOT add yet another `trap ... EXIT` here -- a later trap installation would
# replace whatever was set, leaking this file on every run.
MERGED="$(claude_vm_mktemp claude-vm-merged)"
claude_vm_merge_config "$GLOBAL_CONFIG" "$REPO_CONFIG" > "$MERGED" \
  || { echo "claude-vm: could not resolve effective config" >&2; exit 1; }

VM_CPUS="$(claude_vm_scalar "$MERGED" '.cpus' "$CLAUDE_VM_DEFAULT_CPUS")"
VM_MEM="$(claude_vm_scalar "$MERGED" '.mem' "$CLAUDE_VM_DEFAULT_MEM")"
REPO_MOUNT="$(claude_vm_scalar "$MERGED" '.repo.mount' "$CLAUDE_VM_DEFAULT_REPO_MOUNT")"
COPY_BACK="$(claude_vm_scalar "$MERGED" '.repo.copy_back' "$CLAUDE_VM_DEFAULT_REPO_COPY_BACK")"
PROXY_PORT="$(claude_vm_scalar "$MERGED" '.proxy.port' "$CLAUDE_VM_DEFAULT_PROXY_PORT")"
GVPROXY_HOST_ALIAS="$(claude_vm_scalar "$MERGED" '.proxy.host_alias' "$CLAUDE_VM_DEFAULT_PROXY_HOST_ALIAS")"
# proxy.cmd: when unset in BOTH config layers, default to the bundled
# tinyproxy launcher (the chosen forward proxy). It reads the egress
# allowlist from $CLAUDE_VM_EGRESS_ALLOWLIST and binds $CLAUDE_VM_PROXY_PORT,
# both exported below. An explicit proxy.cmd in config still overrides it.
DEFAULT_PROXY_CMD="$SCRIPT_DIR/proxy/tinyproxy-launch.sh"
PROXY_CMD="$(claude_vm_scalar "$MERGED" '.proxy.cmd' "$DEFAULT_PROXY_CMD")"

# guest_image: a normal scalar; default to the build/cache location
# alongside the global config dir when unset.
DEFAULT_IMAGE_DIR="$(dirname "$GLOBAL_CONFIG")/images"
GUEST_IMAGE="$(claude_vm_scalar "$MERGED" '.guest_image' "$DEFAULT_IMAGE_DIR/guest.raw")"

# claude.version: the channel/pin the host-side verified cache fetches
# (stable|latest|<pinned>). The cache resolves a channel to a concrete
# version HOST-SIDE and keys the cache on that version (see lib/claude-cache.sh).
CLAUDE_VERSION="$(claude_vm_scalar "$MERGED" '.claude.version' "$CLAUDE_VM_DEFAULT_CLAUDE_VERSION")"

# claude.renderer: which renderer the in-guest claude uses on the byte-pipe
# console (issue #88). The vfkit stdio console is a plain bidirectional byte
# pipe, but the guest's alternate-screen (fullscreen) renderer survives it
# (verified on a real host), so this is a preference, not a workaround:
#   classic    -> CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 (no alt-screen)
#   fullscreen -> CLAUDE_CODE_NO_FLICKER=1               (force alt-screen)
#   unset/""   -> pass nothing; claude uses its own default
# Mapped to the matching env var(s) in run.env below. An unrecognized value
# is rejected up front rather than silently ignored.
CLAUDE_RENDERER="$(claude_vm_scalar "$MERGED" '.claude.renderer' "")"
case "$CLAUDE_RENDERER" in
  ""|classic|fullscreen) : ;;
  *)
    echo "claude-vm: unknown claude.renderer '$CLAUDE_RENDERER' (expected classic|fullscreen, or leave unset)" >&2
    exit 1
    ;;
esac

# claude.signing_key_fingerprint: the claude-code signing key fingerprint
# the operator out-of-band-verified at import time. This PINS the GPG
# verification's root of trust to a specific key -- a bare `gpg --verify`
# trusts ANY key in the keyring, so without this the "valid signature"
# check is not bound to "the claude-code key" (issue #49 review). Exported
# so lib/claude-cache.sh's verify step can enforce it. Empty when unset:
# the cache still requires a VALIDSIG but warns the key is not pinned.
CLAUDE_VM_SIGNING_KEY_FINGERPRINT="$(claude_vm_scalar "$MERGED" '.claude.signing_key_fingerprint' "")"
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
    echo "claude-vm: then add to ~/.config/claude-vm/config.yml (or <repo>/.claude-vm/config.yml):" >&2
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
# OAuth setup-token PREFLIGHT (issue #88). The guest authenticates claude
# via CLAUDE_CODE_OAUTH_TOKEN -- the documented headless-auth path from
# `claude setup-token`. Current Claude Code does NOT treat a mounted
# ~/.claude/.credentials.json as pre-authenticated: it runs its normal
# interactive login flow instead, which is unusable on the guest's byte-pipe
# console. The token is the fix.
#
# The launcher reads the token from its OWN ENVIRONMENT -- it does NOT parse
# .env/.envrc. The operator populates it via direnv (an .envrc with
# `dotenv_if_exists` in the repo root) or a plain `export` before launching.
# Gate here, FAST, before any build/boot work: if it is unset or empty, abort
# with an actionable, claude-vm-branded message. Guarded ${...:-} so an unset
# var does not trip `set -u` before this check runs.
# ---------------------------------------------------------------------
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "claude-vm: CLAUDE_CODE_OAUTH_TOKEN is not set (or is empty)." >&2
  echo "claude-vm: the guest authenticates claude with an OAuth setup-token, not an" >&2
  echo "claude-vm: interactive login (the guest console is a byte pipe, unusable for" >&2
  echo "claude-vm: the login flow). Generate one on this host and put it in the env:" >&2
  echo "claude-vm:   claude setup-token        # prints a ~1-year OAuth token" >&2
  echo "claude-vm: then EITHER export it before launching:" >&2
  echo "claude-vm:   export CLAUDE_CODE_OAUTH_TOKEN='<the token>'" >&2
  echo "claude-vm: OR add it to a .env/.envrc in the repo root loaded via direnv, e.g." >&2
  echo "claude-vm: an .envrc containing:  dotenv_if_exists   (with CLAUDE_CODE_OAUTH_TOKEN=... in .env)" >&2
  echo "claude-vm: then retry." >&2
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
# Ensure guest image exists and matches the pinned version. Build on
# demand rather than erroring. The base is version-pinned; claude is
# NOT baked in -- it is fetched at boot through the egress allowlist.
# ---------------------------------------------------------------------
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
# Resolve `claude` via the host-side, GPG-verified cache (issue #49).
#
# The host resolves the requested channel/pin to a concrete version,
# downloads that version's GPG-signed manifest, verifies the signature
# against the operator's pinned key, checksum-verifies the downloaded
# binary against the verified manifest, and caches it keyed on the
# resolved version. The verified binary is then mounted RO into the guest
# (mountTag=claudebin) and exec'd at the boot-launcher seam.
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
# The credential lives in its OWN dir, NOT in CONFIG_DIR: CONFIG_DIR is
# shared into the guest under mountTag=runconfig, and the secret-bearing
# OAuth credential must never travel in the run.env share. Its own dir is
# shared under a separate tag (claudecreds) so only the credential file is
# exposed. The OAuth setup-token (issue #88) is written into this SAME dir
# (oauth-token) for the same reason -- it is a ~1-year secret and must not
# ride in run.env either. Both dirs are created under the tightened umask
# (077) so they are drwx------ from creation -- the secrets are not
# world-traversable.
CREDS_DIR="$RUN/creds"
mkdir -p "$CONFIG_DIR" "$CREDS_DIR"

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
# fire copy-back against a missing worktree. It still removes MERGED so the
# merged-config-cleanup guarantee holds even if a signal fires in this window.
# The full `trap cleanup EXIT INT TERM` REPLACES this interim trap at its
# existing site once the worktree, proxy, and gvproxy state all exist. Guarded
# with ${CREDS_DIR:-}/${RAW_CREDENTIAL:-}/${MERGED:-} so each rm is a no-op
# under `set -u` even if the trap fires before they are set. RAW_CREDENTIAL is
# included so a signal during the selection window does not leak the FULL blob.
trap 'rm -rf "${CREDS_DIR:-}"; rm -f "${RAW_CREDENTIAL:-}" "${MERGED:-}"' EXIT INT TERM
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
# OAuth setup-token -> the SAME shred-on-exit claudecreds mount (issue #88).
#
# The token (from `claude setup-token`, gated at the preflight above) is a
# ~1-year secret. This script has a DELIBERATE invariant that such secrets
# must NEVER travel in the run.env share (see the run.env comment below) --
# so the token is delivered EXACTLY like the keychain credential: written into
# $CREDS_DIR, the transient owner-only dir shared RO into the guest under
# mountTag=claudecreds and shredded by cleanup() on every exit (EXIT/INT/TERM).
# We are still inside the umask-077 window here, so the file is created
# -rw------- with no world-readable moment; the chmod 600 is belt-and-braces.
# The guest boot launcher reads it from the claudecreds mount and EXPORTs
# CLAUDE_CODE_OAUTH_TOKEN before exec'ing claude (see build-guest-image.sh).
HOST_OAUTH_TOKEN_FILE="$CREDS_DIR/oauth-token"
printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" > "$HOST_OAUTH_TOKEN_FILE"
chmod 600 "$HOST_OAUTH_TOKEN_FILE"

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
{
  printf 'run_id=%s\n' "$RUN_ID"
  printf 'repo_src=%s\n' "$REPO_SRC"
  printf 'repo_mount=%s\n' "$REPO_MOUNT"
  printf 'worktree=%s\n' "$MOUNT_SHARED_DIR"
  printf 'copy_back=%s\n' "$COPY_BACK"
} > "$RUN/run.meta"

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
# values BEFORE exec'ing claude (env alone is insufficient -- programs that
# query the tty via TIOCGWINSZ need the kernel tty geometry set). This is
# one-time: the transport carries no live resize, so this seeds the initial
# size only. `stty size` prints "<rows> <cols>" on the controlling tty; it
# fails when stdin is not a tty (e.g. invoked from a pipe/tool), so guard it
# and leave COLUMNS/LINES empty when unavailable -- the guest then keeps its
# 80x24 default rather than getting a bogus size.
HOST_COLUMNS=""
HOST_LINES=""
if [ -t 0 ]; then
  if _stty_size="$(stty size 2>/dev/null)"; then
    HOST_LINES="${_stty_size%% *}"
    HOST_COLUMNS="${_stty_size##* }"
  fi
fi

RUN_ENV="$CONFIG_DIR/run.env"
(
  umask 077
  {
    printf 'HTTPS_PROXY=http://%s:%s\n' "$GVPROXY_HOST_ALIAS" "$PROXY_PORT"
    printf 'HTTP_PROXY=http://%s:%s\n' "$GVPROXY_HOST_ALIAS" "$PROXY_PORT"
    printf 'NO_PROXY=localhost,127.0.0.1\n'
    printf 'REPO_TAG=repo\n'
    printf 'POLICY_TAG=policy\n'
    # The host-verified claude binary is shared into the guest under this
    # virtio-fs tag (mounted RO at /mnt/claudebin by the guest fstab); the
    # boot launcher execs /mnt/claudebin/claude against /mnt/repo.
    printf 'CLAUDEBIN_TAG=claudebin\n'
    # The host's claude.ai OAuth credential's containing dir is shared
    # under this virtio-fs tag (mounted RO at /mnt/claudecreds by the guest
    # fstab); the boot launcher copies it into $HOME/.claude/.credentials.json
    # (mode 0600) so claude authenticates as the host operator.
    printf 'CLAUDECREDS_TAG=claudecreds\n'
    # Host terminal geometry (issue #88). Empty when not launched from a real
    # terminal; the boot launcher only runs `stty` when both are non-empty.
    printf 'CLAUDE_VM_COLUMNS=%s\n' "$HOST_COLUMNS"
    printf 'CLAUDE_VM_LINES=%s\n' "$HOST_LINES"
    # Renderer selection (issue #88) mapped from claude.renderer. The boot
    # launcher exports the matching CLAUDE_CODE_* var when this is set; an
    # empty value leaves claude on its own default.
    case "$CLAUDE_RENDERER" in
      classic)    printf 'CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1\n' ;;
      fullscreen) printf 'CLAUDE_CODE_NO_FLICKER=1\n' ;;
    esac
    printf 'CLAUDE_ARGS=%s\n' "${CLAUDE_ARGS[*]}"
  } > "$RUN_ENV"
)
chmod 600 "$RUN_ENV"

# ---------------------------------------------------------------------
# Egress allowlist -- write it where the proxy reads it. The proxy.cmd
# is expected to consume CLAUDE_VM_EGRESS_ALLOWLIST (a newline-delimited
# host file) instead of a hand-maintained allowlist baked into the cmd.
# ---------------------------------------------------------------------
EGRESS_ALLOWLIST="$CONFIG_DIR/egress.allow"
claude_vm_egress_hosts "$MERGED" > "$EGRESS_ALLOWLIST"

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
  echo "claude-vm: set egress.allow in ~/.config/claude-vm/config.yml or <repo>/.claude-vm/config.yml to confine egress." >&2
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
while IFS=$'\t' read -r src tag mode; do
  [ -z "$src" ] && continue
  # Expand a leading ~ to $HOME (config is YAML, not shell).
  case "$src" in
    "~"/*) src="$HOME/${src#"~/"}" ;;
    "~") src="$HOME" ;;
  esac
  # mode is advisory for virtio-fs share dirs; recorded for the guest
  # mount step. vfkit shares the dir; the guest mounts ro/rw per mode.
  EXTRA_MOUNT_FLAGS+=(--device "virtio-fs,sharedDir=$src,mountTag=$tag")
done < <(claude_vm_mount_specs "$MERGED")

# ---------------------------------------------------------------------
# Launch: proxy -> gvproxy -> vfkit. Copy-back on exit (clone mode).
# ---------------------------------------------------------------------
PROXY_PID=""
GV_PID=""

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
copy_back_rsync() {
  rsync -a --exclude '.git' "$WORKTREE"/ "$REPO_SRC"/ \
    || { echo "claude-vm: copy-back failed (rsync); worktree retained at $WORKTREE" >&2; return 1; }
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
      if src_tree_is_dirty; then
        echo "claude-vm: WARNING -- local source ($REPO_SRC) has uncommitted changes." >&2
        echo "claude-vm: copy-back would overwrite overlapping files. Preview of what it would change:" >&2
        # Show a preview of files copy-back would change, without writing
        # anything. --itemize-changes lists per-file actions; errors are
        # surfaced (no 2>/dev/null). A preview failure is not fatal -- we
        # still fall through to the confirmation prompt.
        rsync -a --dry-run --itemize-changes --exclude '.git' \
          "$WORKTREE"/ "$REPO_SRC"/ >&2 \
          || echo "claude-vm: (could not compute copy-back preview)" >&2
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
        # stays empty -- which routes to SKIP.
        local reply=""
        if [ -t 0 ] || { [ -e /dev/tty ] && [ -r /dev/tty ]; }; then
          printf 'claude-vm: apply copy-back over the dirty source tree? [y/N] ' >&2
          if { read -r reply < /dev/tty; } 2>/dev/null; then :; else reply=""; fi
        fi
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
  [ -n "$GV_PID" ] && kill "$GV_PID" 2>/dev/null || true
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
  copy_back
  # Remove the merged-config temp file. Guarded for the case where the
  # trap fires before MERGED is set (it is unset/empty then). Written as
  # an `if` rather than `[ -n ... ] && rm` so a false guard does not make
  # the function return non-zero and trip `set -e` before the echoes below.
  if [ -n "${MERGED:-}" ]; then
    rm -f "$MERGED"
  fi
  # The host claude.ai OAuth credential AND the OAuth setup-token (issue #88)
  # are transient secrets sharing this dir: remove it on every exit (including
  # Ctrl-C) so neither lingers after the run. The run dir itself is retained
  # for the companion diff/apply skills, but these secrets must NOT be -- they
  # are never persisted past the live VM. Guarded like MERGED above so an early
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

"$GVPROXY_BIN" --listen-vfkit "unixgram://$GVPROXY_SOCK" --pcap "$PCAP" \
  >"$GVPROXY_LOG" 2>&1 &
GV_PID=$!

for _ in $(seq 1 50); do
  [ -S "$GVPROXY_SOCK" ] && break
  sleep 0.1
done
[ -S "$GVPROXY_SOCK" ] || { echo "claude-vm: gvproxy socket never appeared" >&2; exit 1; }

# The verified claude binary is shared into the guest by its CONTAINING
# DIRECTORY (virtio-fs shares a dir, not a single file) under tag
# 'claudebin', mounted RO at /mnt/claudebin in the guest. The guest boot
# launcher execs /mnt/claudebin/claude against /mnt/repo.
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
# vfkit runs as a CHILD here (NOT exec'd), so cleanup() (trapped on
# EXIT/INT/TERM) runs the VM-stop + copy-back + socket-dir removal when the
# session exits or is Ctrl-C'd. Do NOT switch this to `exec vfkit` -- that
# would replace the shell and the trap would never fire.
vfkit \
  --cpus "$VM_CPUS" --memory "$VM_MEM" \
  --bootloader "efi,variable-store=$EFISTORE,create" \
  --device "virtio-blk,path=$GUEST_IMAGE" \
  --device "virtio-fs,sharedDir=$MOUNT_SHARED_DIR,mountTag=repo" \
  --device "virtio-fs,sharedDir=$CONFIG_DIR,mountTag=runconfig" \
  --device "virtio-fs,sharedDir=$CLAUDE_BIN_DIR,mountTag=claudebin" \
  --device "virtio-fs,sharedDir=$CREDS_DIR,mountTag=claudecreds" \
  ${EXTRA_MOUNT_FLAGS[@]+"${EXTRA_MOUNT_FLAGS[@]}"} \
  --device "virtio-net,unixSocketPath=$GVPROXY_SOCK" \
  --device "virtio-serial,logFilePath=$GUEST_CONSOLE_LOG" \
  --device "virtio-serial,stdio" \
  --device "virtio-rng"
