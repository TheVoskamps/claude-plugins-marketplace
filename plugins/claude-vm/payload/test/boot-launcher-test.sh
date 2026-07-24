#!/usr/bin/env bash
#
# boot-launcher-test.sh -- regression test for issue #179's guest-side
# self-poweroff decision, the core of the redesigned shutdown model.
#
# The guest boot launcher (emitted by build-guest-image.sh's
# emit_boot_launcher) runs claude ONCE as a child, captures its exit status,
# and decides:
#   - claude exit 0 (a DELIBERATE quit -- Ctrl-D Ctrl-D, /exit, Ctrl-C Ctrl-C
#     all verified 0)   -> power the guest off (systemctl poweroff / poweroff),
#   - claude exit nonzero (ABNORMAL, e.g. SIGKILL -> 137)
#                        -> do NOT power off; `exec` an interactive root LOGIN
#                           SHELL on the same hvc1 console so the operator can
#                           run a post-mortem inside the still-running guest.
#
# The nonzero branch is the loop-sensitive one: it must hand off to a PLAIN
# LOGIN SHELL and must NOT re-enter the boot launcher (which would rerun claude,
# possibly die identically, and rebuild the respawn loop this redesign removed).
# The tests below assert both halves of that -- the handoff IS a shell, and the
# handoff is NOT the launcher.
#
# That decision is the whole point of the shutdown redesign, so it is worth a
# unit test. The full boot launcher does mount/credential/settings setup that
# cannot run outside a real guest, so this test exercises the DECISION FRAGMENT
# in isolation: it extracts the emitted boot launcher, slices out the tail from
# the `set +e ; "$CLAUDE_BIN" "$@"` run through the final decision, and runs
# THAT real fragment against a stubbed claude / systemctl / poweroff / bash. So
# it is the actual emitted code deciding, not a hand-copied reimplementation.
#
# It ALSO asserts the getty drop-in the provisioner writes neutralizes the
# respawn via `Restart=no` -- the other half of the clean-poweroff contract (an
# unconditional respawn would race the poweroff on the clean path and re-loop
# claude on the abnormal path). Note the MECHANISM: the respawn comes from
# `Restart=` in the stock serial-getty@.service template (`Restart=always`),
# which the drop-in overrides to `no`. The leading `-` on ExecStart is dropped
# too, but that prefix only makes a nonzero exit be reported as success -- it
# never governed the respawn.
#
# Finally it asserts LAUNCHER_LOGIC_REV moved off 16: the image-identity hash
# covers only the bake CONFIG files plus the repo name, never the launcher
# source, so this constant is the sole mechanism invalidating a cached image
# when the launcher logic changes.
#
# Run directly:
#
#   plugins/claude-vm/payload/test/boot-launcher-test.sh
#
# Requires: bash + awk (base tools). No VM, no network, no root.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$(cd "$TEST_DIR/.." && pwd)"
BUILD="$PAYLOAD_DIR/build-guest-image.sh"
PROVISIONER="$PAYLOAD_DIR/provisioners/podman-mkosi.sh"

if [ ! -f "$BUILD" ]; then
  echo "SKIP: build-guest-image.sh not found at $BUILD." >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-bootlaunch-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); echo "ok   - $label"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $label"
    echo "        expected: [$expected]"
    echo "        actual:   [$actual]"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) PASS=$((PASS + 1)); echo "ok   - $label" ;;
    *)           FAIL=$((FAIL + 1)); echo "FAIL - $label"
                 echo "        expected to contain: [$needle]" ;;
  esac
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) FAIL=$((FAIL + 1)); echo "FAIL - $label"
                 echo "        expected NOT to contain: [$needle]" ;;
    *)           PASS=$((PASS + 1)); echo "ok   - $label" ;;
  esac
}

# ---------------------------------------------------------------------
# 1. Extract the emitted boot launcher from build-guest-image.sh. It is a
#    `cat <<'BOOT' ... BOOT` heredoc inside emit_boot_launcher(); slice the
#    heredoc body out verbatim.
# ---------------------------------------------------------------------
LAUNCHER="$WORK/boot-launcher.sh"
awk '
  /^emit_boot_launcher\(\) \{/ { in_fn=1 }
  in_fn && /cat <<.BOOT.$/ { cap=1; next }
  cap && /^BOOT$/ { cap=0; in_fn=0 }
  cap { print }
' "$BUILD" > "$LAUNCHER"

if [ ! -s "$LAUNCHER" ]; then
  FAIL=$((FAIL + 1))
  echo "FAIL - could not extract the emitted boot launcher from $BUILD"
  echo ""
  echo "boot-launcher-test: $PASS passed, $FAIL failed"
  exit 1
fi

# The whole emitted launcher must be syntactically valid bash.
bash -n "$LAUNCHER"
assert_eq "emitted boot launcher is syntactically valid bash" "0" "$?"

# It must NOT bare-`exec claude` any longer (that would discard the exit
# status the decision depends on). It must run claude as a child and branch
# on the status.
assert_not_contains "emitted launcher no longer ends with 'exec \"\$CLAUDE_BIN\"'" \
  "$(cat "$LAUNCHER")" 'exec "$CLAUDE_BIN"'
assert_contains "emitted launcher captures claude's exit status" \
  "$(cat "$LAUNCHER")" 'CLAUDE_STATUS=$?'
assert_contains "emitted launcher powers off via systemctl on the clean path" \
  "$(cat "$LAUNCHER")" 'systemctl poweroff'
assert_contains "emitted launcher execs a login shell on the abnormal path" \
  "$(cat "$LAUNCHER")" 'exec bash -l'

# NON-LOOPING (the loop-sensitive assertion). The abnormal path must hand off to
# a plain login SHELL and must never re-enter the boot launcher itself -- an
# `exec .../boot-launcher.sh` (or a self-re-exec via "$0") would rerun claude,
# possibly die identically, and rebuild the respawn loop this redesign removed.
# There is exactly one launcher process, and on the abnormal path it is REPLACED
# by the shell, so nothing can re-enter this script.
assert_not_contains "emitted launcher never re-execs the boot launcher (no loop)" \
  "$(cat "$LAUNCHER")" 'boot-launcher.sh'
assert_not_contains "emitted launcher never re-execs itself via \$0 (no loop)" \
  "$(cat "$LAUNCHER")" 'exec "$0"'

# ---------------------------------------------------------------------
# 2. Slice the DECISION FRAGMENT (from the `set +e` that guards the claude run
#    through the final `exit "$CLAUDE_STATUS"`) into a standalone script, and
#    run that real fragment against stubs. `log`, `command`, `systemctl`, and
#    `poweroff` are stubbed; `$CLAUDE_BIN`/`$@` are set so the fragment's
#    `"$CLAUDE_BIN" "$@"` runs a fake claude that exits with a chosen status.
#    We record which shutdown path the fragment took via a marker file.
# ---------------------------------------------------------------------
FRAGMENT="$WORK/decision-fragment.sh"
awk '
  /^set \+e$/ { cap=1 }
  cap { print }
  cap && /^exit "\$CLAUDE_STATUS"$/ { exit }
' "$LAUNCHER" > "$FRAGMENT"

if [ ! -s "$FRAGMENT" ]; then
  FAIL=$((FAIL + 1))
  echo "FAIL - could not slice the decision fragment out of the emitted launcher"
  echo ""
  echo "boot-launcher-test: $PASS passed, $FAIL failed"
  exit 1
fi
bash -n "$FRAGMENT"
assert_eq "decision fragment is syntactically valid bash" "0" "$?"

# run_decision <claude-exit-status> [has_systemctl=yes|no] -> prints the
# action the fragment took ("systemctl-poweroff" | "poweroff" | "shell-<argv>" |
# "none") and the fragment's own exit code on the second line. Runs in a
# subshell so stubs are scoped.
#
# The fragment `exec`s its terminal action on BOTH branches (shutdown command on
# the clean path, login shell on the abnormal path), and `exec` replaces the
# process with an EXECUTABLE (shell functions do not apply to exec). So
# systemctl / poweroff / bash are stubbed as real scripts on a private PATH dir
# that record which path ran to a marker file. `command -v systemctl` and
# `command -v bash` in the fragment then also resolve against that PATH: to
# model "systemctl absent", we simply do not place a systemctl stub -- `command
# -v systemctl` fails and the fragment falls through to `exec poweroff`.
#
# The `bash` stub is what makes the abnormal path observable: it records the
# argv it was exec'd with (expected `-l`, i.e. a plain LOGIN SHELL) so the test
# can assert the handoff is a shell and not a relaunch of anything. The fake
# claude therefore uses a `/bin/sh` shebang, not `/usr/bin/env bash`, so the
# bash stub never accidentally intercepts claude itself.
run_decision() {
  local claude_status="$1" has_systemctl="${2:-yes}"
  local marker="$WORK/action"
  local stubdir="$WORK/stubbin"
  rm -f "$marker"
  rm -rf "$stubdir"
  mkdir -p "$stubdir"

  # A fake claude that exits with the requested status. `/bin/sh` shebang so the
  # `bash` stub below cannot intercept it.
  local claude_bin="$WORK/fake-claude.sh"
  cat > "$claude_bin" <<FAKE
#!/bin/sh
exit $claude_status
FAKE
  chmod +x "$claude_bin"

  # poweroff stub (the systemctl-absent fallback), always present.
  cat > "$stubdir/poweroff" <<STUB
#!/bin/sh
printf 'poweroff\n' > "$marker"
exit 0
STUB
  chmod +x "$stubdir/poweroff"

  # bash stub: stands in for the interactive root login shell the abnormal path
  # `exec`s. Records its argv so the test can assert it was invoked as a plain
  # login shell (`-l`) rather than as a re-entry into anything.
  cat > "$stubdir/bash" <<STUB
#!/bin/sh
printf 'shell-%s\n' "\$*" > "$marker"
exit 0
STUB
  chmod +x "$stubdir/bash"

  # systemctl stub, present only when has_systemctl=yes so `command -v
  # systemctl` models both states honestly.
  if [ "$has_systemctl" = "yes" ]; then
    cat > "$stubdir/systemctl" <<STUB
#!/bin/sh
printf 'systemctl-%s\n' "\$*" > "$marker"
exit 0
STUB
    chmod +x "$stubdir/systemctl"
  fi

  (
    CLAUDE_BIN="$claude_bin"
    # The abnormal path echoes the workspace path; give it a value so the
    # fragment does not trip on an unset var under the launcher's `set -u`.
    REPO_MNT="/mnt/repo"
    # Stub log() to a no-op (the real one writes /dev/console).
    log() { :; }
    # Prepend the stub dir so `command -v systemctl` / `command -v bash` and the
    # `exec`s resolve our stubs first, while keeping the real system bins on
    # PATH so the fake claude's `/bin/sh` shebang still resolves. On macOS the
    # host has no real systemctl, so has_systemctl=no (no systemctl stub placed)
    # faithfully models "systemctl absent" and the fragment falls back to
    # `exec poweroff` -- our poweroff stub, first on PATH.
    PATH="$stubdir:$PATH"
    set -- # zero argv, like an empty CLAUDE_ARGS
    # shellcheck disable=SC1090
    . "$FRAGMENT"
  ) 2>/dev/null
  local frag_rc=$?
  if [ -f "$marker" ]; then
    cat "$marker"
  else
    echo "none"
  fi
  echo "$frag_rc"
}

# --- Clean quit (exit 0): the guest powers off via systemctl. ---
OUT="$(run_decision 0)"
ACTION="$(printf '%s\n' "$OUT" | sed -n '1p')"
assert_eq "exit 0 (deliberate quit) -> systemctl poweroff" "systemctl-poweroff" "$ACTION"

# --- Clean quit with systemctl absent: falls back to poweroff(8). ---
OUT="$(run_decision 0 no)"
ACTION="$(printf '%s\n' "$OUT" | sed -n '1p')"
assert_eq "exit 0 with no systemctl -> poweroff(8) fallback" "poweroff" "$ACTION"

# --- Abnormal death (137, SIGKILL): NO poweroff. The fragment `exec`s an
#     interactive root LOGIN SHELL on the same console so the operator can run
#     a post-mortem in the still-running guest. `exec bash -l` -> our bash stub
#     records "shell--l". Crucially the handoff is a SHELL, not a relaunch. ---
OUT="$(run_decision 137)"
ACTION="$(printf '%s\n' "$OUT" | sed -n '1p')"
assert_eq "exit 137 (abnormal) -> execs a login shell (no poweroff)" "shell--l" "$ACTION"

# --- Another nonzero (1): same shell handoff, still no poweroff. ---
OUT="$(run_decision 1)"
ACTION="$(printf '%s\n' "$OUT" | sed -n '1p')"
assert_eq "exit 1 (abnormal) -> execs a login shell (no poweroff)" "shell--l" "$ACTION"

# --- The abnormal path must never take a SHUTDOWN action. Asserted separately
#     from the positive check above so a future regression that both powers off
#     AND spawns a shell cannot hide behind the shell marker. ---
case "$ACTION" in
  systemctl-*|poweroff)
    FAIL=$((FAIL + 1)); echo "FAIL - abnormal exit must not power the guest off (got [$ACTION])" ;;
  *)
    PASS=$((PASS + 1)); echo "ok   - abnormal exit takes no shutdown action" ;;
esac

# --- NON-LOOPING: the handoff must be a plain login shell, never the boot
#     launcher. If the abnormal path re-entered the launcher, claude would rerun
#     and could die identically -- exactly the respawn loop this redesign
#     removed. The stub records the argv it was exec'd with, so a handoff that
#     smuggled a launcher path or a `-c` re-entry in would be visible here. ---
case "$ACTION" in
  *boot-launcher*|*-c*)
    FAIL=$((FAIL + 1)); echo "FAIL - abnormal handoff must be a plain login shell, not a relaunch (got [$ACTION])" ;;
  shell-*)
    PASS=$((PASS + 1)); echo "ok   - abnormal handoff is a plain login shell (cannot loop)" ;;
  *)
    FAIL=$((FAIL + 1)); echo "FAIL - abnormal handoff is not a shell at all (got [$ACTION])" ;;
esac

# ---------------------------------------------------------------------
# 3. The getty drop-in the provisioner writes must neutralize the respawn via
#    `Restart=no`. MECHANISM: the stock serial-getty@.service template sets
#    `Restart=always`; overriding it to `no` in the drop-in is the ONLY thing
#    that stops systemd restarting the unit when the boot launcher exits. The
#    leading `-` is dropped from ExecStart too, but that prefix only makes a
#    nonzero exit be reported as success -- it never governed the respawn, so
#    it is asserted as a separate, independently-motivated property. An
#    unconditional respawn would race the guest's own poweroff on the clean path
#    and re-loop claude on the abnormal path (issue #179). Assert against the
#    LITERAL drop-in text the provisioner heredoc contains (a static heredoc, so
#    grepping the provisioner source is the faithful check without running a
#    container build).
# ---------------------------------------------------------------------
if [ -f "$PROVISIONER" ]; then
  # The boot-launcher ExecStart line: agetty ... --login-program .../boot-launcher.sh
  EXECSTART_LINE="$(grep -E 'ExecStart=.*boot-launcher\.sh' "$PROVISIONER" | head -1)"
  assert_contains "getty drop-in has a boot-launcher ExecStart line" \
    "$EXECSTART_LINE" "boot-launcher.sh"
  # Restart=no is what actually neutralizes the respawn.
  if grep -qE '^Restart=no$' "$PROVISIONER"; then
    PASS=$((PASS + 1)); echo "ok   - getty drop-in sets Restart=no (this is what neutralizes the respawn)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - getty drop-in sets Restart=no (this is what neutralizes the respawn)"
  fi
  # The leading `-` is separately absent, so a nonzero launcher exit marks the
  # unit failed rather than being reported as success. Inert here (no
  # OnFailure=/FailureAction= is set), but pinned so it does not drift back.
  assert_not_contains "getty ExecStart has no leading '-' (nonzero exit marks the unit failed)" \
    "$EXECSTART_LINE" "ExecStart=-/sbin/agetty"
  assert_contains "getty ExecStart runs agetty with no leading '-'" \
    "$EXECSTART_LINE" "ExecStart=/sbin/agetty"
  # A failed getty unit must stay inert: no OnFailure=/FailureAction= anywhere,
  # so the VM stays up (what the abnormal path wants) instead of being torn down.
  if grep -qE '^[[:space:]]*(OnFailure|FailureAction)=' "$PROVISIONER"; then
    FAIL=$((FAIL + 1)); echo "FAIL - provisioner sets no OnFailure=/FailureAction= (a failed getty must stay inert)"
  else
    PASS=$((PASS + 1)); echo "ok   - provisioner sets no OnFailure=/FailureAction= (a failed getty stays inert)"
  fi
  # The getty must start the boot launcher exactly ONCE, as agetty's
  # --login-program. Any second ExecStart naming the launcher would be an
  # independent re-exec path and could reintroduce the loop.
  LAUNCHER_EXECSTARTS="$(grep -cE '^ExecStart=.*boot-launcher\.sh' "$PROVISIONER")"
  assert_eq "getty drop-in starts the boot launcher exactly once (no independent re-exec)" \
    "1" "$LAUNCHER_EXECSTARTS"
else
  echo "SKIP: provisioner not found at $PROVISIONER; getty-respawn assertions skipped." >&2
fi

# ---------------------------------------------------------------------
# 4. LAUNCHER_LOGIC_REV must have moved off 16 (issue #179 review, High).
#    The image-identity hash (claude_vm_image_identity_segments in
#    lib/config.sh) is computed from the two bake CONFIG files plus the repo
#    name -- it has NO launcher-source input. So this constant is the only
#    mechanism that invalidates a cached image when the launcher logic changes.
#    Left at 16, a cached image stamped 'launcher16' (built from main) would be
#    reused carrying the OLD `exec claude` launcher and the OLD respawning
#    getty, silently defeating the whole redesign.
# ---------------------------------------------------------------------
REV="$(sed -n 's/^LAUNCHER_LOGIC_REV="\([0-9][0-9]*\)"$/\1/p' "$BUILD" | head -1)"
if [ -z "$REV" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL - could not read LAUNCHER_LOGIC_REV from $BUILD"
elif [ "$REV" -gt 16 ]; then
  PASS=$((PASS + 1)); echo "ok   - LAUNCHER_LOGIC_REV bumped past 16 (now $REV; cached launcher16 images cannot be reused)"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - LAUNCHER_LOGIC_REV must be > 16 for the self-poweroff/shell-handoff launcher (got $REV)"
fi
# The composite the launcher compares against must be built from that rev, so a
# bump actually reaches the cache key.
assert_contains "BASE_PINNED_VERSION is built from LAUNCHER_LOGIC_REV" \
  "$(cat "$BUILD")" 'BASE_PINNED_VERSION="${BASE_OS_REV}+launcher${LAUNCHER_LOGIC_REV}"'

# ---------------------------------------------------------------------
echo ""
echo "boot-launcher-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
