#!/usr/bin/env bash
#
# reap-cleanup-test.sh -- regression test for issue #179's host-side teardown:
# the BOUNDED vfkit reap and the tty-restore ORDERING inside cleanup().
#
# Two coupled defects motivated this suite:
#
#   (a) reap_vfkit()'s bound was not a bound. It polled for a window and then
#       fell through to an UNCONDITIONAL `wait "$VFKIT_PID"`, so when the poll
#       expired with vfkit still alive the function blocked for as long as vfkit
#       lived. A bounded poll followed by an unbounded wait is unbounded.
#
#   (b) cleanup() called reap_vfkit BEFORE restore_host_tty, so a slow or hung
#       vfkit stranded the operator's terminal in raw mode (echo off, ICANON
#       off) for the whole window -- the repeatedly-observed symptom.
#
# This suite runs the REAL reap_vfkit / reap_vfkit_poll source sliced out of
# claude-vm.sh (not a reimplementation) against a stub child with a chosen
# lifetime, and asserts termination inside the promised window on every path.
# It also asserts cleanup()'s statement ORDER statically, since the ordering is
# the property that survives however the reap goes.
#
# NOTE on the stub's lifetime: the numbers below are THIS TEST's scripted stub
# lifetimes. They are not vfkit constants and must not be read as evidence about
# vfkit's own timers -- no vfkit binary is involved anywhere in this file.
#
# Run directly:
#
#   plugins/claude-vm/payload/test/reap-cleanup-test.sh
#
# Requires: bash + awk + sed (base tools). No VM, no network, no root.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$(cd "$TEST_DIR/.." && pwd)"
LAUNCHER="$PAYLOAD_DIR/claude-vm.sh"

if [ ! -f "$LAUNCHER" ]; then
  echo "SKIP: claude-vm.sh not found at $LAUNCHER." >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-reap-test.XXXXXX")"
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

assert_le() {
  local label="$1" bound="$2" actual="$3"
  if [ "$actual" -le "$bound" ]; then
    PASS=$((PASS + 1)); echo "ok   - $label (took ${actual}s, bound ${bound}s)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $label"
    echo "        expected at most: ${bound}s"
    echo "        actual:           ${actual}s"
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

# ---------------------------------------------------------------------
# 1. Slice the REAL reap functions (and their tunables) out of claude-vm.sh so
#    the tests below exercise the shipped code, not a copy. The slice runs from
#    the REAP_GRACE_TICKS assignment through the closing brace of reap_vfkit().
# ---------------------------------------------------------------------
REAP_SRC="$WORK/reap.sh"
awk '
  /^REAP_GRACE_TICKS=/ { cap=1 }
  cap { print }
  cap && /^\}$/ && seen_reap { exit }
  cap && /^reap_vfkit\(\) \{/ { seen_reap=1 }
' "$LAUNCHER" > "$REAP_SRC"

if [ ! -s "$REAP_SRC" ]; then
  FAIL=$((FAIL + 1))
  echo "FAIL - could not slice reap_vfkit out of $LAUNCHER"
  echo ""
  echo "reap-cleanup-test: $PASS passed, $FAIL failed"
  exit 1
fi

bash -n "$REAP_SRC"
assert_eq "sliced reap source is syntactically valid bash" "0" "$?"
assert_contains "slice carries reap_vfkit_poll" "$(cat "$REAP_SRC")" "reap_vfkit_poll()"
assert_contains "slice carries reap_vfkit" "$(cat "$REAP_SRC")" "reap_vfkit()"

# ---------------------------------------------------------------------
# 2. The bound must be REAL on every path. The regression being guarded is an
#    unconditional `wait` after the poll: run the real reap against a stub child
#    that outlives every rung and assert the function still returns promptly.
#
#    The rungs are shortened via the tunables so the test stays fast; that is
#    the point of them being variables. The stub child's lifetime (60s) is a
#    TEST-SCRIPTED number chosen to be far longer than the shortened rungs --
#    it says nothing about vfkit.
# ---------------------------------------------------------------------

# run_reap <stub-lifetime-seconds> <stub-exit-status> <ignore-term:yes|no>
#   -> prints "<elapsed-seconds> <VM_EXIT_STATUS>"
#
# The stub child's stdio is redirected to /dev/null and the harness writes its
# result to a FILE rather than stdout. Otherwise a long-lived stub would hold
# the command-substitution pipe open for its whole scripted lifetime and the
# test would measure the pipe, not the reap -- which would silently defeat the
# very bound this suite exists to prove.
run_reap() {
  local lifetime="$1" status="$2" ignore_term="${3:-no}"
  local stub="$WORK/stub-child.sh"
  local result="$WORK/reap-result"
  rm -f "$result"
  cat > "$stub" <<STUB
#!/usr/bin/env bash
if [ "$ignore_term" = "yes" ]; then
  trap '' TERM INT
fi
# \`sleep\` as a background child + \`wait\` so a SIGTERM this stub does NOT
# ignore is delivered promptly, instead of being queued behind a foreground
# sleep. With TERM trapped-and-ignored, this stub survives to the SIGKILL rung.
sleep $lifetime &
wait \$!
exit $status
STUB
  chmod +x "$stub"

  bash <<HARNESS
set -uo pipefail
# Shorten the rungs so the suite is fast. These are OUR tunables, exercised
# through the real function bodies.
. "$REAP_SRC"
REAP_GRACE_TICKS=5    # 0.5s
REAP_TERM_TICKS=5     # 0.5s
REAP_KILL_TICKS=5     # 0.5s
"$stub" >/dev/null 2>&1 </dev/null &
VFKIT_PID=\$!
VM_EXIT_STATUS=
start=\$(date +%s)
reap_vfkit
end=\$(date +%s)
printf '%s %s\n' "\$((end - start))" "\${VM_EXIT_STATUS}" > "$result"
HARNESS
  cat "$result" 2>/dev/null || echo "NORESULT NORESULT"
}

# --- The child exits well within rung 1: the real status is reaped. ---
OUT="$(run_reap 0 7 2>/dev/null)"
ELAPSED="${OUT%% *}"; STATUS="${OUT##* }"
assert_eq "child that exits promptly -> its REAL status is recorded" "7" "$STATUS"
assert_le "prompt child: reap returns quickly" 3 "$ELAPSED"

# --- The child exits 0 (the clean guest-poweroff shape). ---
OUT="$(run_reap 0 0 2>/dev/null)"
STATUS="${OUT##* }"
assert_eq "child that exits 0 -> status 0 (routes to DISCARD the clone)" "0" "$STATUS"

# --- The child OUTLIVES rung 1 but dies to the SIGTERM escalation. This is the
#     case the old shape handled by blocking in `wait` for the child's whole
#     scripted lifetime. The bound must now cut it short. ---
OUT="$(run_reap 60 0 no 2>/dev/null)"
ELAPSED="${OUT%% *}"; STATUS="${OUT##* }"
assert_le "child outliving rung 1 -> reap still returns in bounded time" 5 "$ELAPSED"
# SIGTERM-killed: the recorded status is a signal status (128+15) or the
# synthetic give-up status; either way NONZERO, which routes to RETAIN.
if [ "${STATUS:-}" != "0" ] && [ -n "${STATUS:-}" ]; then
  PASS=$((PASS + 1)); echo "ok   - signalled child -> nonzero status (routes to RETAIN the clone)"
else
  FAIL=$((FAIL + 1)); echo "FAIL - signalled child -> nonzero status (got [$STATUS])"
fi

# --- The child IGNORES SIGTERM: rung 3 (SIGKILL) must finish it, and the reap
#     must STILL return in bounded time. This is the worst realistic path. ---
OUT="$(run_reap 60 0 yes 2>/dev/null)"
ELAPSED="${OUT%% *}"; STATUS="${OUT##* }"
assert_le "SIGTERM-ignoring child -> reap STILL returns in bounded time" 6 "$ELAPSED"
if [ "${STATUS:-}" != "0" ] && [ -n "${STATUS:-}" ]; then
  PASS=$((PASS + 1)); echo "ok   - SIGTERM-ignoring child -> nonzero status (routes to RETAIN)"
else
  FAIL=$((FAIL + 1)); echo "FAIL - SIGTERM-ignoring child -> nonzero status (got [$STATUS])"
fi

# --- THE GIVE-UP PATH: every rung expires with the child STILL ALIVE. This is
#     the exact shape the old code hung on (its unconditional `wait` blocked for
#     the child's whole remaining lifetime). Modelled by shadowing `kill` with a
#     function that reports "alive" for `kill -0` and swallows the signals, so
#     no rung can ever succeed. The reap must return anyway, promptly, with the
#     synthetic nonzero give-up status -- never blocking on `wait`. ---
GIVEUP_RESULT="$WORK/giveup-result"
rm -f "$GIVEUP_RESULT"
cat > "$WORK/immortal.sh" <<'IMMORTAL'
#!/usr/bin/env bash
sleep 60 &
wait $!
IMMORTAL
chmod +x "$WORK/immortal.sh"
bash <<GIVEUP >/dev/null 2>&1
set -uo pipefail
. "$REAP_SRC"
REAP_GRACE_TICKS=3
REAP_TERM_TICKS=3
REAP_KILL_TICKS=3
# Shadow \`kill\`: \`kill -0\` always succeeds (the child looks immortal) and
# every real signal is swallowed, so all three rungs expire.
kill() {
  case "\${1:-}" in
    -0) return 0 ;;
    *)  return 0 ;;
  esac
}
"$WORK/immortal.sh" >/dev/null 2>&1 </dev/null &
VFKIT_PID=\$!
VM_EXIT_STATUS=
start=\$(date +%s)
reap_vfkit
end=\$(date +%s)
printf '%s %s\n' "\$((end - start))" "\${VM_EXIT_STATUS}" > "$GIVEUP_RESULT"
# Really clean up the immortal stub now that the measurement is done.
command kill -9 \$VFKIT_PID 2>/dev/null || true
GIVEUP
GIVEUP_OUT="$(cat "$GIVEUP_RESULT" 2>/dev/null || echo "NORESULT NORESULT")"
GIVEUP_ELAPSED="${GIVEUP_OUT%% *}"; GIVEUP_STATUS_OBSERVED="${GIVEUP_OUT##* }"
if [ "$GIVEUP_ELAPSED" = "NORESULT" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL - give-up path: reap never returned (the bound is NOT real)"
else
  assert_le "give-up path: reap returns even when the child never dies" 5 "$GIVEUP_ELAPSED"
  # Compare against the value declared in the SOURCE, not a duplicated literal,
  # so retuning REAP_UNREAPED_STATUS does not need a test edit.
  EXPECTED_GIVEUP="$(sed -n 's/^REAP_UNREAPED_STATUS=\([0-9][0-9]*\)$/\1/p' "$REAP_SRC" | head -1)"
  assert_eq "give-up path: records the synthetic nonzero status (-> RETAIN)" \
    "$EXPECTED_GIVEUP" "$GIVEUP_STATUS_OBSERVED"
fi

# --- No VFKIT_PID at all (a signal fired before vfkit launched): a no-op. ---
NOPID_OUT="$(bash -c '
  set -uo pipefail
  . "'"$REAP_SRC"'"
  VFKIT_PID=""
  VM_EXIT_STATUS=sentinel
  reap_vfkit
  echo "rc=$? status=$VM_EXIT_STATUS"
' 2>/dev/null)"
assert_eq "empty VFKIT_PID -> no-op, status untouched" "rc=0 status=sentinel" "$NOPID_OUT"

# ---------------------------------------------------------------------
# 3. Structural guard: the regression that made the bound fake was an
#    UNCONDITIONAL `wait` reached after the poll expired. Assert that the only
#    blocking `wait` in reap_vfkit sits behind the "vfkit is confirmed gone"
#    branch, i.e. that the give-up path returns BEFORE any `wait`.
# ---------------------------------------------------------------------
GIVEUP_LINE="$(grep -n 'VM_EXIT_STATUS=\$REAP_UNREAPED_STATUS' "$REAP_SRC" | head -1 | cut -d: -f1)"
WAIT_LINE="$(grep -n '^  wait "\$VFKIT_PID"' "$REAP_SRC" | head -1 | cut -d: -f1)"
if [ -n "$GIVEUP_LINE" ] && [ -n "$WAIT_LINE" ] && [ "$GIVEUP_LINE" -lt "$WAIT_LINE" ]; then
  PASS=$((PASS + 1)); echo "ok   - the give-up path returns BEFORE the blocking wait (the bound is real)"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - the give-up path must return before the blocking wait"
  echo "        give-up line: [${GIVEUP_LINE:-none}] wait line: [${WAIT_LINE:-none}]"
fi
# And the give-up status must be NONZERO, so an unreaped vfkit routes to RETAIN
# (the guest may still be writing to the clone; discarding it would be wrong).
GIVEUP_STATUS="$(sed -n 's/^REAP_UNREAPED_STATUS=\([0-9][0-9]*\)$/\1/p' "$REAP_SRC" | head -1)"
if [ -n "$GIVEUP_STATUS" ] && [ "$GIVEUP_STATUS" -ne 0 ]; then
  PASS=$((PASS + 1)); echo "ok   - the give-up status is nonzero (unreaped vfkit -> RETAIN the clone)"
else
  FAIL=$((FAIL + 1)); echo "FAIL - the give-up status must be nonzero (got [${GIVEUP_STATUS:-none}])"
fi

# ---------------------------------------------------------------------
# 4. cleanup() ORDERING: restore_host_tty must run BEFORE reap_vfkit, so the
#    operator's terminal is back in canonical mode no matter how the reap goes.
#    Asserted on the real source's statement order (the ordering is the whole
#    property; running cleanup() end-to-end would need a live vfkit + tty).
# ---------------------------------------------------------------------
CLEANUP_BODY="$WORK/cleanup-body.sh"
awk '
  /^cleanup\(\) \{/ { cap=1 }
  cap { print }
  cap && /^\}$/ { exit }
' "$LAUNCHER" > "$CLEANUP_BODY"

if [ ! -s "$CLEANUP_BODY" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL - could not slice cleanup() out of $LAUNCHER"
else
  FIRST_RESTORE="$(grep -n '^  restore_host_tty$' "$CLEANUP_BODY" | head -1 | cut -d: -f1)"
  REAP_CALL="$(grep -n '^  reap_vfkit$' "$CLEANUP_BODY" | head -1 | cut -d: -f1)"
  if [ -n "$FIRST_RESTORE" ] && [ -n "$REAP_CALL" ] && [ "$FIRST_RESTORE" -lt "$REAP_CALL" ]; then
    PASS=$((PASS + 1)); echo "ok   - cleanup() restores the host tty BEFORE reaping vfkit"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - cleanup() must restore the host tty BEFORE reaping vfkit"
    echo "        restore line: [${FIRST_RESTORE:-none}] reap line: [${REAP_CALL:-none}]"
  fi

  # It must ALSO re-assert the restore after the reap: a vfkit alive across the
  # reap window can re-corrupt the termios state. restore_host_tty is idempotent.
  RESTORE_COUNT="$(grep -c '^  restore_host_tty$' "$CLEANUP_BODY")"
  if [ "$RESTORE_COUNT" -ge 2 ]; then
    PASS=$((PASS + 1)); echo "ok   - cleanup() re-asserts the tty restore after the reap"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - cleanup() must restore the tty on both sides of the reap (found $RESTORE_COUNT call(s))"
  fi

  # The discard-vs-retain decision must still key on vfkit's REAL exit status,
  # read AFTER the reap -- moving the tty restore earlier must not have moved
  # the decision above the reap that establishes the status.
  DECISION="$(grep -n 'VM_EXIT_STATUS:-' "$CLEANUP_BODY" | head -1 | cut -d: -f1)"
  if [ -n "$DECISION" ] && [ -n "$REAP_CALL" ] && [ "$DECISION" -gt "$REAP_CALL" ]; then
    PASS=$((PASS + 1)); echo "ok   - the discard/retain decision still reads VM_EXIT_STATUS after the reap"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - the discard/retain decision must read VM_EXIT_STATUS after the reap"
    echo "        decision line: [${DECISION:-none}] reap line: [${REAP_CALL:-none}]"
  fi

  # sync must still precede the reap (flush writes in flight to the clone).
  SYNC_LINE="$(grep -n '^  sync ' "$CLEANUP_BODY" | head -1 | cut -d: -f1)"
  if [ -n "$SYNC_LINE" ] && [ -n "$REAP_CALL" ] && [ "$SYNC_LINE" -lt "$REAP_CALL" ]; then
    PASS=$((PASS + 1)); echo "ok   - cleanup() still syncs before the reap"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - cleanup() must sync before the reap"
  fi
fi

# ---------------------------------------------------------------------
echo ""
echo "reap-cleanup-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
