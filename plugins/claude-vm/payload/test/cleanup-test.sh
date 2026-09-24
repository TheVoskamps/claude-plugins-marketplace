#!/usr/bin/env bash
#
# cleanup-test.sh -- tests for a run's liveness lock and for
# bin/claude-vm-cleanup, which reaps dead runs by it.
#
# Four parts, none booting a VM:
#
#   1. The launcher's own run-dir + lock lines, sliced out of claude-vm.sh and
#      run in a harness process: a non-blocking test-acquire of run.lock
#      exits 75 while the harness lives and succeeds after `kill -9` of it.
#   2. The launcher's proxy and gvproxy spawn lines, sliced the same way with
#      a sleeping stand-in for each process: the pid recorded for the proxy is
#      the proxy's own, and a child still running after its launcher is killed
#      does not keep the lock held.
#   3. The launcher's vfkit launch, sliced the same way with a sleeping
#      stand-in for vfkit: after `kill -9` of the launcher its watcher stops
#      vfkit, gvproxy and the proxy, and the lock test-acquire succeeds; a
#      pid whose recorded start time it no longer carries is left running.
#   4. bin/claude-vm-cleanup over a runs root holding a dead run, a live run
#      of the same repo_src, a run with no lock file, a run that exited
#      normally and runs whose recorded pids now name other processes, with
#      real processes standing in for the recorded pids.
#
# Run directly:
#
#   plugins/claude-vm/payload/test/cleanup-test.sh
#
# Requires: /usr/bin/lockf (base macOS). Skips cleanly if absent.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../lib/config.sh"
LAUNCHER="$TEST_DIR/../claude-vm.sh"
CLEANER="$TEST_DIR/../../bin/claude-vm-cleanup"

if [ ! -x /usr/bin/lockf ]; then
  echo "SKIP: /usr/bin/lockf not available; cleanup tests skipped." >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-cleanup-test.XXXXXX")"
# Every process this suite starts, so a failure never leaves one behind.
SPAWNED=()
cleanup_test() {
  local p
  for p in ${SPAWNED[@]+"${SPAWNED[@]}"}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup_test EXIT

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

# lock_probe <lock-file> -- lockf's exit status for a non-blocking
# test-acquire of <lock-file>: 75 when another process holds it, 0 when it
# was free. -k keeps the file, as the cleaner's own test does.
lock_probe() {
  /usr/bin/lockf -s -k -t 0 "$1" true
  echo $?
}

# alive <pid> -- "alive" or "dead".
alive() {
  if kill -0 "$1" 2>/dev/null; then echo alive; else echo dead; fi
}

# pid_start <pid> -- lib/config.sh's claude_vm_pid_start, sourced in a subshell
# so this shell's environment is left alone.
pid_start() {
  # shellcheck source=../lib/config.sh
  (. "$LIB" && claude_vm_pid_start "$1")
}

# track_pids <file> -- add every pid listed in <file>, one per line, to
# SPAWNED.
track_pids() {
  local p
  [ -f "$1" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] && SPAWNED+=("$p")
  done < "$1"
}

# wait_for_file <path> -- poll up to 5s for <path> to exist and be non-empty.
wait_for_file() {
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------
# 1. The launcher holds the lock for its lifetime, and kill -9 drops it.
# ---------------------------------------------------------------------
LOCK_START="$(grep -n '^RUN="\$CLAUDE_VM_RUNS_DIR/\$RUN_ID"$' "$LAUNCHER" | head -1 | cut -d: -f1)"
LOCK_END=""
if [ -n "$LOCK_START" ]; then
  LOCK_END="$(awk -v s="$LOCK_START" 'NR > s && /^fi$/ { print NR; exit }' "$LAUNCHER")"
fi

# write_holder <out> <extra-file> -- a harness running the sliced run-dir +
# lock lines under the launcher's own `set -euo pipefail`, then <extra-file>'s
# lines (sliced spawn lines, or nothing), then idling in the `wait` builtin so
# the harness shell itself is the lock holder. Prints the run dir to $2 of the
# harness once locked, and appends the pid of the sleep it idles on to $3; that
# sleep is started with fd 9 closed so only the harness holds the lock.
write_holder() {
  local out="$1" extra="$2"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf '. %s\n' "\"$LIB\""
    echo 'RUN_ID="$1"'
    awk -v s="$LOCK_START" -v e="$LOCK_END" 'NR >= s && NR <= e' "$LAUNCHER"
    [ -n "$extra" ] && cat "$extra"
    echo 'printf "%s\n" "$RUN" > "$2"'
    echo 'sleep 300 9>&- >/dev/null 2>&1 &'
    echo 'echo $! >> "$3"'
    echo 'wait'
  } > "$out"
}

if [ -n "$LOCK_START" ] && [ -n "$LOCK_END" ]; then
  export CLAUDE_VM_RUNS_DIR="$WORK/runs-lock"
  HOLDER="$WORK/holder.sh"
  write_holder "$HOLDER" ""

  bash "$HOLDER" run-a "$WORK/a.ready" "$WORK/a.pids" &
  HOLDER_PID=$!
  SPAWNED+=("$HOLDER_PID")
  wait_for_file "$WORK/a.ready"
  RUN_A="$(cat "$WORK/a.ready" 2>/dev/null)"
  track_pids "$WORK/a.pids"

  assert_eq "run dir: created under \$CLAUDE_VM_RUNS_DIR/<run-id>" \
    "$CLAUDE_VM_RUNS_DIR/run-a" "$RUN_A"
  assert_eq "lock: a non-blocking test-acquire exits 75 while the launcher runs" \
    "75" "$(lock_probe "$RUN_A/run.lock")"
  kill -9 "$HOLDER_PID"
  wait "$HOLDER_PID" 2>/dev/null
  assert_eq "lock: the test-acquire succeeds after kill -9 of the launcher" \
    "0" "$(lock_probe "$RUN_A/run.lock")"

  # A second launch drawing the same run id fails on the leaf mkdir rather
  # than sharing the first run's dir.
  bash "$HOLDER" run-a "$WORK/a2.ready" "$WORK/a2.pids" >/dev/null 2>&1
  assert_eq "run dir: a colliding run id aborts instead of reusing the dir" \
    "1" "$?"

  # A launch whose run dir's lock is already held -- the cleaner mid-reap --
  # aborts rather than run in it. The dir is pre-made, so the slice's leaf
  # mkdir is swapped for a no-op on this copy only.
  HOLDER_NOMKDIR="$WORK/holder-nomkdir.sh"
  awk '$0 == "mkdir \"$RUN\"" { print ":"; next } { print }' "$HOLDER" > "$HOLDER_NOMKDIR"
  mkdir -p "$CLAUDE_VM_RUNS_DIR/run-b"
  : > "$CLAUDE_VM_RUNS_DIR/run-b/run.lock"
  bash -c 'exec 9>>"$1"; /usr/bin/lockf -s -t 0 9 && exec sleep 300' _ "$CLAUDE_VM_RUNS_DIR/run-b/run.lock" >/dev/null 2>&1 &
  BLOCKER_PID=$!
  SPAWNED+=("$BLOCKER_PID")
  sleep 0.3
  NOMKDIR_OUT="$(bash "$HOLDER_NOMKDIR" run-b "$WORK/b.ready" "$WORK/b.pids" 2>&1)"
  NOMKDIR_RC=$?
  assert_eq "lock: a launch finding its lock already held aborts" "1" "$NOMKDIR_RC"
  assert_eq "lock: ...and says the cleaner holds it" \
    "1" "$(printf '%s\n' "$NOMKDIR_OUT" | grep -c 'bin/claude-vm-cleanup is reaping this run dir')"
  kill "$BLOCKER_PID" 2>/dev/null
  wait "$BLOCKER_PID" 2>/dev/null
else
  FAIL=$((FAIL + 1))
  echo "FAIL - could not slice the run-dir + lock lines out of claude-vm.sh"
fi

# ---------------------------------------------------------------------
# 2. The proxy and gvproxy are spawned without the lock.
# ---------------------------------------------------------------------
PROXY_LINE="$(grep -n '^eval "exec \$PROXY_CMD" ' "$LAUNCHER" | head -1 | cut -d: -f1)"
GV_START="$(grep -n '^"\$GVPROXY_BIN" --listen-vfkit' "$LAUNCHER" | head -1 | cut -d: -f1)"
GV_END=""
if [ -n "$GV_START" ]; then
  GV_END="$(awk -v s="$GV_START" 'NR >= s && /^GV_PID=\$!$/ { print NR; exit }' "$LAUNCHER")"
fi
if [ -n "$LOCK_START" ] && [ -n "$LOCK_END" ] && [ -n "$PROXY_LINE" ] && [ -n "$GV_START" ] && [ -n "$GV_END" ]; then
  # Stand-ins: the proxy command and the gvproxy binary each just sleep, long
  # enough to outlive the launcher they were started from. The proxy stand-in
  # is shaped like the bundled tinyproxy launch -- a script that execs the
  # proxy -- and first writes its own pid to $RUN/proxy.self, so a test can
  # tell the process that became the proxy from the pid the launcher recorded.
  FAKE_GVPROXY="$WORK/fake-gvproxy"
  printf '#!/bin/sh\nexec sleep 300\n' > "$FAKE_GVPROXY"
  chmod +x "$FAKE_GVPROXY"
  FAKE_PROXY="$WORK/fake-proxy"
  printf '#!/bin/sh\necho "$$" > "$1"\nexec sleep 300\n' > "$FAKE_PROXY"
  chmod +x "$FAKE_PROXY"
  SPAWN_LINES="$WORK/spawn-lines.sh"
  {
    printf 'PROXY_CMD=%s\n' "'$FAKE_PROXY \"\$RUN/proxy.self\"'"
    echo 'PROXY_LOG="$RUN/proxy.log"'
    echo "GVPROXY_BIN=\"$FAKE_GVPROXY\""
    echo 'GVPROXY_LOG="$RUN/gvproxy.log"'
    echo 'GVPROXY_SOCK="$RUN/net.sock"'
    echo 'SSH_PORT=0'
    echo 'PCAP="$RUN/egress.pcap"'
    awk -v n="$PROXY_LINE" 'NR == n' "$LAUNCHER"
    echo 'echo $! >> "$3"'
    awk -v s="$GV_START" -v e="$GV_END" 'NR >= s && NR <= e' "$LAUNCHER"
    echo 'echo $GV_PID >> "$3"'
  } > "$SPAWN_LINES"
  HOLDER_SPAWN="$WORK/holder-spawn.sh"
  write_holder "$HOLDER_SPAWN" "$SPAWN_LINES"

  bash "$HOLDER_SPAWN" run-c "$WORK/c.ready" "$WORK/c.pids" &
  HOLDER_PID=$!
  SPAWNED+=("$HOLDER_PID")
  wait_for_file "$WORK/c.ready"
  RUN_C="$(cat "$WORK/c.ready" 2>/dev/null)"
  C_PIDS="$(cat "$WORK/c.pids" 2>/dev/null)"
  track_pids "$WORK/c.pids"
  C_PROXY_PID="$(printf '%s\n' "$C_PIDS" | sed -n 1p)"
  C_GV_PID="$(printf '%s\n' "$C_PIDS" | sed -n 2p)"
  wait_for_file "$RUN_C/proxy.self"
  track_pids "$RUN_C/proxy.self"
  assert_eq "spawn: the pid the launcher records for the proxy is the proxy's own process" \
    "$(cat "$RUN_C/proxy.self" 2>/dev/null)" "$C_PROXY_PID"

  kill -9 "$HOLDER_PID"
  wait "$HOLDER_PID" 2>/dev/null
  assert_eq "spawn: the proxy outlives its killed launcher (so the next check means something)" \
    "alive" "$(alive "$C_PROXY_PID")"
  assert_eq "spawn: gvproxy outlives its killed launcher too" \
    "alive" "$(alive "$C_GV_PID")"
  assert_eq "spawn: neither keeps the run's lock held once the launcher is gone" \
    "0" "$(lock_probe "$RUN_C/run.lock")"

  # NEGATIVE CONTROL: the same slice with the two fd closes removed. The
  # orphaned children then keep the lock, and the run would read as live
  # forever -- which is what the closes are for.
  SPAWN_LINES_OPEN="$WORK/spawn-lines-open.sh"
  sed 's/ 9>&- &$/ \&/' "$SPAWN_LINES" > "$SPAWN_LINES_OPEN"
  assert_eq "spawn: the control really has both fd closes removed" \
    "0" "$(grep -c '9>&-' "$SPAWN_LINES_OPEN")"
  HOLDER_OPEN="$WORK/holder-open.sh"
  write_holder "$HOLDER_OPEN" "$SPAWN_LINES_OPEN"
  bash "$HOLDER_OPEN" run-d "$WORK/d.ready" "$WORK/d.pids" &
  HOLDER_PID=$!
  SPAWNED+=("$HOLDER_PID")
  wait_for_file "$WORK/d.ready"
  RUN_D="$(cat "$WORK/d.ready" 2>/dev/null)"
  track_pids "$WORK/d.pids"
  wait_for_file "$RUN_D/proxy.self"
  track_pids "$RUN_D/proxy.self"
  kill -9 "$HOLDER_PID"
  wait "$HOLDER_PID" 2>/dev/null
  assert_eq "spawn: NEGATIVE CONTROL -- children holding fd 9 keep the lock after kill -9" \
    "75" "$(lock_probe "$RUN_D/run.lock")"

  # NEGATIVE CONTROL: the same slice with proxy.cmd eval'd without its exec.
  # The recorded pid is then the subshell the eval runs in, and the proxy is
  # its child, which stopping the recorded pid leaves running.
  SPAWN_LINES_NOEXEC="$WORK/spawn-lines-noexec.sh"
  sed 's/"exec \$PROXY_CMD"/"$PROXY_CMD"/' "$SPAWN_LINES" > "$SPAWN_LINES_NOEXEC"
  assert_eq "spawn: the control really evals proxy.cmd without the exec" \
    "0" "$(grep -c 'exec \$PROXY_CMD' "$SPAWN_LINES_NOEXEC")"
  HOLDER_NOEXEC="$WORK/holder-noexec.sh"
  write_holder "$HOLDER_NOEXEC" "$SPAWN_LINES_NOEXEC"
  bash "$HOLDER_NOEXEC" run-d2 "$WORK/d2.ready" "$WORK/d2.pids" 2>/dev/null &
  HOLDER_PID=$!
  SPAWNED+=("$HOLDER_PID")
  wait_for_file "$WORK/d2.ready"
  RUN_D2="$(cat "$WORK/d2.ready" 2>/dev/null)"
  track_pids "$WORK/d2.pids"
  wait_for_file "$RUN_D2/proxy.self"
  track_pids "$RUN_D2/proxy.self"
  D2_PROXY_PID="$(sed -n 1p "$WORK/d2.pids" 2>/dev/null)"
  D2_PROXY_SELF="$(cat "$RUN_D2/proxy.self" 2>/dev/null)"
  kill "$D2_PROXY_PID" 2>/dev/null
  sleep 0.3
  assert_eq "spawn: NEGATIVE CONTROL -- without the exec, stopping the recorded pid leaves the proxy running" \
    "alive" "$(alive "$D2_PROXY_SELF")"
  kill -9 "$HOLDER_PID"
  wait "$HOLDER_PID" 2>/dev/null
else
  FAIL=$((FAIL + 1))
  echo "FAIL - could not slice the proxy/gvproxy spawn lines out of claude-vm.sh"
fi

# ---------------------------------------------------------------------
# 3. kill -9 of the launcher stops vfkit through the run's watcher.
# ---------------------------------------------------------------------
VF_START="$(grep -n '^VM_EXIT_STATUS=1$' "$LAUNCHER" | head -1 | cut -d: -f1)"
VF_END=""
if [ -n "$VF_START" ]; then
  VF_END="$(awk -v s="$VF_START" 'NR > s && /^VM_EXIT_STATUS=\$\?$/ { print NR; exit }' "$LAUNCHER")"
fi
META_START="$(grep -n '^claude_vm_run_meta_put() {$' "$LAUNCHER" | head -1 | cut -d: -f1)"
if [ -n "${SPAWN_LINES:-}" ] && [ -f "${SPAWN_LINES:-}" ] && [ -n "$VF_START" ] && [ -n "$VF_END" ] && [ -n "$META_START" ]; then
  # Stand-in vfkit: records its own pid -- the pid the launcher's subshell
  # had before it exec'd into this -- then sleeps as a running VM would.
  FAKE_BIN="$WORK/fake-bin"
  mkdir -p "$FAKE_BIN"
  printf '#!/bin/sh\necho "$$" > "$VFKIT_PIDFILE"\nexec sleep 300\n' > "$FAKE_BIN/vfkit"
  chmod +x "$FAKE_BIN/vfkit"

  # The launch harness: the lock lines, the proxy and gvproxy spawns, then the
  # vfkit launch itself, which it never returns from while the stand-in runs.
  # Only the variables vfkit's argument list reads are supplied.
  VF_HOLDER="$WORK/holder-vfkit.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf '. %s\n' "\"$LIB\""
    echo 'RUN_ID="$1"'
    awk -v s="$LOCK_START" -v e="$LOCK_END" 'NR >= s && NR <= e' "$LAUNCHER"
    cat "$SPAWN_LINES"
    # The launcher's own PROXY_PID=$! line is not in the spawn slice, nor are
    # the start-time readings taken beside it and beside GV_PID=$!. A
    # FAKE_PROXY_START in the environment stands in for a recorded start time
    # the proxy's pid no longer carries: a pid another process has taken.
    echo 'PROXY_PID="$(sed -n 1p "$3")"'
    echo 'PROXY_PID_START="${FAKE_PROXY_START:-$(claude_vm_pid_start "$PROXY_PID")}"'
    echo 'GV_PID_START="$(claude_vm_pid_start "$GV_PID")"'
    printf 'SCRIPT_DIR="%s"\n' "$TEST_DIR/.."
    echo 'RUN_META="$RUN/run.meta"'
    awk -v s="$META_START" 'NR >= s { print } NR > s && /^}$/ { exit }' "$LAUNCHER"
    echo 'VM_CPUS=1 VM_MEM=512 EFISTORE="$RUN/efistore" GUEST_IMAGE_CLONE="$RUN/guest-clone.raw"'
    echo 'MOUNT_SHARED_DIR="$RUN/worktree" CONFIG_DIR="$RUN/config" CLAUDE_BIN_DIR="$RUN/bin"'
    echo 'CREDS_DIR="$RUN/creds" GUEST_CONSOLE_LOG="$RUN/guest-console.log" EXTRA_MOUNT_FLAGS=()'
    echo "PATH=\"$FAKE_BIN:\$PATH\""
    awk -v s="$VF_START" -v e="$VF_END" 'NR >= s && NR < e' "$LAUNCHER"
  } > "$VF_HOLDER"

  # start_vf_run <run-id> -- start a launch harness for <run-id> and wait for
  # its stand-in vfkit and its watcher to be up. Sets VF_HOLDER_PID, VF_RUN,
  # VF_PID, VF_PROXY_PID, VF_GV_PID and VF_WATCHER_PID.
  start_vf_run() {
    VF_RUN="$CLAUDE_VM_RUNS_DIR/$1"
    VFKIT_PIDFILE="$WORK/$1.vfkit-pid" bash "$VF_HOLDER" "$1" unused "$WORK/$1.pids" \
      >/dev/null 2>&1 &
    VF_HOLDER_PID=$!
    SPAWNED+=("$VF_HOLDER_PID")
    wait_for_file "$WORK/$1.vfkit-pid"
    track_pids "$WORK/$1.pids"
    track_pids "$WORK/$1.vfkit-pid"
    VF_PID="$(cat "$WORK/$1.vfkit-pid" 2>/dev/null)"
    wait_for_file "$VF_RUN/proxy.self"
    track_pids "$VF_RUN/proxy.self"
    VF_PROXY_PID="$(cat "$VF_RUN/proxy.self" 2>/dev/null)"
    VF_GV_PID="$(sed -n 2p "$WORK/$1.pids" 2>/dev/null)"
    VF_WATCHER_PID="$(sed -n 's/^watcher_pid=//p' "$VF_RUN/run.meta" 2>/dev/null | tail -n 1)"
    [ -n "$VF_WATCHER_PID" ] && SPAWNED+=("$VF_WATCHER_PID")
  }

  # wait_dead <pid> -- poll up to 5s for <pid> to exit.
  wait_dead() {
    local i=0
    while kill -0 "$1" 2>/dev/null && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i + 1))
    done
  }

  export CLAUDE_VM_RUNS_DIR="$WORK/runs-vfkit"
  start_vf_run run-e
  assert_eq "vfkit: the stand-in is running under the launcher" "alive" "$(alive "$VF_PID")"
  assert_eq "vfkit: run.meta records the pid that became vfkit as vfkit_pid" \
    "$VF_PID" "$(sed -n 's/^vfkit_pid=//p' "$VF_RUN/run.meta" 2>/dev/null | tail -n 1)"
  assert_eq "vfkit: run.meta records vfkit's start time beside its pid" \
    "$(pid_start "$VF_PID")" "$(sed -n 's/^vfkit_pid_start=//p' "$VF_RUN/run.meta" 2>/dev/null | tail -n 1)"
  assert_eq "vfkit: the proxy pid the watcher is handed is the proxy's own process" \
    "$VF_PROXY_PID" "$(sed -n 1p "$WORK/run-e.pids" 2>/dev/null)"
  assert_eq "vfkit: run.meta's watcher_pid is lockf itself, waiting on the lock" \
    "/usr/bin/lockf" "$([ -n "$VF_WATCHER_PID" ] && ps -o comm= -p "$VF_WATCHER_PID" 2>/dev/null)"
  assert_eq "vfkit: the lock is held while the launcher runs" \
    "75" "$(lock_probe "$VF_RUN/run.lock")"
  kill -9 "$VF_HOLDER_PID"
  wait "$VF_HOLDER_PID" 2>/dev/null
  wait_dead "$VF_PID"
  assert_eq "vfkit: after kill -9 of the launcher, the watcher stops vfkit" \
    "dead" "$(alive "$VF_PID")"
  assert_eq "vfkit: ...and gvproxy" "dead" "$(alive "$VF_GV_PID")"
  assert_eq "vfkit: ...and the forward proxy" "dead" "$(alive "$VF_PROXY_PID")"
  wait_dead "$VF_WATCHER_PID"
  assert_eq "vfkit: the run's lock test-acquire then succeeds" \
    "0" "$(lock_probe "$VF_RUN/run.lock")"
  assert_eq "vfkit: the watcher keeps run.lock in place" \
    "present" "$([ -f "$VF_RUN/run.lock" ] && echo present || echo absent)"

  # NEGATIVE CONTROL: the same launch with its watcher stopped first -- what
  # cleanup() does on a normal exit. kill -9 of the launcher then leaves vfkit
  # running, so the watcher is what stopped it above; and the lock is still
  # free, so vfkit itself holds none.
  start_vf_run run-f
  kill "$VF_WATCHER_PID" 2>/dev/null
  wait_dead "$VF_WATCHER_PID"
  kill -9 "$VF_HOLDER_PID"
  wait "$VF_HOLDER_PID" 2>/dev/null
  sleep 0.5
  assert_eq "vfkit: NEGATIVE CONTROL -- with the watcher stopped, vfkit outlives the killed launcher" \
    "alive" "$(alive "$VF_PID")"
  assert_eq "vfkit: ...and still holds no lock: the test-acquire succeeds" \
    "0" "$(lock_probe "$VF_RUN/run.lock")"
  kill "$VF_PID" "$VF_GV_PID" "$VF_PROXY_PID" 2>/dev/null

  # A recorded pid that no longer carries its recorded start time is left
  # alone: the watcher stops vfkit and gvproxy but not a proxy pid whose start
  # time run.meta does not match -- a number another process has since taken.
  FAKE_PROXY_START="Thu Jan  1 00:00:00 1970" start_vf_run run-g
  assert_eq "vfkit: run.meta records the watcher's start time beside its pid" \
    "$(pid_start "$VF_WATCHER_PID")" "$(sed -n 's/^watcher_pid_start=//p' "$VF_RUN/run.meta" 2>/dev/null | tail -n 1)"
  kill -9 "$VF_HOLDER_PID"
  wait "$VF_HOLDER_PID" 2>/dev/null
  wait_dead "$VF_PID"
  wait_dead "$VF_WATCHER_PID"
  assert_eq "vfkit: the watcher stops a pid still carrying its recorded start time" \
    "dead" "$(alive "$VF_PID")"
  assert_eq "vfkit: ...and gvproxy" "dead" "$(alive "$VF_GV_PID")"
  assert_eq "vfkit: ...and leaves a pid whose start time is not the recorded one" \
    "alive" "$(alive "$VF_PROXY_PID")"
  kill "$VF_PID" "$VF_GV_PID" "$VF_PROXY_PID" 2>/dev/null
else
  FAIL=$((FAIL + 1))
  echo "FAIL - could not slice the vfkit launch lines out of claude-vm.sh"
fi

# ---------------------------------------------------------------------
# 4. bin/claude-vm-cleanup reaps the dead run, keeping its worktree and
#    run.meta, and spares the live one.
# ---------------------------------------------------------------------
# Only the state root is set; the runs root is whatever lib/config.sh derives
# from it, read back here the same way the cleaner gets it.
export CLAUDE_VM_STATE_DIR="$WORK/state"
unset CLAUDE_VM_RUNS_DIR
# shellcheck source=../lib/config.sh
CLAUDE_VM_RUNS_DIR="$(. "$LIB" && printf '%s' "$CLAUDE_VM_RUNS_DIR")"
assert_eq "runs root: lib/config.sh derives it under the state root" \
  "$CLAUDE_VM_STATE_DIR/runs" "$CLAUDE_VM_RUNS_DIR"
REPO="/repos/shared"

# make_run <run-id> <gvproxy-pid> <proxy-pid> <sock-dir> [<vfkit-pid>] -- a
# run dir shaped the way a crashed launcher leaves one: run.lock, run.meta
# with each pid's start time beside it, a clone, a worktree, the creds/ dir
# and the raw Keychain blob.
make_run() {
  local run="$CLAUDE_VM_RUNS_DIR/$1"
  mkdir -p "$run/worktree" "$run/creds" "$4"
  : > "$run/run.lock"
  : > "$4/net.sock"
  printf 'guest image bytes\n' > "$run/guest-clone.raw"
  printf '{"claudeAiOauth":{}}\n' > "$run/creds/.credentials.json"
  printf '{"claudeAiOauth":{}}\n' > "$run/.keychain-blob.raw.json"
  {
    printf 'run_id=%s\n' "$1"
    printf 'repo_src=%s\n' "$REPO"
    printf 'repo_mount=clone\n'
    printf 'worktree=%s\n' "$run/worktree"
    printf 'copy_back=local\n'
    printf 'proxy_pid=%s\n' "$3"
    printf 'proxy_pid_start=%s\n' "$([ -n "$3" ] && pid_start "$3")"
    printf 'gvproxy_pid=%s\n' "$2"
    printf 'gvproxy_pid_start=%s\n' "$([ -n "$2" ] && pid_start "$2")"
    printf 'gvproxy_sock=%s\n' "$4/net.sock"
    printf 'ssh_port=2222\n'
    printf 'vfkit_pid=%s\n' "${5:-}"
    printf 'vfkit_pid_start=%s\n' "$([ -n "${5:-}" ] && pid_start "$5")"
  } > "$run/run.meta"
}

# spawn_sleeper -- print the pid of a detached `sleep 300`. Started from a
# command substitution so it is not this shell's job, and the cleaner killing
# it prints no job notice into the suite's output.
spawn_sleeper() {
  sleep 300 >/dev/null 2>&1 &
  echo $!
}
DEAD_GV="$(spawn_sleeper)"; SPAWNED+=("$DEAD_GV")
DEAD_PROXY="$(spawn_sleeper)"; SPAWNED+=("$DEAD_PROXY")
LIVE_GV="$(spawn_sleeper)"; SPAWNED+=("$LIVE_GV")
LIVE_PROXY="$(spawn_sleeper)"; SPAWNED+=("$LIVE_PROXY")
DEAD_VFKIT="$(spawn_sleeper)"; SPAWNED+=("$DEAD_VFKIT")
LIVE_VFKIT="$(spawn_sleeper)"; SPAWNED+=("$LIVE_VFKIT")
DEAD_SOCK_DIR="$WORK/tmp/claude-vm-sock.dead01"
LIVE_SOCK_DIR="$WORK/tmp/claude-vm-sock.live01"
make_run 20260101-000000-1 "$DEAD_GV" "$DEAD_PROXY" "$DEAD_SOCK_DIR" "$DEAD_VFKIT"
make_run 20260101-000000-2 "$LIVE_GV" "$LIVE_PROXY" "$LIVE_SOCK_DIR" "$LIVE_VFKIT"
DEAD_RUN="$CLAUDE_VM_RUNS_DIR/20260101-000000-1"
LIVE_RUN="$CLAUDE_VM_RUNS_DIR/20260101-000000-2"
# A run dir with no lock file: a launch caught between mkdir and its lock.
mkdir -p "$CLAUDE_VM_RUNS_DIR/20260101-000000-3"
# The dead run's logs, which the cleaner must never touch.
mkdir -p "$CLAUDE_VM_STATE_DIR/logs/20260101-000000-1"
printf 'post-mortem\n' > "$CLAUDE_VM_STATE_DIR/logs/20260101-000000-1/boot.log"

# The live run's launcher: holds run.lock through fd 9, the way the launcher
# does, and execs into the sleep so killing this one pid releases it.
bash -c 'exec 9>>"$1"; /usr/bin/lockf -s -t 0 9 && exec sleep 300' _ "$LIVE_RUN/run.lock" >/dev/null 2>&1 &
LIVE_HOLDER=$!
SPAWNED+=("$LIVE_HOLDER")
sleep 0.3
assert_eq "cleaner fixture: the live run's lock really is held" \
  "75" "$(lock_probe "$LIVE_RUN/run.lock")"

CLEAN_OUT="$("$CLEANER" 2>&1)"
CLEAN_RC=$?
printf '%s\n' "$CLEAN_OUT" | sed 's/^/        | /'

assert_eq "cleaner: exits 0 when nothing failed" "0" "$CLEAN_RC"
# Dead run: processes, socket dir, run dir.
sleep 0.2
assert_eq "cleaner: kills the dead run's recorded gvproxy_pid" "dead" "$(alive "$DEAD_GV")"
assert_eq "cleaner: kills the dead run's recorded proxy_pid" "dead" "$(alive "$DEAD_PROXY")"
assert_eq "cleaner: kills the dead run's recorded vfkit_pid" "dead" "$(alive "$DEAD_VFKIT")"
assert_eq "cleaner: removes the dead run's gvproxy_sock directory" \
  "absent" "$([ -e "$DEAD_SOCK_DIR" ] && echo present || echo absent)"
assert_eq "cleaner: removes the dead run's guest-clone.raw" \
  "absent" "$([ -e "$DEAD_RUN/guest-clone.raw" ] && echo present || echo absent)"
assert_eq "cleaner: keeps the dead run's worktree" \
  "present" "$([ -d "$DEAD_RUN/worktree" ] && echo present || echo absent)"
assert_eq "cleaner: keeps the dead run's run.meta" \
  "present" "$([ -f "$DEAD_RUN/run.meta" ] && echo present || echo absent)"
assert_eq "cleaner: removes the dead run's creds/ dir" \
  "absent" "$([ -e "$DEAD_RUN/creds" ] && echo present || echo absent)"
assert_eq "cleaner: removes the dead run's raw Keychain blob" \
  "absent" "$([ -e "$DEAD_RUN/.keychain-blob.raw.json" ] && echo present || echo absent)"
assert_eq "cleaner: reports the creds/ removal" \
  "1" "$(printf '%s\n' "$CLEAN_OUT" | grep -cF "removed $DEAD_RUN/creds")"
# Live run of the same repo_src: untouched, processes included.
assert_eq "cleaner: leaves the live run dir of the same repo_src in place" \
  "present" "$([ -f "$LIVE_RUN/guest-clone.raw" ] && echo present || echo absent)"
assert_eq "cleaner: leaves the live run's run.meta in place" \
  "present" "$([ -f "$LIVE_RUN/run.meta" ] && echo present || echo absent)"
assert_eq "cleaner: does not kill the live run's gvproxy_pid" "alive" "$(alive "$LIVE_GV")"
assert_eq "cleaner: does not kill the live run's proxy_pid" "alive" "$(alive "$LIVE_PROXY")"
assert_eq "cleaner: does not kill the live run's vfkit_pid" "alive" "$(alive "$LIVE_VFKIT")"
assert_eq "cleaner: leaves the live run's socket dir" \
  "present" "$([ -d "$LIVE_SOCK_DIR" ] && echo present || echo absent)"
assert_eq "cleaner: leaves the live run's creds/ dir" \
  "present" "$([ -f "$LIVE_RUN/creds/.credentials.json" ] && echo present || echo absent)"
assert_eq "cleaner: the live run's lock is still held afterwards" \
  "75" "$(lock_probe "$LIVE_RUN/run.lock")"
# No lock file: spared.
assert_eq "cleaner: spares a run dir with no run.lock" \
  "present" "$([ -d "$CLAUDE_VM_RUNS_DIR/20260101-000000-3" ] && echo present || echo absent)"
# Logs.
assert_eq "cleaner: never removes \$CLAUDE_VM_STATE_DIR/logs/<run-id>/" \
  "post-mortem" "$(cat "$CLAUDE_VM_STATE_DIR/logs/20260101-000000-1/boot.log" 2>/dev/null)"
# Report.
assert_eq "cleaner: reports the reaped run" \
  "1" "$(printf '%s\n' "$CLEAN_OUT" | grep -c '^reaped  20260101-000000-1 ')"
assert_eq "cleaner: reports the reaped run's log dir path" \
  "1" "$(printf '%s\n' "$CLEAN_OUT" | grep -cF "log dir $CLAUDE_VM_STATE_DIR/logs/20260101-000000-1/")"
assert_eq "cleaner: reports the reaped run's kept worktree path" \
  "1" "$(printf '%s\n' "$CLEAN_OUT" | grep -cF "worktree $DEAD_RUN/worktree (kept)")"
assert_eq "cleaner: reports the live run as spared" \
  "1" "$(printf '%s\n' "$CLEAN_OUT" | grep -c '^spared  20260101-000000-2 -- live')"
assert_eq "cleaner: reports the lockless run as spared" \
  "1" "$(printf '%s\n' "$CLEAN_OUT" | grep -c '^spared  20260101-000000-3 ')"
assert_eq "cleaner: the summary counts one reaped and two spared" \
  "1" "$(printf '%s\n' "$CLEAN_OUT" | grep -c ': 1 reaped, 2 spared, 0 failed ')"

# Once the live run's launcher dies, a second pass reaps it.
kill "$LIVE_HOLDER" 2>/dev/null
wait "$LIVE_HOLDER" 2>/dev/null
"$CLEANER" >/dev/null 2>&1
sleep 0.2
assert_eq "cleaner: a second pass reaps the run once its launcher is gone" \
  "absent" "$([ -e "$LIVE_RUN/guest-clone.raw" ] && echo present || echo absent)"
assert_eq "cleaner: ...keeping its worktree" \
  "present" "$([ -d "$LIVE_RUN/worktree" ] && echo present || echo absent)"
assert_eq "cleaner: ...killing its recorded gvproxy_pid then" "dead" "$(alive "$LIVE_GV")"
assert_eq "cleaner: ...and removing its creds/ dir then" \
  "absent" "$([ -e "$LIVE_RUN/creds" ] && echo present || echo absent)"

# A recorded pid that now belongs to another process is never signalled. The
# stand-in for a pid reused since the run stopped is a live process whose
# start time differs from the one run.meta records; one with no recorded start
# time is left alone too.
REUSED_PID="$(spawn_sleeper)"; SPAWNED+=("$REUSED_PID")
make_run 20260101-000000-6 "" "$REUSED_PID" "$WORK/tmp/claude-vm-sock.reuse01"
printf 'proxy_pid_start=Thu Jan  1 00:00:00 1970\n' >> "$CLAUDE_VM_RUNS_DIR/20260101-000000-6/run.meta"
NOSTART_PID="$(spawn_sleeper)"; SPAWNED+=("$NOSTART_PID")
make_run 20260101-000000-7 "$NOSTART_PID" "" "$WORK/tmp/claude-vm-sock.nostart01"
printf 'gvproxy_pid_start=\n' >> "$CLAUDE_VM_RUNS_DIR/20260101-000000-7/run.meta"
REUSE_OUT="$("$CLEANER" 2>&1)"
sleep 0.2
assert_eq "cleaner: does not signal a recorded pid whose start time has changed" \
  "alive" "$(alive "$REUSED_PID")"
assert_eq "cleaner: ...and says it left it alone" \
  "1" "$(printf '%s\n' "$REUSE_OUT" | grep -c "proxy_pid $REUSED_PID left alone -- not provably this run's process")"
assert_eq "cleaner: does not signal a recorded pid with no recorded start time" \
  "alive" "$(alive "$NOSTART_PID")"

# The same on a later pass over a run already reaped: the dead run's proxy pid
# number now names a different, live process. Start times are whole seconds,
# so the stand-in is started a second after the recorded one.
sleep 1.1
LATER_PID="$(spawn_sleeper)"; SPAWNED+=("$LATER_PID")
printf 'proxy_pid=%s\n' "$LATER_PID" >> "$DEAD_RUN/run.meta"
"$CLEANER" >/dev/null 2>&1
sleep 0.2
assert_eq "cleaner: a later pass over a reaped run does not signal its reused pid" \
  "alive" "$(alive "$LATER_PID")"

# A gvproxy_sock whose directory is not one the launcher names is left alone,
# while the rest of the dead run is still reaped.
FOREIGN_DIR="$WORK/tmp/not-a-sock-dir"
make_run 20260101-000000-4 "" "" "$FOREIGN_DIR"
"$CLEANER" >/dev/null 2>&1
assert_eq "cleaner: leaves a recorded socket dir that is not claude-vm-sock.*" \
  "present" "$([ -d "$FOREIGN_DIR" ] && echo present || echo absent)"
assert_eq "cleaner: ...and still removes that dead run's guest-clone.raw" \
  "absent" "$([ -e "$CLAUDE_VM_RUNS_DIR/20260101-000000-4/guest-clone.raw" ] && echo present || echo absent)"

# A run that exited normally: its cleanup() already removed guest-clone.raw
# and stopped its processes. It is reaped the same way as a crashed one, and
# its worktree is kept for the companion skills.
make_run 20260101-000000-5 "" "" "$WORK/tmp/claude-vm-sock.clean01"
rm -f "$CLAUDE_VM_RUNS_DIR/20260101-000000-5/guest-clone.raw"
CLEAN5_OUT="$("$CLEANER" 2>&1)"
assert_eq "cleaner: exits 0 on a run that exited normally" "0" "$?"
assert_eq "cleaner: reaps a run that exited normally" \
  "1" "$(printf '%s\n' "$CLEAN5_OUT" | grep -c '^reaped  20260101-000000-5 ')"
assert_eq "cleaner: ...keeping its worktree" \
  "present" "$([ -d "$CLAUDE_VM_RUNS_DIR/20260101-000000-5/worktree" ] && echo present || echo absent)"
assert_eq "cleaner: ...and its run.meta" \
  "present" "$([ -f "$CLAUDE_VM_RUNS_DIR/20260101-000000-5/run.meta" ] && echo present || echo absent)"

# No runs root at all is not an error.
NOROOT_OUT="$(CLAUDE_VM_RUNS_DIR="$WORK/no-such-root" "$CLEANER" 2>&1)"
assert_eq "cleaner: a missing runs root exits 0" "0" "$?"
assert_eq "cleaner: ...and says there is nothing to reap" \
  "1" "$(printf '%s\n' "$NOROOT_OUT" | grep -c 'nothing to reap')"

# ---------------------------------------------------------------------
echo ""
echo "cleanup-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
