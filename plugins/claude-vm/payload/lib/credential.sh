#!/usr/bin/env bash
#
# credential.sh -- selective extraction of the claude.ai OAuth credential
# from the raw macOS Keychain blob, plus selection of the minimal identity
# seed from the host ~/.claude.json, for claude-vm.
#
# Sourced by claude-vm.sh. Also directly testable: both selection functions
# are pure (input on stdin -> selected JSON on stdout) with no Keychain, no
# VM, no network, and no host mutation, so payload/test/credential-test.sh
# exercises them in isolation against representative fixtures.
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

# claude_vm_select_claude_json_seed
#
# Reads the host's ~/.claude.json on stdin, writes a MINIMAL identity seed
# {"userID": <str>, "oauthAccount": {...}} to stdout (issue #88, pass 1).
# Exits:
#   0  -> selection succeeded; valid JSON written to stdout
#   1  -> input not valid JSON, or missing/unusable `userID` or
#         `oauthAccount` (nothing written to stdout)
#   2  -> python3 not available (nothing written to stdout)
#
# WHY this exists (issue #88): the interactive Claude Code TUI in the guest
# decides "am I logged in" from on-disk state -- the bearer token in
# ~/.claude/.credentials.json (already installed via the claudecreds mount)
# PLUS identity state in ~/.claude.json (`userID` + `oauthAccount`). A fresh
# throwaway guest lacks that identity state, so every launch shows the login
# menu. Seeding these two top-level keys (and NOTHING else -- no projects{},
# no telemetry, no onboarding flags; those are later passes) makes the guest
# come up already authenticated.
#
# SELECTION discipline mirrors claude_vm_select_claude_credential: the host
# ~/.claude.json carries far more than identity (projects{}, has* flags,
# metrics, tips history). Copying it verbatim would leak host-local state
# into the guest. So we select ONLY `userID` and `oauthAccount` and write a
# minimal object in the shape claude reads at ~/.claude.json.
#
# Fail-closed contract: invalid JSON, a non-object top level, a missing/
# non-string `userID`, or a missing/non-object `oauthAccount` all exit
# non-zero with NOTHING on stdout. The caller routes that to a friendly
# "log in to Claude Code on the host first" abort.
#
# Pure: no side effects beyond stdin/stdout. Does not touch the filesystem
# or any host state.
claude_vm_select_claude_json_seed() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "claude-vm: python3 is required to select the identity seed from ~/.claude.json." >&2
    return 2
  fi
  # json.dumps runs only after BOTH keys are validated and is the last
  # statement, so a failure exits non-zero WITHOUT writing partial output.
  python3 -c '
import sys, json
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
sys.stdout.write(json.dumps({"userID": user_id, "oauthAccount": oauth}))
'
}
