#!/usr/bin/env bash
#
# credential-test.sh -- unit tests for claude-vm's claude.ai OAuth
# credential SELECTION logic (issue #50 review fix).
#
# Exercises payload/lib/credential.sh's pure functions:
#   - claude_vm_select_claude_credential: raw Keychain blob on stdin ->
#     {"claudeAiOauth": {...}} on stdout, fail-closed on missing key / bad input.
#   - claude_vm_validate_claude_credential_tokens: predicate over the selected
#     credential -- exit 0 iff both tokens non-empty (issue #88, Gap 1).
#   - claude_vm_select_claude_json_seed: build the identity seed from the host
#     ~/.claude.json (issue #88).
# No Keychain, no VM, no network, no host mutation. Run directly:
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
# claude_vm_validate_claude_credential_tokens (issue #88, Gap 1): predicate over
# the SELECTED {"claudeAiOauth": {...}} -- exit 0 iff BOTH accessToken and
# refreshToken are non-empty strings, exit 1 otherwise, and NEVER write to
# stdout. Guards against the degraded-Keychain shape (structurally complete but
# empty tokens) that would boot the guest to "Not logged in".
# ---------------------------------------------------------------------

# Healthy: both tokens non-empty -> exit 0, no stdout.
HEALTHY_CRED='{"claudeAiOauth": {"accessToken": "acc-123", "refreshToken": "ref-456", "expiresAt": 1893456000000}}'
VOUT="$(printf '%s' "$HEALTHY_CRED" | claude_vm_validate_claude_credential_tokens)"
VRC=$?
assert_rc "validate: healthy credential exits 0" "0" "$VRC"
assert_eq "validate: healthy credential writes nothing" "" "$VOUT"

# Degraded: empty accessToken -> exit 1, no stdout.
EMPTY_ACCESS='{"claudeAiOauth": {"accessToken": "", "refreshToken": "ref-456", "expiresAt": 0}}'
VOUT2="$(printf '%s' "$EMPTY_ACCESS" | claude_vm_validate_claude_credential_tokens)"
VRC2=$?
assert_rc "validate: empty accessToken exits 1" "1" "$VRC2"
assert_eq "validate: empty accessToken writes nothing" "" "$VOUT2"

# Degraded: empty refreshToken -> exit 1, no stdout.
EMPTY_REFRESH='{"claudeAiOauth": {"accessToken": "acc-123", "refreshToken": "", "expiresAt": 0}}'
VOUT3="$(printf '%s' "$EMPTY_REFRESH" | claude_vm_validate_claude_credential_tokens)"
VRC3=$?
assert_rc "validate: empty refreshToken exits 1" "1" "$VRC3"
assert_eq "validate: empty refreshToken writes nothing" "" "$VOUT3"

# Degraded: BOTH tokens empty (the real observed shape) -> exit 1, no stdout.
BOTH_EMPTY='{"claudeAiOauth": {"accessToken": "", "refreshToken": "", "expiresAt": 0}}'
VOUT4="$(printf '%s' "$BOTH_EMPTY" | claude_vm_validate_claude_credential_tokens)"
VRC4=$?
assert_rc "validate: both tokens empty exits 1" "1" "$VRC4"
assert_eq "validate: both tokens empty writes nothing" "" "$VOUT4"

# Missing keys entirely -> exit 1, no stdout.
MISSING_KEYS='{"claudeAiOauth": {"expiresAt": 0}}'
VOUT5="$(printf '%s' "$MISSING_KEYS" | claude_vm_validate_claude_credential_tokens)"
VRC5=$?
assert_rc "validate: missing token keys exits 1" "1" "$VRC5"
assert_eq "validate: missing token keys writes nothing" "" "$VOUT5"

# accessToken present but not a string -> exit 1.
NONSTR_TOKEN='{"claudeAiOauth": {"accessToken": 12345, "refreshToken": "ref-456"}}'
VOUT6="$(printf '%s' "$NONSTR_TOKEN" | claude_vm_validate_claude_credential_tokens)"
VRC6=$?
assert_rc "validate: non-string accessToken exits 1" "1" "$VRC6"

# Invalid JSON -> exit 1, no stdout.
VOUT7="$(printf '%s' "not json {" | claude_vm_validate_claude_credential_tokens)"
VRC7=$?
assert_rc "validate: invalid JSON exits 1" "1" "$VRC7"
assert_eq "validate: invalid JSON writes nothing" "" "$VOUT7"

# No claudeAiOauth key -> exit 1.
NO_CRED='{"mcpOAuth": {"x": {"accessToken": "y"}}}'
VOUT8="$(printf '%s' "$NO_CRED" | claude_vm_validate_claude_credential_tokens)"
VRC8=$?
assert_rc "validate: no claudeAiOauth key exits 1" "1" "$VRC8"

# ---------------------------------------------------------------------
# claude_vm_select_claude_json_seed (issue #88): build the identity seed from
# the host ~/.claude.json -- select {userID, oauthAccount} from the host,
# SYNTHESIZE {hasCompletedOnboarding: true, autoUpdates: false}, stamp
# {lastOnboardingVersion, lastReleaseNotesSeen} with the resolved version passed
# in as $1, ADDITIVELY pass through benign host UI keys when present, and (given
# a guest-repo-path in $3) seed a projects entry keyed on the guest mount path
# with the trust flags forced true. machineID must NOT be emitted. Fail-closed
# on a missing/unusable userID or oauthAccount.
# ---------------------------------------------------------------------

# The resolved concrete claude version the caller passes as the FIRST arg. The
# seed stamps this into lastOnboardingVersion / lastReleaseNotesSeen.
SEED_VERSION="2.1.172"
# The host repo path ($2) and guest repo mount path ($3) the launcher passes.
SEED_HOST_REPO="/Users/operator/some/repo"
SEED_GUEST_REPO="/mnt/repo"

# Fixture: the real ~/.claude.json shape -- the two identity keys we select,
# the ADDITIVE pass-through keys (installMethod, hasSeenTasksHint, hasUsedStash,
# tipsHistory), a projects entry for the host repo path (with a FALSE trust flag
# and an extra allowedTools key that must survive verbatim), plus the noise we
# must DROP (a projects entry for a DIFFERENT repo, telemetry) AND a host
# machineID we must NOT propagate. The host's own hasCompletedOnboarding/
# autoUpdates values are IGNORED -- the seed synthesizes its own (true / false)
# regardless of what the host carries; the fixture sets host values that DIFFER
# from the synthesized ones (autoUpdates "on-host-true") so a passthrough bug
# would be caught.
FULL_CLAUDE_JSON='{
  "userID": "abc123deadbeef",
  "oauthAccount": {
    "accountUuid": "uuid-1111",
    "emailAddress": "operator@example.com",
    "organizationUuid": "org-2222",
    "organizationRole": "admin"
  },
  "hasCompletedOnboarding": false,
  "autoUpdates": "on-host-true",
  "machineID": "host-machine-secret",
  "installMethod": "native",
  "hasSeenTasksHint": true,
  "hasUsedStash": true,
  "tipsHistory": {"tip-a": 3, "tip-b": 7},
  "numStartups": 42,
  "projects": {
    "/Users/operator/some/repo": {
      "hasTrustDialogAccepted": false,
      "hasCompletedProjectOnboarding": false,
      "allowedTools": ["Bash(git status)", "Read"],
      "lastCost": 1.23,
      "lastSessionId": "sess-secret"
    },
    "/Users/operator/OTHER/repo": {
      "hasTrustDialogAccepted": true,
      "lastSessionId": "other-secret"
    }
  }
}'

SEED_OUT="$(printf '%s' "$FULL_CLAUDE_JSON" | claude_vm_select_claude_json_seed "$SEED_VERSION" "$SEED_HOST_REPO" "$SEED_GUEST_REPO")"
SEED_RC=$?
assert_rc "full ~/.claude.json: seed selection exits 0" "0" "$SEED_RC"

# Output is valid JSON.
if printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
  assert_eq "seed: output is valid JSON" "ok" "ok"
else
  assert_eq "seed: output is valid JSON" "ok" "INVALID-JSON"
fi

# EXACTLY the expected keys: 6 base + 4 pass-through + projects.
SEED_KEYS="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; print(",".join(sorted(json.load(sys.stdin).keys())))')"
assert_eq "seed: output has the base + pass-through + projects keys" \
  "autoUpdates,hasCompletedOnboarding,hasSeenTasksHint,hasUsedStash,installMethod,lastOnboardingVersion,lastReleaseNotesSeen,oauthAccount,projects,tipsHistory,userID" \
  "$SEED_KEYS"

# The two host-selected keys survive verbatim.
SEED_USER="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["userID"])')"
assert_eq "seed: userID preserved" "abc123deadbeef" "$SEED_USER"

SEED_EMAIL="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["oauthAccount"]["emailAddress"])')"
assert_eq "seed: oauthAccount.emailAddress preserved" "operator@example.com" "$SEED_EMAIL"

# The two synthesized booleans are present with the RIGHT type and value,
# regardless of the host's own (differing) values. json.dumps emits Python
# True/False as JSON true/false; check the type is bool AND the value is right.
SEED_ONBOARD="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; v=json.load(sys.stdin)["hasCompletedOnboarding"]; print(type(v).__name__+":"+repr(v))')"
assert_eq "seed: hasCompletedOnboarding is boolean true" "bool:True" "$SEED_ONBOARD"

SEED_AUTOUPD="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; v=json.load(sys.stdin)["autoUpdates"]; print(type(v).__name__+":"+repr(v))')"
assert_eq "seed: autoUpdates is boolean false" "bool:False" "$SEED_AUTOUPD"

# The two version fields equal the passed-in resolved version.
SEED_LOV="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["lastOnboardingVersion"])')"
assert_eq "seed: lastOnboardingVersion equals passed-in version" "$SEED_VERSION" "$SEED_LOV"

SEED_LRNS="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["lastReleaseNotesSeen"])')"
assert_eq "seed: lastReleaseNotesSeen equals passed-in version" "$SEED_VERSION" "$SEED_LRNS"

# ADDITIVE pass-through keys copied verbatim when present.
SEED_INSTALL="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["installMethod"])')"
assert_eq "seed: installMethod passed through verbatim" "native" "$SEED_INSTALL"

SEED_TASKS="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; v=json.load(sys.stdin)["hasSeenTasksHint"]; print(type(v).__name__+":"+repr(v))')"
assert_eq "seed: hasSeenTasksHint passed through verbatim" "bool:True" "$SEED_TASKS"

SEED_STASH="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; v=json.load(sys.stdin)["hasUsedStash"]; print(type(v).__name__+":"+repr(v))')"
assert_eq "seed: hasUsedStash passed through verbatim" "bool:True" "$SEED_STASH"

# tipsHistory: the WHOLE object copied.
SEED_TIPS="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; d=json.load(sys.stdin)["tipsHistory"]; print(str(d.get("tip-a"))+","+str(d.get("tip-b")))')"
assert_eq "seed: tipsHistory object copied whole" "3,7" "$SEED_TIPS"

# projects: rekeyed to the guest path, host entry copied verbatim with the two
# trust flags FORCED true (overriding the host's false) and extras (allowedTools)
# surviving verbatim.
SEED_PROJ_KEYS="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin)["projects"].keys()))')"
assert_eq "seed: projects keyed on the GUEST mount path" "/mnt/repo" "$SEED_PROJ_KEYS"

SEED_PROJ_TRUST="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; v=json.load(sys.stdin)["projects"]["/mnt/repo"]["hasTrustDialogAccepted"]; print(type(v).__name__+":"+repr(v))')"
assert_eq "seed: projects hasTrustDialogAccepted FORCED true" "bool:True" "$SEED_PROJ_TRUST"

SEED_PROJ_ONBOARD="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; v=json.load(sys.stdin)["projects"]["/mnt/repo"]["hasCompletedProjectOnboarding"]; print(type(v).__name__+":"+repr(v))')"
assert_eq "seed: projects hasCompletedProjectOnboarding FORCED true" "bool:True" "$SEED_PROJ_ONBOARD"

SEED_PROJ_TOOLS="$(printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin)["projects"]["/mnt/repo"]["allowedTools"]))')"
assert_eq "seed: projects entry extras (allowedTools) survive verbatim" "Bash(git status),Read" "$SEED_PROJ_TOOLS"

# machineID must be ABSENT -- the guest mints its own; the host's must not leak.
if printf '%s' "$SEED_OUT" | python3 -c 'import sys,json; sys.exit(0 if "machineID" in json.load(sys.stdin) else 1)'; then
  assert_eq "seed: machineID is ABSENT from output" "absent" "PRESENT-LEAKED"
else
  assert_eq "seed: machineID is ABSENT from output" "absent" "absent"
fi

# The dropped noise must NOT appear anywhere -- the OTHER (non-launched) repo's
# entry and its secret, top-level telemetry. NOTE: the launched repo's own entry
# is copied VERBATIM (rekeyed to /mnt/repo), so ITS keys -- including
# lastSessionId ("sess-secret") -- intentionally survive; only the two trust
# flags are forced. (installMethod/tipsHistory/hasSeenTasksHint/hasUsedStash ARE
# now passed through, so they are no longer in this drop list.)
for needle in "other-secret" "OTHER/repo" "numStartups"; do
  if printf '%s' "$SEED_OUT" | grep -q "$needle"; then
    assert_eq "seed: '$needle' is DROPPED from output" "absent" "PRESENT-LEAKED"
  else
    assert_eq "seed: '$needle' is DROPPED from output" "absent" "absent"
  fi
done

# The host repo path key must NOT appear -- the projects entry is rekeyed to the
# guest path.
if printf '%s' "$SEED_OUT" | grep -q "/Users/operator/some/repo"; then
  assert_eq "seed: host repo path key is REKEYED away" "absent" "PRESENT-LEAKED"
else
  assert_eq "seed: host repo path key is REKEYED away" "absent" "absent"
fi

# Version passthrough: a DIFFERENT version arg lands in both version fields.
SEED_OUT_V2="$(printf '%s' "$FULL_CLAUDE_JSON" | claude_vm_select_claude_json_seed "9.9.9" "$SEED_HOST_REPO" "$SEED_GUEST_REPO")"
SEED_V2="$(printf '%s' "$SEED_OUT_V2" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["lastOnboardingVersion"]+","+d["lastReleaseNotesSeen"])')"
assert_eq "seed: version arg passes through to both version fields" "9.9.9,9.9.9" "$SEED_V2"

# ADDITIVE keys ABSENT on the host -> silently OMITTED (never a failure).
MINIMAL_CLAUDE_JSON='{
  "userID": "min-user",
  "oauthAccount": {"emailAddress": "min@example.com"}
}'
SEED_MIN="$(printf '%s' "$MINIMAL_CLAUDE_JSON" | claude_vm_select_claude_json_seed "$SEED_VERSION" "$SEED_HOST_REPO" "$SEED_GUEST_REPO")"
SEED_MIN_RC=$?
assert_rc "seed (minimal host): exits 0" "0" "$SEED_MIN_RC"
SEED_MIN_KEYS="$(printf '%s' "$SEED_MIN" | python3 -c 'import sys,json; print(",".join(sorted(json.load(sys.stdin).keys())))')"
# No pass-through keys present on the host -> only the 6 base keys + projects.
assert_eq "seed (minimal host): pass-through keys OMITTED when absent" \
  "autoUpdates,hasCompletedOnboarding,lastOnboardingVersion,lastReleaseNotesSeen,oauthAccount,projects,userID" \
  "$SEED_MIN_KEYS"

# projects: host has NO entry for the launched repo -> minimal synthesized entry
# with both trust flags true.
SEED_MIN_TRUST="$(printf '%s' "$SEED_MIN" | python3 -c 'import sys,json; p=json.load(sys.stdin)["projects"]["/mnt/repo"]; print(str(p["hasTrustDialogAccepted"])+","+str(p["hasCompletedProjectOnboarding"])+","+str(sorted(p.keys())))')"
assert_eq "seed (minimal host): synthesized projects entry has ONLY the two trust flags true" \
  "True,True,['hasCompletedProjectOnboarding', 'hasTrustDialogAccepted']" \
  "$SEED_MIN_TRUST"

# projects: guest-repo-path input EMPTY -> no projects key at all.
SEED_NO_GUEST="$(printf '%s' "$FULL_CLAUDE_JSON" | claude_vm_select_claude_json_seed "$SEED_VERSION" "$SEED_HOST_REPO" "")"
if printf '%s' "$SEED_NO_GUEST" | python3 -c 'import sys,json; sys.exit(0 if "projects" in json.load(sys.stdin) else 1)'; then
  assert_eq "seed: empty guest-repo-path OMITS projects entirely" "omitted" "PRESENT"
else
  assert_eq "seed: empty guest-repo-path OMITS projects entirely" "omitted" "omitted"
fi

# Fail-closed: missing userID.
NO_USER='{"oauthAccount": {"emailAddress": "x@y.z"}}'
SO1="$(printf '%s' "$NO_USER" | claude_vm_select_claude_json_seed "$SEED_VERSION" "$SEED_HOST_REPO" "$SEED_GUEST_REPO")"
SR1=$?
assert_rc "seed: missing userID exits non-zero" "1" "$SR1"
assert_eq "seed: missing userID writes nothing" "" "$SO1"

# Fail-closed: missing oauthAccount.
NO_OAUTH='{"userID": "abc"}'
SO2="$(printf '%s' "$NO_OAUTH" | claude_vm_select_claude_json_seed "$SEED_VERSION" "$SEED_HOST_REPO" "$SEED_GUEST_REPO")"
SR2=$?
assert_rc "seed: missing oauthAccount exits non-zero" "1" "$SR2"
assert_eq "seed: missing oauthAccount writes nothing" "" "$SO2"

# Fail-closed: userID present but not a string.
BAD_USER='{"userID": 12345, "oauthAccount": {"a": "b"}}'
SO3="$(printf '%s' "$BAD_USER" | claude_vm_select_claude_json_seed "$SEED_VERSION" "$SEED_HOST_REPO" "$SEED_GUEST_REPO")"
SR3=$?
assert_rc "seed: non-string userID exits non-zero" "1" "$SR3"

# Fail-closed: oauthAccount present but not an object.
BAD_OAUTH='{"userID": "abc", "oauthAccount": "not-an-object"}'
SO4="$(printf '%s' "$BAD_OAUTH" | claude_vm_select_claude_json_seed "$SEED_VERSION" "$SEED_HOST_REPO" "$SEED_GUEST_REPO")"
SR4=$?
assert_rc "seed: non-object oauthAccount exits non-zero" "1" "$SR4"

# Fail-closed: empty oauthAccount object -> not usable.
EMPTY_OAUTH='{"userID": "abc", "oauthAccount": {}}'
SO5="$(printf '%s' "$EMPTY_OAUTH" | claude_vm_select_claude_json_seed "$SEED_VERSION" "$SEED_HOST_REPO" "$SEED_GUEST_REPO")"
SR5=$?
assert_rc "seed: empty oauthAccount exits non-zero" "1" "$SR5"

# Fail-closed: invalid JSON.
SO6="$(printf '%s' "not json {" | claude_vm_select_claude_json_seed "$SEED_VERSION" "$SEED_HOST_REPO" "$SEED_GUEST_REPO")"
SR6=$?
assert_rc "seed: invalid JSON exits non-zero" "1" "$SR6"
assert_eq "seed: invalid JSON writes nothing" "" "$SO6"

# Fail-closed: empty input.
SO7="$(printf '%s' "" | claude_vm_select_claude_json_seed "$SEED_VERSION" "$SEED_HOST_REPO" "$SEED_GUEST_REPO")"
SR7=$?
assert_rc "seed: empty input exits non-zero" "1" "$SR7"

# ---------------------------------------------------------------------
echo
echo "credential-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
