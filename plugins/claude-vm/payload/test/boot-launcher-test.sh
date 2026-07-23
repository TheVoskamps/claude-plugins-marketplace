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
#                        -> do NOT power off; leave the VM up and inspectable.
#
# That decision is the whole point of the shutdown redesign, so it is worth a
# unit test. The full boot launcher does mount/credential/settings setup that
# cannot run outside a real guest, so this test exercises the DECISION FRAGMENT
# in isolation: it extracts the emitted boot launcher, slices out the tail from
# the `set +e ; "$CLAUDE_BIN" "$@"` run through the final decision, and runs
# THAT real fragment against a stubbed claude / systemctl / poweroff. So it is
# the actual emitted code deciding, not a hand-copied reimplementation.
#
# It ALSO asserts the getty drop-in the provisioner writes neutralizes the
# respawn (no leading `-` on ExecStart, Restart=no) -- the other half of the
# clean-poweroff contract (an unconditional respawn would race the poweroff).
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
# shutdown action the fragment took ("systemctl-poweroff" | "poweroff" | "none")
# and the fragment's own exit code on the second line. Runs in a subshell so
# stubs are scoped.
#
# The fragment `exec`s the shutdown command on the clean path, and `exec`
# replaces the process with an EXECUTABLE (shell functions do not apply to
# exec). So systemctl / poweroff are stubbed as real scripts on a private PATH
# dir that records which path ran to a marker file. `command -v systemctl` in
# the fragment then also resolves against that PATH: to model "systemctl
# absent", we simply do not place a systemctl stub, and point the fallback
# poweroff stub in place -- `command -v systemctl` fails, the fragment falls
# through to `exec poweroff`.
run_decision() {
  local claude_status="$1" has_systemctl="${2:-yes}"
  local marker="$WORK/action"
  local stubdir="$WORK/stubbin"
  rm -f "$marker"
  rm -rf "$stubdir"
  mkdir -p "$stubdir"

  # A fake claude that exits with the requested status.
  local claude_bin="$WORK/fake-claude.sh"
  cat > "$claude_bin" <<FAKE
#!/usr/bin/env bash
exit $claude_status
FAKE
  chmod +x "$claude_bin"

  # poweroff stub (the systemctl-absent fallback), always present.
  cat > "$stubdir/poweroff" <<STUB
#!/usr/bin/env bash
printf 'poweroff\n' > "$marker"
exit 0
STUB
  chmod +x "$stubdir/poweroff"

  # systemctl stub, present only when has_systemctl=yes so `command -v
  # systemctl` models both states honestly.
  if [ "$has_systemctl" = "yes" ]; then
    cat > "$stubdir/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl-%s\n' "\$*" > "$marker"
exit 0
STUB
    chmod +x "$stubdir/systemctl"
  fi

  (
    CLAUDE_BIN="$claude_bin"
    # Stub log() to a no-op (the real one writes /dev/console).
    log() { :; }
    # Prepend the stub dir so `command -v systemctl` and the `exec` resolve our
    # stubs first, while keeping the real system bins on PATH so the fake
    # claude's `/usr/bin/env bash` shebang still finds bash. On macOS the host
    # has no real systemctl, so has_systemctl=no (no systemctl stub placed)
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

# --- Abnormal death (137, SIGKILL): NO poweroff; VM left up. The fragment
#     returns claude's status and takes no shutdown action. ---
OUT="$(run_decision 137)"
ACTION="$(printf '%s\n' "$OUT" | sed -n '1p')"
RC="$(printf '%s\n' "$OUT" | sed -n '2p')"
assert_eq "exit 137 (abnormal) -> NO poweroff (VM left up)" "none" "$ACTION"
assert_eq "exit 137 (abnormal) -> fragment returns claude's status (137)" "137" "$RC"

# --- Another nonzero (1): still no poweroff. ---
OUT="$(run_decision 1)"
ACTION="$(printf '%s\n' "$OUT" | sed -n '1p')"
assert_eq "exit 1 (abnormal) -> NO poweroff" "none" "$ACTION"

# ---------------------------------------------------------------------
# 3. The getty drop-in the provisioner writes must neutralize the respawn:
#    NO leading `-` on the boot-launcher ExecStart, and Restart=no. An
#    unconditional respawn would race the guest's own poweroff on the clean
#    path (issue #179). Assert against the LITERAL drop-in text the provisioner
#    heredoc contains (a static heredoc, so grepping the provisioner source is
#    the faithful check without running a container build).
# ---------------------------------------------------------------------
if [ -f "$PROVISIONER" ]; then
  # The boot-launcher ExecStart line: agetty ... --login-program .../boot-launcher.sh
  EXECSTART_LINE="$(grep -E 'ExecStart=.*boot-launcher\.sh' "$PROVISIONER" | head -1)"
  assert_contains "getty drop-in has a boot-launcher ExecStart line" \
    "$EXECSTART_LINE" "boot-launcher.sh"
  # It must NOT carry the leading `-` (which made a launcher exit auto-respawn).
  assert_not_contains "getty ExecStart has no leading '-' (respawn neutralized)" \
    "$EXECSTART_LINE" "ExecStart=-/sbin/agetty"
  assert_contains "getty ExecStart runs agetty with no leading '-'" \
    "$EXECSTART_LINE" "ExecStart=/sbin/agetty"
  # And Restart=no is set explicitly in the drop-in.
  if grep -qE '^Restart=no$' "$PROVISIONER"; then
    PASS=$((PASS + 1)); echo "ok   - getty drop-in sets Restart=no"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - getty drop-in sets Restart=no"
  fi
else
  echo "SKIP: provisioner not found at $PROVISIONER; getty-respawn assertions skipped." >&2
fi

# ---------------------------------------------------------------------
echo ""
echo "boot-launcher-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
