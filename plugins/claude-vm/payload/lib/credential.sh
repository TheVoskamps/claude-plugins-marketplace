#!/usr/bin/env bash
#
# credential.sh -- selective extraction of the claude.ai OAuth credential
# from the raw macOS Keychain blob, plus construction of the identity seed
# from the host ~/.claude.json (2 keys selected from the host + 4 synthesized),
# for claude-vm.
#
# Sourced by claude-vm.sh. Also directly testable: both selection functions
# are pure (input on stdin, plus argv for the seed's resolved version ->
# selected JSON on stdout) with no Keychain, no VM, no network, and no host
# mutation, so payload/test/credential-test.sh exercises them in isolation
# against representative fixtures.
#
# WHY a selection step exists (issue #50 review): the Keychain item named
# "Claude Code-credentials" is NOT just the claude.ai login credential. On a
# real host its JSON has sibling top-level keys -- at minimum `claudeAiOauth`
# (the intended full-scope claude.ai login) AND `mcpOAuth` (per-MCP-server
# OAuth credentials, e.g. a Sentry MCP access/refresh token). Copying the
# blob verbatim into the guest would mount those unrelated MCP credentials
# into the VM alongside the intended one -- a scope leak broader than the
# guest needs. So we select ONLY the `claudeAiOauth` key and write a file
# in the shape claude expects at ~/.claude/.credentials.json, namely
# `{"claudeAiOauth": { ... }}`, dropping `mcpOAuth` and any other siblings.
#
# This deliberately reserializes the JSON (it is NOT a byte-for-byte copy):
# selecting a subset of keys requires parsing. The selection is the point.
#
# Fail-closed contract: if the input is not valid JSON, or has no
# `claudeAiOauth` key (or it is not a JSON object), the function exits
# non-zero and emits NOTHING on stdout. The caller routes that to the
# friendly "log in to claude.ai" path -- an operator with no usable
# claudeAiOauth key is effectively not logged in.
#
# Requires: python3 (stock on macOS, where this plugin runs -- `security`
# is itself macOS-only). python3's json stdlib does the key selection; we
# deliberately do NOT add a hard `jq` dependency, mirroring the rest of the
# plugin (claude-cache.sh treats jq as optional with a jq-free fallback).

# claude_vm_select_claude_credential
#
# Reads the raw Keychain blob from stdin, writes the selected
# {"claudeAiOauth": {...}} JSON to stdout. Exits:
#   0  -> selection succeeded; valid JSON written to stdout
#   1  -> input not valid JSON, or no usable `claudeAiOauth` object key
#         (nothing written to stdout)
#   2  -> python3 not available (nothing written to stdout)
#
# Pure: no side effects beyond stdin/stdout. Does not touch the Keychain,
# the filesystem, or any host state.
claude_vm_select_claude_credential() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "claude-vm: python3 is required to select the claude.ai OAuth credential from the Keychain blob." >&2
    return 2
  fi
  # The selection runs entirely in python3's json stdlib. stdin is the raw
  # blob; stdout is the reserialized {"claudeAiOauth": {...}} on success.
  # A non-object `claudeAiOauth`, a missing key, or non-JSON input all exit
  # non-zero WITHOUT writing partial output (json.dumps runs only after the
  # key is validated, and is the last statement).
  python3 -c '
import sys, json
try:
    blob = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(blob, dict):
    sys.exit(1)
cred = blob.get("claudeAiOauth")
if not isinstance(cred, dict):
    # Missing, null, or not an object -> no usable claude.ai login.
    sys.exit(1)
sys.stdout.write(json.dumps({"claudeAiOauth": cred}))
'
}

# claude_vm_select_claude_json_seed <resolved-version>
#
# Reads the host's ~/.claude.json on stdin, writes a 6-key identity seed to
# stdout (issue #88). Takes the concrete resolved claude version as its FIRST
# POSITIONAL ARGUMENT (e.g. "2.1.172") -- NOT on stdin, which is the host
# JSON. Exits:
#   0  -> selection succeeded; valid JSON written to stdout
#   1  -> input not valid JSON, or missing/unusable `userID` or
#         `oauthAccount` (nothing written to stdout)
#   2  -> python3 not available (nothing written to stdout)
#
# The emitted object carries SIX top-level keys:
#   - userID                 (from host ~/.claude.json)
#   - oauthAccount           (from host ~/.claude.json)
#   - hasCompletedOnboarding (synthesized: boolean true)
#   - autoUpdates            (synthesized: boolean false)
#   - lastOnboardingVersion  (the resolved version string passed in)
#   - lastReleaseNotesSeen   (the resolved version string passed in)
#
# WHY this widened seed exists (issue #88, established by real-hardware
# testing): the interactive Claude Code TUI in the guest decides "am I
# onboarded / logged in" from on-disk state -- the bearer token in
# ~/.claude/.credentials.json (already installed via the claudecreds mount)
# PLUS identity AND onboarding state in ~/.claude.json. A seed carrying ONLY
# {userID, oauthAccount} is insufficient: the guest claude still runs its
# onboarding flow (the login wall) on every boot because
# `hasCompletedOnboarding` is absent. Separately, with `autoUpdates` unset the
# guest claude immediately tries to self-update and fails (egress-confined VM,
# RO-mounted binary). So the seed synthesizes `hasCompletedOnboarding: true`
# (skip the wall) and `autoUpdates: false` (no self-update), and stamps
# `lastOnboardingVersion` / `lastReleaseNotesSeen` with the concrete resolved
# claude version so the release-notes / onboarding-version gates also read as
# satisfied.
#
# machineID is DELIBERATELY OMITTED -- the guest mints its own on first run;
# seeding the host's would bind the throwaway guest to the host machine
# identity.
#
# SELECTION discipline mirrors claude_vm_select_claude_credential: the host
# ~/.claude.json carries far more than identity (projects{}, has* flags,
# metrics, tips history). Copying it verbatim would leak host-local state into
# the guest. So we select ONLY `userID` and `oauthAccount` from the host, and
# SYNTHESIZE the other four keys (two static booleans + two version-derived) --
# nothing else from the host survives.
#
# Fail-closed contract: invalid JSON, a non-object top level, a missing/
# non-string `userID`, or a missing/non-object `oauthAccount` all exit
# non-zero with NOTHING on stdout. The caller routes that to a friendly
# "log in to Claude Code on the host first" abort. On a successful emit the
# two static booleans and the two version fields are ALWAYS present.
#
# Pure: no side effects beyond stdin/stdout/argv. Does not touch the filesystem
# or any host state.
claude_vm_select_claude_json_seed() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "claude-vm: python3 is required to select the identity seed from ~/.claude.json." >&2
    return 2
  fi
  # The resolved concrete claude version rides in via the environment (NOT
  # stdin -- stdin is the host JSON). An empty/unset value is tolerated (the
  # version fields then emit empty strings): credential.sh has no business
  # deciding what a "valid" version is, and the real write site passes an
  # authoritative resolved version.
  #
  # json.dumps runs only after BOTH host keys are validated and is the last
  # statement, so a failure exits non-zero WITHOUT writing partial output.
  CLAUDE_VM_SEED_VERSION="${1:-}" python3 -c '
import sys, json, os
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)
user_id = doc.get("userID")
oauth = doc.get("oauthAccount")
if not isinstance(user_id, str) or not user_id:
    # Missing, null, non-string, or empty -> no usable identity.
    sys.exit(1)
if not isinstance(oauth, dict) or not oauth:
    # Missing, null, not an object, or empty -> no usable account state.
    sys.exit(1)
version = os.environ.get("CLAUDE_VM_SEED_VERSION", "")
# Two identity keys from the host, four synthesized: two static booleans that
# skip the onboarding wall and disable self-update, two version-derived fields.
# machineID is intentionally NOT emitted -- the guest mints its own.
sys.stdout.write(json.dumps({
    "userID": user_id,
    "oauthAccount": oauth,
    "hasCompletedOnboarding": True,
    "autoUpdates": False,
    "lastOnboardingVersion": version,
    "lastReleaseNotesSeen": version,
}))
'
}
