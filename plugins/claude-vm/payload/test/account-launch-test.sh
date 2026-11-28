#!/usr/bin/env bash
#
# account-launch-test.sh -- the launcher's `--as <name>` sources and refusals.
#
# Runs the REAL payload/claude-vm.sh against a fake $HOME, with `security`,
# `gpg` and `podman` stubbed on a PATH that carries no `vfkit`. A launch whose
# account checks all pass therefore stops at the dependency preflight, which
# is the last gate before the guest-image build -- so every case ends before
# any build or boot, and the cases read off which Keychain service was asked
# for, which .claude.json was accepted, and what each refusal printed.
# Reaching the preflight's message is the marker for "past every account
# check", and its absence shows a refusal came before the build.
#
# The default account has no ~/.claude.json in the passing `--as` case, so
# getting past the identity preflight proves the account's file was the one
# read, and the `security` stub's log shows the account's derived service was
# the only one asked for. Each refusal over something the launcher read -- a
# missing account .claude.json with the default account's present, one with
# no usable identity, a missing, empty, token-less, claudeAiOauth-less or
# locked Keychain item -- is asserted to name the account, to come before the
# build, and to print none of the LEAKME marker values planted in the identity
# and Keychain fixtures. An invalid name is refused, and `backup` and a missing
# account directory are refused with no Keychain read. Every case inherits a
# CLAUDE_CONFIG_DIR naming the account directory, which must decide nothing:
# the cases without `--as` still read ~/.claude.json, with no Keychain read
# before the build.
#
# Run directly:
#
#   plugins/claude-vm/payload/test/account-launch-test.sh
#
# Requires: git, yq (mikefarah, at the floor claude_vm_require_yq checks) and
# python3. Skips if any is absent.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$TEST_DIR/../claude-vm.sh"

for tool in git yq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not available; account launch test skipped." >&2
    exit 0
  fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-account-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "ok   - $label"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $label"
    echo "        expected: [$expected]"
    echo "        actual:   [$actual]"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      PASS=$((PASS + 1))
      echo "ok   - $label"
      ;;
    *)
      FAIL=$((FAIL + 1))
      echo "FAIL - $label"
      echo "        expected to contain: [$needle]"
      printf '%s\n' "$haystack" | sed 's/^/          /'
      ;;
  esac
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      FAIL=$((FAIL + 1))
      echo "FAIL - $label"
      echo "        expected NOT to contain: [$needle]"
      ;;
    *)
      PASS=$((PASS + 1))
      echo "ok   - $label"
      ;;
  esac
}

# ---------------------------------------------------------------------
# Stubs. `security` logs the service it was asked for to $SEC_LOG, prints
# $SEC_BLOB's contents on stdout and $SEC_ERR on stderr, and exits $SEC_RC.
# `gpg` accepts every key, so the trust-path preflight passes. `podman` only
# records that it was run. yq and python3 are linked in, so PATH need carry
# nothing beyond the stubs and the base system.
# ---------------------------------------------------------------------
STUBBIN="$WORK/stubbin"
mkdir -p "$STUBBIN"
cat >"$STUBBIN/security" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-s" ]; then printf '%s\n' "$2" >> "$SEC_LOG"; fi
  shift
done
[ -n "${SEC_BLOB:-}" ] && cat "$SEC_BLOB"
[ -n "${SEC_ERR:-}" ] && printf '%s\n' "$SEC_ERR" >&2
exit "${SEC_RC:-0}"
STUB
cat >"$STUBBIN/gpg" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$STUBBIN/podman" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PODMAN_LOG"
exit 1
STUB
chmod +x "$STUBBIN/security" "$STUBBIN/gpg" "$STUBBIN/podman"
ln -s "$(command -v yq)" "$STUBBIN/yq"
ln -s "$(command -v python3)" "$STUBBIN/python3"

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

GLOBAL_DIR="$WORK/gconfig"
mkdir -p "$GLOBAL_DIR"
printf 'claude:\n  signing_key_fingerprint: "0123456789ABCDEF0123456789ABCDEF01234567"\n' \
  >"$GLOBAL_DIR/config-boot.yml"

FAKE_HOME="$WORK/home"
ACCOUNT_DIR="$FAKE_HOME/.claude.work"
mkdir -p "$ACCOUNT_DIR" "$WORK/tmp" "$WORK/state"

SEC_LOG="$WORK/security.log"
PODMAN_LOG="$WORK/podman.log"
: >"$PODMAN_LOG"

# Identity and credential fixtures. Each carries a LEAKME marker in a value,
# so a refusal that printed what it read would be caught.
IDENTITY_OK='{"userID":"LEAKME-USER","oauthAccount":{"emailAddress":"LEAKME@example.com"}}'
IDENTITY_NONE='{"oauthAccount":{"emailAddress":"LEAKME@example.com"}}'
BLOB_OK="$WORK/blob-ok.json"
printf '%s' '{"claudeAiOauth":{"accessToken":"LEAKME-ACCESS","refreshToken":"LEAKME-REFRESH"}}' >"$BLOB_OK"
BLOB_EMPTY_TOKENS="$WORK/blob-empty.json"
printf '%s' '{"claudeAiOauth":{"accessToken":"","refreshToken":"","note":"LEAKME-NOTE"}}' >"$BLOB_EMPTY_TOKENS"
BLOB_MCP_ONLY="$WORK/blob-mcp.json"
printf '%s' '{"mcpOAuth":{"x":{"accessToken":"LEAKME-MCP"}}}' >"$BLOB_MCP_ONLY"

# The service Claude Code itself uses for CLAUDE_CONFIG_DIR=<dir>, computed
# here independently of lib/credential.sh.
WORK_SERVICE="Claude Code-credentials-$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:8])' "$ACCOUNT_DIR")"

# The marker the launcher prints once every check up to the image build has
# passed and the (vfkit-less) toolchain preflight refuses.
PAST_ACCOUNT_CHECKS="dependency preflight failed"

# run_launcher [arg...] -> the launcher's stderr+stdout. Every case inherits a
# CLAUDE_CONFIG_DIR naming the account directory, which must decide nothing.
run_launcher() {
  : >"$SEC_LOG"
  HOME="$FAKE_HOME" \
    PATH="$STUBBIN:/usr/bin:/bin" \
    TMPDIR="$WORK/tmp" \
    XDG_STATE_HOME="$WORK/state" \
    CLAUDE_VM_GLOBAL_CONFIG_DIR="$GLOBAL_DIR" \
    CLAUDE_CONFIG_DIR="$ACCOUNT_DIR" \
    SEC_LOG="$SEC_LOG" PODMAN_LOG="$PODMAN_LOG" \
    /bin/bash "$LAUNCHER" "$@" "$REPO" 2>&1
}

# A refusal: it names the account, ran before the build, and printed no value
# from the identity file or the Keychain.
assert_refusal() {
  local label="$1" out="$2"
  assert_contains "$label: names the account" "$out" "account 'work'"
  assert_not_contains "$label: refuses before the image build" "$out" "$PAST_ACCOUNT_CHECKS"
  assert_not_contains "$label: prints no value it read" "$out" "LEAKME"
}

# --- 1. Every source is the account's ----------------------------------
# The default account has no ~/.claude.json at all, so getting past the
# identity preflight proves the account's file was the one read.
printf '%s' "$IDENTITY_OK" >"$ACCOUNT_DIR/.claude.json"
OUT="$(SEC_BLOB="$BLOB_OK" SEC_RC=0 run_launcher --as work)"
assert_contains "--as work: the account's identity and credential pass the preflights" "$OUT" "$PAST_ACCOUNT_CHECKS"
assert_eq "--as work: the Keychain is asked for the account's derived service only" \
  "$WORK_SERVICE" "$(cat "$SEC_LOG")"
assert_not_contains "--as work: no value from the Keychain or identity file is printed" "$OUT" "LEAKME"

# --- 2. A missing account .claude.json is refused, never substituted ----
rm -f "$ACCOUNT_DIR/.claude.json"
printf '%s' "$IDENTITY_OK" >"$FAKE_HOME/.claude.json"
OUT="$(SEC_BLOB="$BLOB_OK" SEC_RC=0 run_launcher --as work)"
assert_refusal "--as work, no account .claude.json" "$OUT"
assert_contains "--as work, no account .claude.json: names the missing file" "$OUT" "$ACCOUNT_DIR/.claude.json"
assert_eq "--as work, no account .claude.json: the default account's file is not copied in" \
  "absent" "$([ -e "$ACCOUNT_DIR/.claude.json" ] && echo present || echo absent)"
assert_eq "--as work, no account .claude.json: no Keychain read" "" "$(cat "$SEC_LOG")"

# --- 3. An account .claude.json with no usable identity is refused -------
printf '%s' "$IDENTITY_NONE" >"$ACCOUNT_DIR/.claude.json"
OUT="$(SEC_BLOB="$BLOB_OK" SEC_RC=0 run_launcher --as work)"
assert_refusal "--as work, no usable identity" "$OUT"
assert_contains "--as work, no usable identity: says so" "$OUT" "no usable"
printf '%s' "$IDENTITY_OK" >"$ACCOUNT_DIR/.claude.json"

# --- 4. Keychain refusals -------------------------------------------------
OUT="$(SEC_RC=44 run_launcher --as work)"
assert_refusal "--as work, no Keychain item" "$OUT"
assert_contains "--as work, no Keychain item: names the service" "$OUT" "$WORK_SERVICE"

OUT="$(SEC_BLOB="$BLOB_EMPTY_TOKENS" SEC_RC=0 run_launcher --as work)"
assert_refusal "--as work, empty tokens" "$OUT"
assert_contains "--as work, empty tokens: says the item is unusable" "$OUT" "no usable claude.ai OAuth credential"

OUT="$(SEC_BLOB="$BLOB_MCP_ONLY" SEC_RC=0 run_launcher --as work)"
assert_refusal "--as work, no claudeAiOauth" "$OUT"

OUT="$(SEC_RC=0 run_launcher --as work)"
assert_refusal "--as work, empty Keychain item" "$OUT"

OUT="$(SEC_ERR="keychain is locked" SEC_RC=36 run_launcher --as work)"
assert_refusal "--as work, locked Keychain" "$OUT"
assert_contains "--as work, locked Keychain: surfaces the security error" "$OUT" "keychain is locked"

# --- 5. Name and directory refusals ---------------------------------------
mkdir -p "$FAKE_HOME/.claude.backup"
OUT="$(run_launcher --as backup)"
assert_contains "--as backup: refused as an invalid name" "$OUT" "not a valid account name"
assert_contains "--as backup: names the account" "$OUT" "account 'backup'"
assert_eq "--as backup: no Keychain read" "" "$(cat "$SEC_LOG")"

OUT="$(run_launcher --as 'w rk')"
assert_contains "--as 'w rk': refused as an invalid name" "$OUT" "not a valid account name"

OUT="$(run_launcher --as absent)"
assert_contains "--as absent: a missing account directory is refused" "$OUT" "has no config directory"
assert_contains "--as absent: names the account" "$OUT" "account 'absent'"
assert_eq "--as absent: no Keychain read" "" "$(cat "$SEC_LOG")"
assert_not_contains "--as absent: refuses before the image build" "$OUT" "$PAST_ACCOUNT_CHECKS"

# --- 6. Without --as, the default account's sources -----------------------
# The inherited CLAUDE_CONFIG_DIR names the account directory, whose
# .claude.json is removed: passing the identity preflight shows ~/.claude.json
# was read, and no Keychain read happens before the image build.
rm -f "$ACCOUNT_DIR/.claude.json"
OUT="$(SEC_BLOB="$BLOB_OK" SEC_RC=0 run_launcher)"
assert_contains "no --as: ~/.claude.json passes the identity preflight" "$OUT" "$PAST_ACCOUNT_CHECKS"
assert_eq "no --as: no Keychain read before the image build" "" "$(cat "$SEC_LOG")"

rm -f "$FAKE_HOME/.claude.json"
printf '%s' "$IDENTITY_OK" >"$ACCOUNT_DIR/.claude.json"
OUT="$(SEC_BLOB="$BLOB_OK" SEC_RC=0 run_launcher)"
assert_contains "no --as: a missing ~/.claude.json is refused even with CLAUDE_CONFIG_DIR's present" \
  "$OUT" "no ~/.claude.json found on the host"

assert_eq "no case ran podman" "" "$(cat "$PODMAN_LOG")"

echo ""
echo "account-launch-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
