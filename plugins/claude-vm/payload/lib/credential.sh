#!/usr/bin/env bash
#
# credential.sh -- selective extraction of the claude.ai OAuth credential
# from the raw macOS Keychain blob, validation that the selected credential
# carries usable (non-empty) tokens, plus construction of the identity seed
# from the host ~/.claude.json (userID + oauthAccount selected from the host,
# four synthesized onboarding/version keys, additive pass-through of benign
# host UI keys, and a projects entry that skips the guest trust dialog),
# for claude-vm.
#
# Sourced by claude-vm.sh. Also directly testable: the selection/validation
# functions are pure (input on stdin, plus argv for the seed's resolved version
# and host/guest repo paths -> selected JSON on stdout, or an exit code for the
# validator) with no Keychain, no VM, no network, and no host mutation, so
# payload/test/credential-test.sh exercises them in isolation against
# representative fixtures.
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

# claude_vm_validate_claude_credential_tokens
#
# Reads the SELECTED `{"claudeAiOauth": {...}}` JSON on stdin (the output of
# claude_vm_select_claude_credential) and validates that the credential is
# actually USABLE -- i.e. it carries non-empty access AND refresh tokens.
# Exits:
#   0  -> both accessToken and refreshToken are non-empty strings
#   1  -> either token is absent, null, non-string, or an EMPTY string
#         (nothing written to stdout)
#   2  -> python3 not available (nothing written to stdout)
#
# WHY this validator exists (issue #88, established by real-hardware testing):
# the host Keychain item "Claude Code-credentials" can hold a
# STRUCTURALLY-COMPLETE `claudeAiOauth` object whose `accessToken` and
# `refreshToken` are EMPTY STRINGS (with `expiresAt: 0`). This was observed on
# a real host whose claude sessions kept working via the shared auth daemon
# (which serves in-memory tokens) while the PERSISTED Keychain entry had gone
# degraded. claude_vm_select_claude_credential happily selects that object --
# it is a valid non-empty dict -- so the structural fail-closed contract there
# does NOT catch it. Copied into the guest, the empty credential boots claude
# to "Not logged in -- Run /login". Worse, an in-guest /login can trip OAuth
# reuse-detection and REVOKE the operator's other live sessions. So the launcher
# validates the SELECTED credential here at preflight and aborts fast, steering
# the operator to re-login on the HOST (which repairs the Keychain entry) rather
# than into the guest.
#
# Pure: no side effects beyond stdin/stdout. Does not touch the Keychain,
# the filesystem, or any host state.
claude_vm_validate_claude_credential_tokens() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "claude-vm: python3 is required to validate the claude.ai OAuth credential tokens." >&2
    return 2
  fi
  # stdin is the selected {"claudeAiOauth": {...}} object. Exit 0 iff BOTH
  # accessToken and refreshToken are non-empty strings; exit 1 otherwise. No
  # output on any path (this is a pure predicate).
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
    sys.exit(1)
access = cred.get("accessToken")
refresh = cred.get("refreshToken")
# Both must be present, string-typed, and non-empty. An empty string (the
# degraded-Keychain shape) fails here even though the object is structurally
# complete.
if not isinstance(access, str) or not access:
    sys.exit(1)
if not isinstance(refresh, str) or not refresh:
    sys.exit(1)
sys.exit(0)
'
}

# claude_vm_select_claude_json_seed <resolved-version> [host-repo-path] [guest-repo-path]
#
# Reads the host's ~/.claude.json on stdin, writes the identity seed to stdout
# (issue #88). Takes three POSITIONAL ARGUMENTS -- NOT on stdin, which is the
# host JSON:
#   $1  the concrete resolved claude version (e.g. "2.1.172")
#   $2  the absolute HOST path of the launched repo (optional)
#   $3  the fixed GUEST mount path the boot launcher cd's into, e.g.
#       "/mnt/repo" (optional)
# Exits:
#   0  -> selection succeeded; valid JSON written to stdout
#   1  -> input not valid JSON, or missing/unusable `userID` or
#         `oauthAccount` (nothing written to stdout)
#   2  -> python3 not available (nothing written to stdout)
#
# The emitted object carries the SIX base top-level keys:
#   - userID                 (from host ~/.claude.json)
#   - oauthAccount           (from host ~/.claude.json)
#   - hasCompletedOnboarding (synthesized: boolean true)
#   - autoUpdates            (synthesized: boolean false)
#   - lastOnboardingVersion  (the resolved version string passed in)
#   - lastReleaseNotesSeen   (the resolved version string passed in)
# plus, ADDITIVELY when the host doc carries them (silently omitted otherwise):
#   - installMethod          (copied verbatim from host)
#   - hasSeenTasksHint       (copied verbatim from host)
#   - hasUsedStash           (copied verbatim from host)
#   - tipsHistory            (the whole object, copied verbatim from host)
# plus, when a guest-repo-path is supplied:
#   - projects               ({ "<guest-repo-path>": <entry> }) where <entry>
#                            is the host's projects[<host-repo-path>] rekeyed to
#                            the guest path with hasTrustDialogAccepted and
#                            hasCompletedProjectOnboarding FORCED true (or a
#                            minimal synthesized entry with both flags true when
#                            the host has no such project entry)
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
# WHY the projects entry (issue #88, Gap 2): on first boot the guest TUI prompts
# "Do you trust this folder? /mnt/repo" and accepting writes
# projects."/mnt/repo".hasTrustDialogAccepted / hasCompletedProjectOnboarding.
# Seeding a projects entry for the guest mount path -- with both flags forced
# true -- skips that dialog. When the host already has a projects entry for the
# launched repo we copy it verbatim (rekeyed to the guest path) so per-project
# settings like allowedTools ride along, then force the two trust flags true.
#
# The additive pass-through keys (installMethod, hasSeenTasksHint, hasUsedStash,
# tipsHistory) carry benign host UI/onboarding state so the guest matches the
# host's dismissed-hint posture. They are ADDITIVE: absent on the host -> silently
# omitted, never a failure.
#
# machineID is DELIBERATELY OMITTED -- the guest mints its own on first run;
# seeding the host's would bind the throwaway guest to the host machine
# identity.
#
# SELECTION discipline mirrors claude_vm_select_claude_credential: the host
# ~/.claude.json carries far more than identity (projects{} for OTHER repos,
# metrics, session ids). Copying it verbatim would leak host-local state into
# the guest. So we select a NAMED allowlist of keys, rekey ONLY the launched
# repo's project entry, and synthesize the onboarding/version fields -- nothing
# else from the host survives.
#
# Fail-closed contract: invalid JSON, a non-object top level, a missing/
# non-string `userID`, or a missing/non-object `oauthAccount` all exit
# non-zero with NOTHING on stdout. The caller routes that to a friendly
# "log in to Claude Code on the host first" abort. The additive keys and the
# projects entry NEVER cause a failure. On a successful emit the two static
# booleans and the two version fields are ALWAYS present.
#
# Pure: no side effects beyond stdin/stdout/argv. Does not touch the filesystem
# or any host state.
claude_vm_select_claude_json_seed() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "claude-vm: python3 is required to select the identity seed from ~/.claude.json." >&2
    return 2
  fi
  # The resolved concrete claude version and the host/guest repo paths ride in
  # via the environment (NOT stdin -- stdin is the host JSON). An empty/unset
  # version is tolerated (the version fields then emit empty strings):
  # credential.sh has no business deciding what a "valid" version is, and the
  # real write site passes an authoritative resolved version. An empty/unset
  # guest-repo-path means the `projects` key is omitted entirely (defensive;
  # the launcher always passes it).
  #
  # json.dumps runs only after BOTH host identity keys are validated and is the
  # last statement, so a failure exits non-zero WITHOUT writing partial output.
  CLAUDE_VM_SEED_VERSION="${1:-}" \
  CLAUDE_VM_SEED_HOST_REPO_PATH="${2:-}" \
  CLAUDE_VM_SEED_GUEST_REPO_PATH="${3:-}" \
  python3 -c '
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
host_repo = os.environ.get("CLAUDE_VM_SEED_HOST_REPO_PATH", "")
guest_repo = os.environ.get("CLAUDE_VM_SEED_GUEST_REPO_PATH", "")
# Two identity keys from the host, four synthesized: two static booleans that
# skip the onboarding wall and disable self-update, two version-derived fields.
# machineID is intentionally NOT emitted -- the guest mints its own.
seed = {
    "userID": user_id,
    "oauthAccount": oauth,
    "hasCompletedOnboarding": True,
    "autoUpdates": False,
    "lastOnboardingVersion": version,
    "lastReleaseNotesSeen": version,
}
# ADDITIVE pass-through of benign host UI/onboarding keys, WHEN PRESENT. Absent
# on the host -> silently omitted; never a failure. tipsHistory rides as the
# whole object.
for key in ("installMethod", "hasSeenTasksHint", "hasUsedStash", "tipsHistory"):
    if key in doc:
        seed[key] = doc[key]
# The projects entry for the guest repo mount path (skips the trust dialog).
# Only when a guest path was supplied.
if guest_repo:
    host_projects = doc.get("projects")
    entry = None
    if isinstance(host_projects, dict) and host_repo:
        candidate = host_projects.get(host_repo)
        if isinstance(candidate, dict):
            # Copy the host entry verbatim (so per-project settings like
            # allowedTools survive), rekeyed to the guest path, then FORCE the
            # two trust flags true regardless of what the host entry carried.
            entry = dict(candidate)
    if entry is None:
        # No usable host entry -> minimal synthesized entry.
        entry = {}
    entry["hasTrustDialogAccepted"] = True
    entry["hasCompletedProjectOnboarding"] = True
    seed["projects"] = {guest_repo: entry}
sys.stdout.write(json.dumps(seed))
'
}
