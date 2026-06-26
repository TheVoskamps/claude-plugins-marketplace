#!/usr/bin/env bash
#
# claude-cache.sh -- host-side, GPG-verified `claude` binary cache.
#
# Sourced by claude-vm.sh. This is the TRUSTED install path for the
# guest's `claude` binary (issue #49 / slice 4 of issue #39): instead of
# the guest running `curl https://claude.ai/install.sh | bash` on every
# boot (unsigned, unchecksummed, re-fetched each time), the HOST resolves
# the requested channel to a concrete version, downloads that version's
# GPG-signed manifest, verifies the signature against a pinned key,
# checksum-verifies the downloaded binary against the signature-verified
# manifest, and caches the verified binary keyed on the resolved version.
# The launcher then mounts the cached binary RO into the guest.
#
# Root of trust (resolved in issue #39): the GPG-signed
# `manifest.json.sig`. Trusting install.sh's own built-in checksum is
# circular -- the script is itself unsigned and could omit its checks or
# repoint its download base. The one signed artifact in the chain is the
# manifest signature, so THAT is the root of trust. The operator imports
# and out-of-band-verifies the signing key once (trust-on-first-use);
# this library only ever VERIFIES against an already-imported key and
# ABORTS (never falls back to unverified code) on any failure.
#
# SECURITY INVARIANT: a failed `gpg --verify` OR a checksum mismatch MUST
# abort before any unverified binary is cached or mounted. Every verify
# step below returns non-zero on failure and every caller treats that as
# fatal. There is no "verify failed, proceed anyway" branch.
#
# The functions are split so the OFFLINE logic (channel/version
# validation, cache-path derivation, checksum comparison, manifest
# parsing) is unit-testable with no network and no gpg, exactly as
# config.sh's layering is testable without a VM. The network/gpg steps
# (claude_cache_fetch_url, claude_cache_gpg_verify) are thin wrappers the
# offline tests stub or skip.

set -uo pipefail

# Default cache + key locations. Overridable via env for testing.
: "${CLAUDE_VM_CACHE_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/cache}"

# The guest is an arm64 Linux micro-VM (Apple Silicon host, debian guest),
# so the manifest platform key and artifact path are linux-arm64.
CLAUDE_VM_GUEST_PLATFORM="linux-arm64"

# Download endpoints (issue #39, "Resolved build-time decisions"). The
# channel pointer returns a bare concrete-version string; per-version
# artifacts live under the releases base keyed on that version.
CLAUDE_VM_RELEASES_BASE="https://downloads.claude.ai/claude-code-releases"
CLAUDE_VM_SIGNING_KEY_URL="https://downloads.claude.ai/keys/claude-code.asc"

# Default channel when `claude.version` is unset in both config layers.
# `stable` is the conservative channel (latest binary tracking stable).
CLAUDE_VM_DEFAULT_CLAUDE_VERSION="stable"

# A concrete pinned version is a dotted numeric like 2.1.172. The two
# symbolic channels resolve to such a version host-side.
claude_cache_is_pinned_version() {
  printf '%s\n' "$1" | grep -qE '^[0-9]+(\.[0-9]+)*$'
}

# Validate a `claude.version` scalar: `stable` | `latest` | a concrete
# pinned version. Prints the normalized value and returns 0 when valid;
# prints an error to stderr and returns 1 otherwise. Keeping this as a
# guard means a typo in config (`stabel`) fails fast with a clear message
# rather than being sent to the release endpoint as a bogus channel.
claude_cache_validate_version() {
  local v="$1"
  case "$v" in
    stable|latest)
      printf '%s\n' "$v"
      return 0
      ;;
    *)
      if claude_cache_is_pinned_version "$v"; then
        printf '%s\n' "$v"
        return 0
      fi
      echo "claude-cache: invalid claude.version '$v' (expected 'stable', 'latest', or a pinned version like 2.1.172)." >&2
      return 1
      ;;
  esac
}

# Fetch a URL to stdout through the host's network. A thin curl wrapper so
# the offline tests can stub it. --fail makes an HTTP error (404 on a
# bogus channel/version) a non-zero exit rather than a 200-with-error-body
# we'd mistake for content. Returns curl's exit status.
claude_cache_fetch_url() {
  local url="$1"
  curl -fsSL --max-time 60 "$url"
}

# Resolve a channel (stable|latest) to a concrete version string by
# fetching its pointer. A pinned version resolves to itself with no
# network call. Prints the concrete version on stdout; returns non-zero
# (and prints nothing usable) when the pointer fetch fails or returns
# something that is not a version string.
claude_cache_resolve_version() {
  local channel="$1" resolved
  if claude_cache_is_pinned_version "$channel"; then
    printf '%s\n' "$channel"
    return 0
  fi
  # stable|latest: fetch the channel pointer (a bare version string).
  resolved="$(claude_cache_fetch_url "$CLAUDE_VM_RELEASES_BASE/$channel" 2>/dev/null \
    | tr -d '[:space:]')" || {
    echo "claude-cache: could not fetch the '$channel' channel pointer from $CLAUDE_VM_RELEASES_BASE/$channel." >&2
    return 1
  }
  if ! claude_cache_is_pinned_version "$resolved"; then
    echo "claude-cache: '$channel' channel pointer did not return a version string (got: '${resolved:0:80}')." >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

# Cache path for a resolved version's verified binary. Keyed on the
# concrete version so two channels resolving to the same version share one
# cache entry and a warm boot finds it deterministically.
claude_cache_binary_path() {
  local version="$1"
  printf '%s/%s/%s/claude\n' "$CLAUDE_VM_CACHE_DIR" "$version" "$CLAUDE_VM_GUEST_PLATFORM"
}

# Is a verified binary already cached for this version? (Warm-boot check.)
# Returns 0 when the cached binary exists and is non-empty.
claude_cache_is_cached() {
  local version="$1" path
  path="$(claude_cache_binary_path "$version")"
  [ -s "$path" ]
}

# Extract the platform SHA256 from a manifest.json on stdin. The manifest
# shape (issue #39) maps platform -> {checksum/sha256, ...}; we read the
# guest platform's hex digest. Prefers jq when present (robust), falling
# back to a constrained grep/sed for hosts without jq. Prints the lowercase
# hex digest; returns non-zero when no digest is found.
claude_cache_manifest_sha256() {
  local manifest_file="$1" platform="$CLAUDE_VM_GUEST_PLATFORM" digest=""
  if command -v jq >/dev/null 2>&1; then
    # Try the common manifest shapes: .platforms.<p>.checksum,
    # .platforms.<p>.sha256, .<p>.checksum, .<p>.sha256. The first
    # non-null wins.
    digest="$(jq -r --arg p "$platform" '
      (.platforms[$p].checksum // .platforms[$p].sha256
        // .[$p].checksum // .[$p].sha256 // empty)
    ' "$manifest_file" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  fi
  if [ -z "$digest" ]; then
    # jq-free fallback: find the platform key, then the first 64-hex token
    # after it. Constrained to a 64-char hex run so it cannot match a
    # version or URL. This is best-effort for hosts without jq; jq is the
    # supported path.
    digest="$(grep -A4 "\"$platform\"" "$manifest_file" 2>/dev/null \
      | grep -oiE '[0-9a-f]{64}' | head -n1 | tr '[:upper:]' '[:lower:]')"
  fi
  if ! printf '%s\n' "$digest" | grep -qiE '^[0-9a-f]{64}$'; then
    echo "claude-cache: could not read a sha256 for platform '$platform' from the manifest." >&2
    return 1
  fi
  printf '%s\n' "$digest"
}

# Compute the sha256 of a file as lowercase hex, using whichever tool the
# host has (macOS ships shasum; Linux/CI may have sha256sum). Prints the
# digest; returns non-zero when neither tool is available.
claude_cache_file_sha256() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    echo "claude-cache: neither 'shasum' nor 'sha256sum' is available to verify the binary checksum." >&2
    return 1
  fi
}

# Compare two sha256 hex digests case-insensitively. Returns 0 when they
# match, 1 otherwise. A mismatch is the checksum-verification failure that
# MUST abort the install (the caller treats non-zero as fatal).
claude_cache_checksum_matches() {
  local expected actual
  expected="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  actual="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ]
}

# GPG-verify a detached signature against a file, using the operator's
# pre-imported claude-code signing key. This is the ROOT OF TRUST step.
# Returns gpg's exit status: 0 only when the signature validates against an
# imported, trusted-enough key. A thin wrapper so offline tests can stub
# it; the real verification is gpg's.
#
#   $1 -- signature file (manifest.json.sig)
#   $2 -- signed file     (manifest.json)
claude_cache_gpg_verify() {
  local sig="$1" signed="$2"
  command -v gpg >/dev/null 2>&1 || {
    echo "claude-cache: 'gpg' is required to verify the release manifest signature but was not found on PATH." >&2
    echo "claude-cache: install it ('brew install gnupg') and import the claude-code signing key:" >&2
    echo "claude-cache:   curl -fsSL $CLAUDE_VM_SIGNING_KEY_URL | gpg --import" >&2
    echo "claude-cache: then verify its fingerprint out of band (one-time, trust-on-first-use)." >&2
    return 1
  }
  # --status-fd lets us assert a GOODSIG rather than relying solely on the
  # exit code, but gpg's exit status is already non-zero on a bad/absent
  # signature, which is the fatal condition we need. Keep stderr visible so
  # a verification failure is diagnosable.
  gpg --verify "$sig" "$signed"
}

# The full TRUSTED fetch+verify+cache flow for a resolved version. On
# success the verified binary is at claude_cache_binary_path "$version"
# and the function prints that path on stdout. On ANY verification failure
# it removes partial artifacts and returns non-zero WITHOUT caching or
# printing a usable path -- there is no unverified-fallback branch here.
#
#   $1 -- resolved concrete version (e.g. 2.1.172)
#
# Steps (issue #39):
#   1. download manifest.json + manifest.json.sig
#   2. gpg --verify the signature against the pinned key  -> ABORT on fail
#   3. read the platform sha256 from the verified manifest
#   4. download the binary; verify its sha256             -> ABORT on fail
#   5. atomically install into the version-keyed cache
claude_cache_fetch_verified() {
  local version="$1"
  local base="$CLAUDE_VM_RELEASES_BASE/$version"
  local manifest_url="$base/manifest.json"
  local sig_url="$base/manifest.json.sig"
  local binary_url="$base/$CLAUDE_VM_GUEST_PLATFORM/claude"

  local dest dest_dir
  dest="$(claude_cache_binary_path "$version")"
  dest_dir="$(dirname "$dest")"

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-cache.XXXXXX")" || {
    echo "claude-cache: could not create a temp work dir for the verified fetch." >&2
    return 1
  }
  # Clean the scratch on every return path; the cache install is atomic via
  # a rename out of this dir's sibling, so a failure leaves no half-binary
  # in the cache.
  local rc=0
  _cache_cleanup() { rm -rf "$work"; }

  # Step 1: download manifest + signature.
  if ! claude_cache_fetch_url "$manifest_url" > "$work/manifest.json" 2>/dev/null; then
    echo "claude-cache: failed to download the manifest for version $version ($manifest_url)." >&2
    _cache_cleanup; return 1
  fi
  if ! claude_cache_fetch_url "$sig_url" > "$work/manifest.json.sig" 2>/dev/null; then
    echo "claude-cache: failed to download the manifest signature for version $version ($sig_url)." >&2
    _cache_cleanup; return 1
  fi

  # Step 2: ROOT OF TRUST -- gpg --verify. A failure here ABORTS; we never
  # proceed to use an unverified manifest.
  if ! claude_cache_gpg_verify "$work/manifest.json.sig" "$work/manifest.json"; then
    echo "claude-cache: GPG verification of the manifest FAILED for version $version -- aborting." >&2
    echo "claude-cache: refusing to install an unverified claude binary. Ensure the claude-code" >&2
    echo "claude-cache: signing key is imported and trusted (see $CLAUDE_VM_SIGNING_KEY_URL)." >&2
    _cache_cleanup; return 1
  fi

  # Step 3: read the platform sha256 from the signature-verified manifest.
  local want_sha
  if ! want_sha="$(claude_cache_manifest_sha256 "$work/manifest.json")"; then
    echo "claude-cache: could not extract the $CLAUDE_VM_GUEST_PLATFORM checksum from the verified manifest -- aborting." >&2
    _cache_cleanup; return 1
  fi

  # Step 4: download the binary and verify its checksum against the
  # verified manifest. A mismatch ABORTS.
  if ! claude_cache_fetch_url "$binary_url" > "$work/claude" 2>/dev/null; then
    echo "claude-cache: failed to download the claude binary for version $version ($binary_url)." >&2
    _cache_cleanup; return 1
  fi
  local have_sha
  if ! have_sha="$(claude_cache_file_sha256 "$work/claude")"; then
    _cache_cleanup; return 1
  fi
  if ! claude_cache_checksum_matches "$want_sha" "$have_sha"; then
    echo "claude-cache: checksum MISMATCH for the claude binary version $version -- aborting." >&2
    echo "claude-cache:   expected (verified manifest): $want_sha" >&2
    echo "claude-cache:   actual   (downloaded binary): $have_sha" >&2
    echo "claude-cache: refusing to cache or run a binary that does not match the signed manifest." >&2
    _cache_cleanup; return 1
  fi

  # Step 5: install into the version-keyed cache. Make the binary
  # executable and move it into place atomically (write to a temp sibling
  # in the dest dir, then rename) so a concurrent warm-boot check never
  # sees a half-written file.
  chmod 0755 "$work/claude"
  mkdir -p "$dest_dir"
  local tmp_dest="$dest_dir/.claude.tmp.$$"
  if ! cp "$work/claude" "$tmp_dest" || ! mv -f "$tmp_dest" "$dest"; then
    echo "claude-cache: failed to install the verified binary into the cache at $dest." >&2
    rm -f "$tmp_dest"
    _cache_cleanup; return 1
  fi

  _cache_cleanup
  printf '%s\n' "$dest"
  return "$rc"
}

# Top-level: ensure a verified, cached binary exists for the requested
# `claude.version` scalar, and print its host path on stdout. This is the
# single entry point claude-vm.sh calls.
#
#   $1 -- the `claude.version` scalar (stable|latest|pinned)
#
# Warm boot: when the resolved version is already cached, returns the
# cached path with NO network fetch and NO gpg call (the verification
# happened when it was first cached). Cold boot: resolves, fetches, and
# verifies. On any failure returns non-zero without printing a usable path.
#
# Also prints, on fd 3 if open (else stderr), whether the network was
# touched, so the launcher can decide to drop claude.ai/downloads.claude.ai
# from the allowlist on a warm boot.
claude_cache_ensure() {
  local requested="$1" version path
  if ! version="$(claude_cache_validate_version "$requested")"; then
    return 1
  fi

  # Warm-boot fast path: a PINNED version that is already cached needs no
  # network at all. For a channel (stable|latest) we must still resolve to
  # learn the concrete version, which is a network call -- but once
  # resolved, if that version is cached we skip the (larger) binary
  # download + verify.
  if claude_cache_is_pinned_version "$version" && claude_cache_is_cached "$version"; then
    claude_cache_note_network "warm"
    claude_cache_binary_path "$version"
    return 0
  fi

  if ! version="$(claude_cache_resolve_version "$version")"; then
    return 1
  fi

  if claude_cache_is_cached "$version"; then
    # Resolved-then-cached: the binary is already verified+cached; no
    # binary download. (We did make ONE small network call to resolve the
    # channel pointer; the launcher still treats this as "warm" for the
    # allowlist decision since the heavy fetch is skipped, but the channel
    # pointer call means downloads.claude.ai was reached. The launcher
    # keys its allowlist decision off claude_cache_note_network.)
    claude_cache_note_network "channel-resolve"
    claude_cache_binary_path "$version"
    return 0
  fi

  claude_cache_note_network "cold"
  if ! path="$(claude_cache_fetch_verified "$version")"; then
    return 1
  fi
  printf '%s\n' "$path"
}

# Record whether the ensure path touched the network. Values:
#   warm            -- pinned version, fully cached: NO network at all.
#   channel-resolve -- channel resolved but binary cached: one small
#                      pointer fetch, no binary download.
#   cold            -- binary downloaded + verified this run.
#
# claude_cache_ensure runs inside a command substitution in the launcher
# ($(claude_cache_ensure ...)), so an exported variable set here would NOT
# propagate to the parent shell. We therefore ALSO write the state to a
# small state file the caller can read after the substitution returns. The
# file path defaults to <cache-dir>/.last-network-state and is overridable
# via CLAUDE_VM_CACHE_STATE_FILE (the launcher points it at its per-run dir
# so concurrent launches do not race on one shared file). The exported var
# is kept too -- it is still useful in non-subshell callers and in tests
# that source-and-call directly.
claude_cache_note_network() {
  CLAUDE_VM_CACHE_NETWORK="$1"
  export CLAUDE_VM_CACHE_NETWORK
  local state_file="${CLAUDE_VM_CACHE_STATE_FILE:-$CLAUDE_VM_CACHE_DIR/.last-network-state}"
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
  printf '%s\n' "$1" > "$state_file" 2>/dev/null || true
}
