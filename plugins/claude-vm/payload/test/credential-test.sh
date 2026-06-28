#!/usr/bin/env bash
#
# credential-test.sh -- unit tests for claude-vm's claude.ai OAuth
# credential SELECTION logic (issue #50 review fix).
#
# Exercises payload/lib/credential.sh's pure selection function
# (claude_vm_select_claude_credential): raw Keychain blob on stdin ->
# {"claudeAiOauth": {...}} on stdout, fail-closed on missing key / bad
# input. No Keychain, no VM, no network, no host mutation. Run directly:
#
#   plugins/claude-vm/payload/test/credential-test.sh
#
# Requires: python3 (stock on macOS). Skips with a clear message if absent.
#
# NOTE: this does NOT and CANNOT test the live `security` Keychain call --
# that is a credential surface. It proves the selection logic in isolation
# against a representative fixture matching the real two-sibling-key shape
# (claudeAiOauth + mcpOAuth) observed on a real host.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../lib/credential.sh"

# shellcheck source=../lib/credential.sh
. "$LIB"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available; credential selection tests skipped." >&2
  exit 0
fi

PASS=0
FAIL=0

# assert_eq <label> <expected> <actual>
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

# assert_rc <label> <expected-rc> <actual-rc>
assert_rc() {
  assert_eq "$1" "$2" "$3"
}

# ---------------------------------------------------------------------
# Fixture: the real two-sibling-key shape observed on a live host --
# claudeAiOauth (the intended claude.ai login) AND mcpOAuth (an unrelated
# per-MCP-server OAuth credential, here a Sentry MCP token). The verbatim
# copy this fix replaces would have mounted the mcpOAuth block into the
# guest; selection must drop it.
# ---------------------------------------------------------------------
TWO_KEY_BLOB='{
  "mcpOAuth": {
    "sentry|https://mcp.sentry.dev": {
      "serverName": "sentry",
      "serverUrl": "https://mcp.sentry.dev",
      "clientId": "client-abc",
      "redirectUri": "http://localhost:1234/callback",
      "discoveryState": {"foo": "bar"},
      "accessToken": "mcp-secret-access-token"
    }
  },
  "claudeAiOauth": {
    "accessToken": "claude-access-token",
    "refreshToken": "claude-refresh-token",
    "expiresAt": 1893456000000,
    "scopes": ["user:inference", "user:profile"],
    "subscriptionType": "max",
    "rateLimitTier": "default"
  }
}'

# ---------------------------------------------------------------------
# (a) claudeAiOauth is PRESERVED under its key; (b) mcpOAuth is DROPPED;
# (d) output is valid JSON.
# ---------------------------------------------------------------------
OUT="$(printf '%s' "$TWO_KEY_BLOB" | claude_vm_select_claude_credential)"
RC=$?
assert_rc "two-key blob: selection exits 0" "0" "$RC"

# (d) output is valid JSON
if printf '%s' "$OUT" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
  assert_eq "two-key blob: output is valid JSON" "ok" "ok"
else
  assert_eq "two-key blob: output is valid JSON" "ok" "INVALID-JSON"
fi

# (a) claudeAiOauth preserved under its key, with its accessToken intact
TOP_KEYS="$(printf '%s' "$OUT" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(",".join(sorted(d.keys())))')"
assert_eq "selected output has ONLY the claudeAiOauth top-level key" "claudeAiOauth" "$TOP_KEYS"

CLAUDE_TOKEN="$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')"
assert_eq "claudeAiOauth.accessToken preserved" "claude-access-token" "$CLAUDE_TOKEN"

CLAUDE_SUB="$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["claudeAiOauth"]["subscriptionType"])')"
assert_eq "claudeAiOauth.subscriptionType preserved" "max" "$CLAUDE_SUB"

# (b) mcpOAuth dropped -- assert the SECRET MCP token does not appear anywhere
if printf '%s' "$OUT" | grep -q "mcp-secret-access-token"; then
  assert_eq "mcpOAuth secret token is DROPPED from output" "absent" "PRESENT-LEAKED"
else
  assert_eq "mcpOAuth secret token is DROPPED from output" "absent" "absent"
fi
if printf '%s' "$OUT" | grep -q "mcpOAuth"; then
  assert_eq "mcpOAuth key is DROPPED from output" "absent" "PRESENT-LEAKED"
else
  assert_eq "mcpOAuth key is DROPPED from output" "absent" "absent"
fi

# ---------------------------------------------------------------------
# (c) a blob MISSING claudeAiOauth routes to fail-fast (non-zero, no output).
# ---------------------------------------------------------------------
MCP_ONLY_BLOB='{"mcpOAuth": {"sentry": {"accessToken": "x"}}}'
OUT2="$(printf '%s' "$MCP_ONLY_BLOB" | claude_vm_select_claude_credential)"
RC2=$?
assert_rc "mcpOAuth-only blob: selection exits non-zero (fail-fast)" "1" "$RC2"
assert_eq "mcpOAuth-only blob: NOTHING written to stdout" "" "$OUT2"

# ---------------------------------------------------------------------
# Additional fail-closed cases.
# ---------------------------------------------------------------------
# claudeAiOauth present but null -> not a usable object -> fail-fast.
NULL_BLOB='{"claudeAiOauth": null}'
OUT3="$(printf '%s' "$NULL_BLOB" | claude_vm_select_claude_credential)"
RC3=$?
assert_rc "claudeAiOauth=null: selection exits non-zero" "1" "$RC3"
assert_eq "claudeAiOauth=null: NOTHING written to stdout" "" "$OUT3"

# claudeAiOauth present but a string (not an object) -> fail-fast.
STR_BLOB='{"claudeAiOauth": "not-an-object"}'
OUT4="$(printf '%s' "$STR_BLOB" | claude_vm_select_claude_credential)"
RC4=$?
assert_rc "claudeAiOauth=string: selection exits non-zero" "1" "$RC4"

# Invalid JSON -> fail-fast, no output.
OUT5="$(printf '%s' "not json at all {" | claude_vm_select_claude_credential)"
RC5=$?
assert_rc "invalid JSON: selection exits non-zero" "1" "$RC5"
assert_eq "invalid JSON: NOTHING written to stdout" "" "$OUT5"

# Empty input -> fail-fast.
OUT6="$(printf '%s' "" | claude_vm_select_claude_credential)"
RC6=$?
assert_rc "empty input: selection exits non-zero" "1" "$RC6"

# A clean single-key blob (already only claudeAiOauth) round-trips fine.
SINGLE_BLOB='{"claudeAiOauth": {"accessToken": "only-token"}}'
OUT7="$(printf '%s' "$SINGLE_BLOB" | claude_vm_select_claude_credential)"
RC7=$?
assert_rc "single-key blob: selection exits 0" "0" "$RC7"
TOKEN7="$(printf '%s' "$OUT7" | python3 -c 'import sys,json; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')"
assert_eq "single-key blob: accessToken preserved" "only-token" "$TOKEN7"

# ---------------------------------------------------------------------
echo
echo "credential-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
