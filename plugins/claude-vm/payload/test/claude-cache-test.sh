#!/usr/bin/env bash
#
# claude-cache-test.sh -- unit tests for the host-side verified claude cache.
#
# Exercises payload/lib/claude-cache.sh's OFFLINE logic with no real
# network and no real download from claude.ai: the network/gpg primitives
# (claude_cache_fetch_url, claude_cache_gpg_verify) are STUBBED so the
# resolve -> verify -> checksum -> cache pipeline runs end-to-end against
# local fixtures. This mirrors config-test.sh: pure, deterministic, no VM.
#
# The security-critical assertions are the ABORT paths: a failed
# gpg --verify and a checksum mismatch must each cause the ensure/fetch
# flow to return non-zero WITHOUT caching a binary -- there is no
# "verify failed, proceed anyway" branch. We assert both the non-zero
# return AND that nothing landed in the cache.
#
# Run directly:
#   plugins/claude-vm/payload/test/claude-cache-test.sh
#
# Requires only bash + a sha256 tool (shasum or sha256sum), both present on
# stock macOS and Linux. Skips cleanly if no sha256 tool is available.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../lib/claude-cache.sh"

# Point the cache at a throwaway dir BEFORE sourcing, so the lib's default
# never touches the real ~/.config/claude-vm/cache.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-cache-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_VM_CACHE_DIR="$WORK/cache"

# shellcheck source=../lib/claude-cache.sh
. "$LIB"

if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  echo "SKIP: no sha256 tool (shasum/sha256sum) available; claude-cache tests skipped." >&2
  exit 0
fi

PASS=0
FAIL=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); echo "ok   - $label"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $label"
    echo "        expected: [$expected]"; echo "        actual:   [$actual]"
  fi
}
assert_rc() {
  local label="$1" want="$2" got="$3"
  assert_eq "$label" "$want" "$got"
}

# ---------------------------------------------------------------------
# Fixtures: a fake release. The "binary" is arbitrary bytes; the manifest
# carries the binary's real sha256 so the checksum step passes on the happy
# path and can be corrupted to exercise the mismatch-abort path.
# ---------------------------------------------------------------------
FIXTURE="$WORK/fixture"
mkdir -p "$FIXTURE"
printf 'fake-claude-binary-bytes-v1\n' > "$FIXTURE/claude"
BIN_SHA="$(claude_cache_file_sha256 "$FIXTURE/claude")"
cat > "$FIXTURE/manifest.good.json" <<JSON
{ "version": "9.9.9",
  "platforms": { "linux-arm64": { "checksum": "$BIN_SHA" } } }
JSON
# A manifest whose checksum does NOT match the binary (mismatch fixture).
cat > "$FIXTURE/manifest.badsum.json" <<JSON
{ "version": "9.9.9",
  "platforms": { "linux-arm64": { "checksum": "0000000000000000000000000000000000000000000000000000000000000000" } } }
JSON

# Channel pointer the stub returns for stable/latest.
RESOLVED_VERSION="9.9.9"

# ---------------------------------------------------------------------
# Stubs. claude_cache_fetch_url is redefined to serve fixtures by URL
# suffix; claude_cache_gpg_verify is redefined to honor a toggle so we can
# simulate both a good signature and a tampered one without real gpg/keys.
# ---------------------------------------------------------------------
GPG_VERIFY_RESULT=0      # 0 = signature valid; non-zero = tampered/invalid
MANIFEST_TO_SERVE="$FIXTURE/manifest.good.json"

claude_cache_fetch_url() {
  local url="$1"
  case "$url" in
    */claude-code-releases/stable|*/claude-code-releases/latest)
      printf '%s\n' "$RESOLVED_VERSION" ;;
    */manifest.json)      cat "$MANIFEST_TO_SERVE" ;;
    */manifest.json.sig)  printf 'FAKE-SIGNATURE\n' ;;
    */linux-arm64/claude) cat "$FIXTURE/claude" ;;
    *) echo "stub: unexpected URL: $url" >&2; return 1 ;;
  esac
}
claude_cache_gpg_verify() { return "$GPG_VERIFY_RESULT"; }

# ---------------------------------------------------------------------
# 1. Version validation
# ---------------------------------------------------------------------
assert_eq "validate: stable accepted" "stable" "$(claude_cache_validate_version stable)"
assert_eq "validate: latest accepted" "latest" "$(claude_cache_validate_version latest)"
assert_eq "validate: pinned accepted" "2.1.172" "$(claude_cache_validate_version 2.1.172)"
claude_cache_validate_version "stabel" >/dev/null 2>&1
assert_rc "validate: typo rejected (non-zero)" "1" "$?"

# ---------------------------------------------------------------------
# 2. Cache-path derivation keyed on resolved version
# ---------------------------------------------------------------------
assert_eq "cache path keyed on version + platform" \
  "$WORK/cache/9.9.9/linux-arm64/claude" "$(claude_cache_binary_path 9.9.9)"

# ---------------------------------------------------------------------
# 3. Manifest sha256 extraction + checksum comparison
# ---------------------------------------------------------------------
assert_eq "manifest sha256 extracted" "$BIN_SHA" \
  "$(claude_cache_manifest_sha256 "$FIXTURE/manifest.good.json")"
claude_cache_checksum_matches "$BIN_SHA" "$BIN_SHA"
assert_rc "checksum match -> rc 0" "0" "$?"
claude_cache_checksum_matches "$BIN_SHA" "deadbeef"
assert_rc "checksum mismatch -> rc 1" "1" "$?"

# ---------------------------------------------------------------------
# 3b. Hardened jq-free manifest parse. The fallback parser must scope to
#     the target platform's object and take the checksum-keyed hex -- not a
#     fixed N-line window that a layout change could make grab the wrong
#     token. We force the fallback by hiding jq behind a minimal PATH, and
#     feed adversarial layouts: a hex-bearing `url` field BEFORE the
#     checksum, and a DIFFERENT platform's digest preceding ours.
# ---------------------------------------------------------------------
# Build a PATH that has the parse tools (awk/grep/tr/head/sed/cat) but NOT
# jq, so claude_cache_manifest_sha256 exercises its jq-free branch.
NOJQ_BIN="$WORK/nojq-bin"; mkdir -p "$NOJQ_BIN"
for _t in awk grep tr head sed cat shasum sha256sum; do
  _src="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_src" "$NOJQ_BIN/$_t" 2>/dev/null
done
parse_nojq() { PATH="$NOJQ_BIN" claude_cache_manifest_sha256 "$1" 2>/dev/null; }

# Adversarial layout A: a url carrying its own 64-hex run BEFORE the checksum.
cat > "$FIXTURE/manifest.urlhex.json" <<JSON
{ "version": "9.9.9",
  "platforms": {
    "linux-arm64": {
      "url": "https://x/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/claude",
      "size": 12345,
      "checksum": "$BIN_SHA"
    } } }
JSON
assert_eq "fallback parse ignores a hex-bearing url before checksum" \
  "$BIN_SHA" "$(parse_nojq "$FIXTURE/manifest.urlhex.json")"

# Adversarial layout B: another platform's digest precedes ours.
cat > "$FIXTURE/manifest.multiplat.json" <<JSON
{ "platforms": {
    "darwin-arm64": { "checksum": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
    "linux-arm64":  { "checksum": "$BIN_SHA" }
  } }
JSON
assert_eq "fallback parse picks OUR platform, not a preceding one" \
  "$BIN_SHA" "$(parse_nojq "$FIXTURE/manifest.multiplat.json")"

# ---------------------------------------------------------------------
# 3c. Fingerprint normalization: spaced + lowercased vs compact + upper
#     must compare equal (operators paste the gpg --fingerprint form).
# ---------------------------------------------------------------------
assert_eq "normalize_fpr strips spaces + uppercases" \
  "C8D7E3123F312A2DC66F4F009C01EB1720C49782" \
  "$(claude_cache_normalize_fpr 'c8d7 e312 3f31 2a2d c66f 4f00 9c01 eb17 20c4 9782')"

# ---------------------------------------------------------------------
# 3d. REAL claude_cache_gpg_verify: pin-binding behavior.
#     The pipeline tests below stub claude_cache_gpg_verify wholesale, so
#     they never exercise its internal pin logic. Here we exercise the REAL
#     function against a stubbed `gpg` that emits a VALIDSIG status line, to
#     assert the security-critical rule: an UNSET pin HARD-ABORTS (a valid
#     signature by an unpinned key is NOT accepted), while a MATCHING pin
#     returns 0. We stub only `gpg` (a fake on PATH), not the function.
# ---------------------------------------------------------------------
# A fake `gpg` whose --verify run emits a VALIDSIG status line carrying a
# known fingerprint as BOTH the signing-key (field 1) and primary-key (last)
# token. command -v gpg must succeed, so the fake also answers --version.
GPG_BIN="$WORK/gpg-bin"; mkdir -p "$GPG_BIN"
FAKE_FPR="C8D7E3123F312A2DC66F4F009C01EB1720C49782"
cat > "$GPG_BIN/gpg" <<GPGSTUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    --version) echo "gpg (fake) 0.0"; exit 0 ;;
  esac
done
# --status-fd 1 --verify <sig> <signed>: emit a VALIDSIG with FAKE_FPR as
# the first AND last fingerprint token (sig-fpr == primary-fpr).
echo "[GNUPG:] VALIDSIG $FAKE_FPR 2026-01-01 0 0 4 0 1 8 00 $FAKE_FPR"
exit 0
GPGSTUB
chmod +x "$GPG_BIN/gpg"

# The top of this file replaced claude_cache_gpg_verify with a stub, so we
# cannot call the REAL function in this shell. Instead each check runs in a
# subshell that re-sources the lib fresh (restoring the real function) with
# the fake gpg on PATH and the pin set/unset.
verify_with_pin() {
  # $1 = pin value (may be empty). Runs the REAL gpg_verify with the fake
  # gpg on PATH, against throwaway sig/signed files. Prints nothing; returns
  # the function's rc.
  local pin="$1"
  ( PATH="$GPG_BIN:$PATH"
    CLAUDE_VM_SIGNING_KEY_FINGERPRINT="$pin"
    export CLAUDE_VM_SIGNING_KEY_FINGERPRINT
    . "$LIB"   # fresh lib => REAL claude_cache_gpg_verify, not the stub
    : > "$WORK/sig"; : > "$WORK/signed"
    claude_cache_gpg_verify "$WORK/sig" "$WORK/signed" >/dev/null 2>&1 )
}

verify_with_pin ""
assert_rc "gpg_verify: UNSET pin hard-aborts even with VALIDSIG -> rc 1" "1" "$?"
verify_with_pin "$FAKE_FPR"
assert_rc "gpg_verify: matching pin accepts VALIDSIG -> rc 0" "0" "$?"
verify_with_pin "c8d7 e312 3f31 2a2d c66f 4f00 9c01 eb17 20c4 9782"
assert_rc "gpg_verify: matching pin (spaced/lowercased) accepts -> rc 0" "0" "$?"
verify_with_pin "DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"
assert_rc "gpg_verify: non-matching pin rejects VALIDSIG -> rc 1" "1" "$?"

# ---------------------------------------------------------------------
# 4. HAPPY PATH: cold fetch caches a verified binary
# ---------------------------------------------------------------------
GPG_VERIFY_RESULT=0
MANIFEST_TO_SERVE="$FIXTURE/manifest.good.json"
# Read the network state from the state file: ensure runs in a command
# substitution, so an exported var would not propagate here (this is exactly
# why claude_cache_note_network also writes a state file). This mirrors how
# the launcher reads it.
cache_net() { cat "$WORK/cache/.last-network-state" 2>/dev/null; }
out="$(claude_cache_ensure stable)"; rc=$?
assert_rc "ensure(stable) happy path -> rc 0" "0" "$rc"
assert_eq "ensure prints the cache path" "$WORK/cache/9.9.9/linux-arm64/claude" "$out"
assert_eq "ensure reports cold fetch" "cold" "$(cache_net)"
[ -s "$WORK/cache/9.9.9/linux-arm64/claude" ] && cached=yes || cached=no
assert_eq "verified binary is cached" "yes" "$cached"

# ---------------------------------------------------------------------
# 5. WARM BOOT: a pinned, already-cached version touches NO network.
#    We prove "no network" by making the fetch stub FAIL loudly; if the
#    warm path called it, ensure would error.
# ---------------------------------------------------------------------
claude_cache_fetch_url() { echo "stub: network MUST NOT be called on warm boot ($1)" >&2; return 1; }
out="$(claude_cache_ensure 9.9.9)"; rc=$?
assert_rc "ensure(pinned, cached) warm -> rc 0 with no network" "0" "$rc"
assert_eq "warm boot reports 'warm' (no network)" "warm" "$(cache_net)"
assert_eq "warm boot returns the cached path" "$WORK/cache/9.9.9/linux-arm64/claude" "$out"
# Restore the serving stub for the abort tests below.
claude_cache_fetch_url() {
  local url="$1"
  case "$url" in
    */claude-code-releases/stable|*/claude-code-releases/latest)
      printf '%s\n' "$RESOLVED_VERSION" ;;
    */manifest.json)      cat "$MANIFEST_TO_SERVE" ;;
    */manifest.json.sig)  printf 'FAKE-SIGNATURE\n' ;;
    */linux-arm64/claude) cat "$FIXTURE/claude" ;;
    *) echo "stub: unexpected URL: $url" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------
# 6. ABORT: a failed gpg --verify must NOT cache and must return non-zero.
#    Use a fresh version so a prior cache entry cannot mask the abort.
# ---------------------------------------------------------------------
GPG_VERIFY_RESULT=1
RESOLVED_VERSION="8.8.8"
MANIFEST_TO_SERVE="$FIXTURE/manifest.good.json"
out="$(claude_cache_ensure stable 2>/dev/null)"; rc=$?
assert_rc "ensure aborts on gpg --verify failure -> rc 1" "1" "$rc"
[ -e "$WORK/cache/8.8.8/linux-arm64/claude" ] && leaked=yes || leaked=no
assert_eq "gpg failure caches NOTHING" "no" "$leaked"

# ---------------------------------------------------------------------
# 7. ABORT: a checksum mismatch (good signature, wrong digest) must NOT
#    cache and must return non-zero.
# ---------------------------------------------------------------------
GPG_VERIFY_RESULT=0
RESOLVED_VERSION="7.7.7"
MANIFEST_TO_SERVE="$FIXTURE/manifest.badsum.json"
out="$(claude_cache_ensure stable 2>/dev/null)"; rc=$?
assert_rc "ensure aborts on checksum mismatch -> rc 1" "1" "$rc"
[ -e "$WORK/cache/7.7.7/linux-arm64/claude" ] && leaked=yes || leaked=no
assert_eq "checksum mismatch caches NOTHING" "no" "$leaked"

# ---------------------------------------------------------------------
# 8. ABORT: an UNSET signing-key pin must HARD-ABORT the whole ensure flow
#    and cache NOTHING -- even when the signature is otherwise valid. This
#    is the end-to-end counterpart of section 3d: it drives the FULL
#    resolve->fetch->verify->cache pipeline with the REAL gpg_verify (via
#    the fake gpg from 3d) and an empty pin, proving the launch never
#    proceeds to download/cache a binary under an unpinned key.
# ---------------------------------------------------------------------
ensure_unset_pin_caches_nothing() {
  # Run in a subshell so the real lib (with real gpg_verify) and the empty
  # pin do not leak into the rest of this file's stubbed pipeline.
  ( PATH="$GPG_BIN:$PATH"
    CLAUDE_VM_SIGNING_KEY_FINGERPRINT=""        # unpinned => must hard-abort
    export CLAUDE_VM_SIGNING_KEY_FINGERPRINT CLAUDE_VM_CACHE_DIR
    . "$LIB"   # fresh lib => REAL claude_cache_gpg_verify
    # Re-install the fetch stub inside this subshell (sourcing the lib reset
    # it to the real curl wrapper). Serve a fresh version so no prior cache
    # entry can mask the abort.
    claude_cache_fetch_url() {
      case "$1" in
        */claude-code-releases/stable) printf '%s\n' "6.6.6" ;;
        */manifest.json)      cat "$FIXTURE/manifest.good.json" ;;
        */manifest.json.sig)  printf 'FAKE-SIGNATURE\n' ;;
        */linux-arm64/claude) cat "$FIXTURE/claude" ;;
        *) return 1 ;;
      esac
    }
    claude_cache_ensure stable >/dev/null 2>&1 )
}
ensure_unset_pin_caches_nothing
assert_rc "ensure(unset pin) hard-aborts -> rc 1" "1" "$?"
[ -e "$WORK/cache/6.6.6/linux-arm64/claude" ] && leaked=yes || leaked=no
assert_eq "unset pin caches NOTHING" "no" "$leaked"

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
echo "claude-cache-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
