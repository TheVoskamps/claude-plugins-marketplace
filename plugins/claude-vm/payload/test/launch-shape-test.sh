#!/usr/bin/env bash
#
# launch-shape-test.sh -- regression test for issue #179's vfkit launch shape:
# vfkit MUST run FOREGROUND.
#
# A backgrounded vfkit (`vfkit ... &` + `wait $!`) cannot attach its
# `virtio-serial,stdio` console to the terminal -- a real boot fails with
# `Error: operation not supported by device` at "Adding stdio console". That
# shape shipped once and never booted. Foreground is load-bearing: vfkit owns
# the tty, its exit status lands in the launcher's own `$?`, bash defers traps
# while a foreground child runs (so cleanup() can never face a live vfkit),
# and therefore no reap machinery may exist.
#
# These are grep-level shape assertions against the launcher SOURCE (like the
# getty drop-in assertions in podman-mkosi-test.sh) -- no VM, no network, no
# root; needs only bash + awk.
#
# Run directly:
#
#   plugins/claude-vm/payload/test/launch-shape-test.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$TEST_DIR/../claude-vm.sh"

if [ ! -f "$LAUNCHER" ]; then
  echo "SKIP: launcher not found at $LAUNCHER." >&2
  exit 0
fi

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "        $2"; }

# Slice the vfkit invocation: from the `vfkit \` command line through the
# first following non-continuation line. awk collects the invocation's lines.
VFKIT_BLOCK="$(awk '
  /^vfkit \\$/ { grab = 1 }
  grab {
    print
    if ($0 !~ /\\$/) exit
  }
' "$LAUNCHER")"

# The line AFTER the invocation (first line following the block).
AFTER_LINE="$(awk '
  /^vfkit \\$/ { grab = 1; next }
  grab && $0 !~ /\\$/ { getline nxt; print nxt; exit }
' "$LAUNCHER")"

# ---------------------------------------------------------------------
# 1. The invocation exists and is NOT backgrounded: its final line must not
#    end with `&` (allowing trailing whitespace).
# ---------------------------------------------------------------------
if [ -z "$VFKIT_BLOCK" ]; then
  bad "vfkit invocation found in launcher" "no ^vfkit \\\\ block located"
else
  ok "vfkit invocation found in launcher"
  LAST_LINE="$(printf '%s\n' "$VFKIT_BLOCK" | tail -1)"
  case "$LAST_LINE" in
    *"&"|*"& ")
      bad "vfkit runs foreground (no trailing &)" "last line: [$LAST_LINE]" ;;
    *)
      ok "vfkit runs foreground (no trailing &)" ;;
  esac
fi

# ---------------------------------------------------------------------
# 2. `VM_EXIT_STATUS=$?` immediately follows the invocation, so vfkit's real
#    status is captured from the foreground wait -- no `$!`, no `wait`.
# ---------------------------------------------------------------------
if [ "$AFTER_LINE" = 'VM_EXIT_STATUS=$?' ]; then
  ok 'VM_EXIT_STATUS=$? immediately follows the vfkit invocation'
else
  bad 'VM_EXIT_STATUS=$? immediately follows the vfkit invocation' \
      "line after invocation: [$AFTER_LINE]"
fi

# ---------------------------------------------------------------------
# 3. None of the background-era machinery survives anywhere in the launcher:
#    no VFKIT_PID, no reap functions, no REAP_ constants, no `wait "$VFKIT...`.
# ---------------------------------------------------------------------
for FORBIDDEN in 'VFKIT_PID' 'reap_vfkit' 'REAP_'; do
  if grep -q "$FORBIDDEN" "$LAUNCHER"; then
    bad "launcher contains no '$FORBIDDEN'" \
        "$(grep -n "$FORBIDDEN" "$LAUNCHER" | head -3)"
  else
    ok "launcher contains no '$FORBIDDEN'"
  fi
done

# ---------------------------------------------------------------------
# 4. VM_EXIT_STATUS is initialized to 1 (abnormal -> retain) before the
#    launch, so an interrupted path fails safe.
# ---------------------------------------------------------------------
if grep -q '^VM_EXIT_STATUS=1$' "$LAUNCHER"; then
  ok "VM_EXIT_STATUS initialized to 1 (fail-safe retain) before the launch"
else
  bad "VM_EXIT_STATUS initialized to 1 (fail-safe retain) before the launch"
fi

echo ""
echo "launch-shape-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
