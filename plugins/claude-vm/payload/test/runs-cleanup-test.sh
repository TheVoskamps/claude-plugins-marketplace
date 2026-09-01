#!/usr/bin/env bash
#
# runs-cleanup-test.sh -- the host-scoped run root and the orphan cleaner
# (issue #181).
#
# Covers three things, none of which needs a VM:
#
#   1. payload/lib/runsroot.sh -- the ONE place the runs root is composed:
#      the XDG default, the $XDG_STATE_HOME override, and the env override
#      the rest of this suite drives everything through.
#   2. The lockf(1) liveness mechanism the cleaner's dead-vs-live decision
#      rests on, against REAL processes -- including the fd-inheritance
#      hazard, which is the whole reason the launcher spawns its long-lived
#      children with `9>&-`.
#   3. bin/claude-vm-cleanup itself: it reaps a dead run's dir, clone,
#      recorded pids and recorded socket dir; it never touches a live run;
#      and it gets both right when a dead run and a LIVE SIBLING sit in the
#      same runs root for the same repo, which is the concurrency shape the
#      issue names as the thing an existence test destroys.
#
# Run directly:
#
#   plugins/claude-vm/payload/test/runs-cleanup-test.sh
#
# Requires: /usr/bin/lockf (macOS base system). Skips cleanly if absent.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../lib/runsroot.sh"
CLEANER="$TEST_DIR/../../bin/claude-vm-cleanup"

if ! command -v lockf >/dev/null 2>&1; then
  echo "SKIP: lockf(1) not available; runs-cleanup tests skipped." >&2
  exit 0
fi
if [ ! -x "$CLEANER" ]; then
  echo "FAIL - bin/claude-vm-cleanup is missing or not executable at $CLEANER"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-runs-cleanup-test.XXXXXX")"
# Spawned pids are tracked in a FILE, not an array: every spawner below runs
# inside a `$(...)` so it can print the pid it made, and an array append inside
# a command substitution lands in that subshell and never reaches this one.
# A file is the only channel that survives the subshell, so the trap really
# does see every process this suite started.
PIDFILE="$WORK/spawned.pids"
: > "$PIDFILE"
cleanup_test() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    kill -9 "$p" 2>/dev/null || true
  done < "$PIDFILE"
  rm -rf "$WORK"
}
trap cleanup_test EXIT

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

exists() { [ -e "$1" ] && echo present || echo absent; }

# Is <path> inside <dir>? Defined as a FUNCTION rather than written inline in
# an assertion's own `$(...)`: bash 3.2 -- what this file's `#!/usr/bin/env
# bash` resolves to on a stock macOS -- finds the end of a command substitution
# by counting parens, and a `case` pattern's `)` ends it early, so an inline
# case compares against a fragment of this file's own source. Same rule
# config-test.sh's mnt_inside_share follows, for the same reason.
path_inside() {
  case "$1/" in
    "$2"/*) echo inside ;;
    *) echo outside ;;
  esac
}

# Is <pid> alive?
alive() { kill -0 "$1" 2>/dev/null && echo running || echo gone; }

# ---------------------------------------------------------------------
# 1. The resolver
#
# Driven in SUBSHELLS with the variable unset, because runsroot.sh assigns
# with `: "${VAR:=default}"` -- a value already in this shell's environment
# would make every case measure that value instead of the default logic.
# ---------------------------------------------------------------------
assert_eq "runsroot: defaults to \$HOME/.local/state when XDG_STATE_HOME is unset" \
  "/fake/home/.local/state/claude-vm/runs" \
  "$(unset CLAUDE_VM_RUNS_ROOT XDG_STATE_HOME; HOME=/fake/home; . "$LIB"; claude_vm_runs_root)"

assert_eq "runsroot: honours XDG_STATE_HOME when it is set" \
  "/xdg/state/claude-vm/runs" \
  "$(unset CLAUDE_VM_RUNS_ROOT; XDG_STATE_HOME=/xdg/state; HOME=/fake/home; . "$LIB"; claude_vm_runs_root)"

assert_eq "runsroot: an explicit CLAUDE_VM_RUNS_ROOT wins over both" \
  "/explicit/runs" \
  "$(CLAUDE_VM_RUNS_ROOT=/explicit/runs XDG_STATE_HOME=/xdg/state HOME=/fake/home; . "$LIB"; claude_vm_runs_root)"

# It is state, not config: it must NOT land under the config dir lib/config.sh
# and lib/claude-cache.sh use. Asserted as a relation between the two roots
# rather than as a second literal, so a future move of either is still caught.
assert_eq "runsroot: the runs root is NOT under \$XDG_CONFIG_HOME/claude-vm (state, not config)" \
  "outside" \
  "$(unset CLAUDE_VM_RUNS_ROOT XDG_STATE_HOME; HOME=/fake/home; . "$LIB"; \
     path_inside "$(claude_vm_runs_root)" /fake/home/.config/claude-vm)"

# ---------------------------------------------------------------------
# 2. The lockf liveness mechanism, against real processes.
#
# `lock_holder <lockfile> <marker> <inherit|closed> <child-secs>` mirrors the
# launcher: it opens the lock on fd 9, takes it, then spawns ONE long-lived
# child and parks on the `wait` BUILTIN (which forks nothing, so the arm under
# test is the only child there is). The two modes differ ONLY in whether that
# child inherits fd 9 -- `closed` is the launcher's real `9>&-` shape.
#
# <child-secs> is the child's sleep duration, and doubles as its IDENTITY: the
# assertions below have to establish that the orphan is still running after its
# parent is killed, and `sleep 600` is not distinguishable from any other
# `sleep 600` on the host. Give each arm its own duration and `pgrep -f` finds
# exactly its own child.
# ---------------------------------------------------------------------
lock_holder() {
  local lockfile="$1" marker="$2" mode="$3"
  # $script is declared on its OWN line: `local` expands every word before it
  # assigns any of them, so `local marker="$2" script="...$marker..."` reads an
  # unset $marker and dies under `set -u`.
  local script="$WORK/holder-$marker.sh"
  local child_secs="${4:-600}"
  {
    echo 'set -uo pipefail'
    echo 'exec 9>>"$1"'
    echo 'lockf -s -t 0 9 || exit 1'
    if [ "$mode" = closed ]; then
      echo "sleep $child_secs 9>&- &"
    else
      echo "sleep $child_secs &"
    fi
    echo 'wait'
  } > "$script"
  /bin/bash "$script" "$lockfile" >/dev/null 2>&1 &
  echo $! >> "$PIDFILE"
  echo $!
}

# Non-blocking test-acquire, exactly as the cleaner performs it.
test_acquire_rc() {
  lockf -s -t 0 -k "$1" true
  echo $?
}

LOCK_A="$WORK/a.lock"
assert_eq "lockf: an unheld lock file test-acquires cleanly (rc 0 -> DEAD)" \
  "0" "$(test_acquire_rc "$LOCK_A")"
assert_eq "lockf: -k keeps the lock file, and its mere existence is not a lock" \
  "present" "$(exists "$LOCK_A")"
assert_eq "lockf: the kept file still test-acquires cleanly (rc 0 -> DEAD)" \
  "0" "$(test_acquire_rc "$LOCK_A")"

LOCK_B="$WORK/b.lock"
HOLDER_B="$(lock_holder "$LOCK_B" b closed)"
sleep 1
assert_eq "lockf: a held lock fails EX_TEMPFAIL (rc 75 -> LIVE)" \
  "75" "$(test_acquire_rc "$LOCK_B")"

# The kernel releases the lock on the holder's death, kill -9 included -- which
# is the case cleanup()'s trap cannot cover and the whole reason the lock is
# the liveness test.
kill -9 "$HOLDER_B" 2>/dev/null
wait "$HOLDER_B" 2>/dev/null
sleep 1
assert_eq "lockf: kill -9 of the holder releases the lock (rc 0 -> DEAD)" \
  "0" "$(test_acquire_rc "$LOCK_B")"

# NEGATIVE CONTROL for the launcher's `9>&-`, and the reason it exists.
#
# An flock lives on the open file DESCRIPTION, which fork(2) SHARES, so a
# surviving child that inherited fd 9 keeps the lock held after the launcher
# dies -- and the survivors in the real launcher are exactly the gvproxy/proxy
# /vfkit processes the cleaner exists to reap. The `inherit` arm is the
# pre-`9>&-` shape and must read LIVE (75) while its orphan runs; the `closed`
# arm is what the launcher actually spawns and must read DEAD (0) with an
# equally-alive orphan. The orphan's liveness is asserted in both arms, so
# neither result can be explained by the child having simply exited.
ORPHAN_INHERIT_SECS=60181
ORPHAN_CLOSED_SECS=60182
LOCK_C="$WORK/c.lock"
HOLDER_C="$(lock_holder "$LOCK_C" cinherit inherit "$ORPHAN_INHERIT_SECS")"
LOCK_D="$WORK/d.lock"
HOLDER_D="$(lock_holder "$LOCK_D" dclosed closed "$ORPHAN_CLOSED_SECS")"
sleep 1
kill -9 "$HOLDER_C" "$HOLDER_D" 2>/dev/null
wait "$HOLDER_C" 2>/dev/null
wait "$HOLDER_D" 2>/dev/null
sleep 1

orphan_state() { pgrep -f "sleep $1" >/dev/null 2>&1 && echo running || echo gone; }

assert_eq "fd inheritance: the inheriting orphan outlived its parent and is still running" \
  "running" "$(orphan_state "$ORPHAN_INHERIT_SECS")"
assert_eq "fd inheritance: NEGATIVE CONTROL -- an orphan holding the inherited fd keeps the run LIVE (75)" \
  "75" "$(test_acquire_rc "$LOCK_C")"
assert_eq "fd inheritance: the 9>&- orphan outlived its parent and is equally alive" \
  "running" "$(orphan_state "$ORPHAN_CLOSED_SECS")"
assert_eq "fd inheritance: with 9>&- that same live orphan leaves the run DEAD (0)" \
  "0" "$(test_acquire_rc "$LOCK_D")"
pkill -f "sleep $ORPHAN_INHERIT_SECS" 2>/dev/null || true
pkill -f "sleep $ORPHAN_CLOSED_SECS" 2>/dev/null || true

# Which children get `9>&-` is a per-process DESIGN choice, not a blanket rule,
# and the launcher's three spawn sites must keep it. vfkit -- the VM itself --
# inherits the lock fd on purpose, so an orphaned vfkit reads LIVE and the
# cleaner spares a running VM's disk; the proxy and gvproxy, which are the two
# pids run.meta records for reaping, must NOT. Asserted on the launcher source
# because the asymmetry is invisible in behaviour until the exact orphan case
# arises, and it reads like an oversight a future round would "fix" for
# symmetry.
LAUNCHER="$TEST_DIR/../claude-vm.sh"
assert_eq "spawn sites: the forward proxy is spawned with the lock fd CLOSED" \
  "1" "$(grep -c '^eval "\$PROXY_CMD" .*9>&- &$' "$LAUNCHER")"
assert_eq "spawn sites: gvproxy is spawned with the lock fd CLOSED" \
  "1" "$(grep -c '^  >"\$GVPROXY_LOG" 2>&1 9>&- &$' "$LAUNCHER")"
assert_eq "spawn sites: vfkit is NOT -- it inherits the lock fd, so a live VM reads LIVE" \
  "1" "$(grep -c '^vfkit \\$' "$LAUNCHER")"
assert_eq "spawn sites: ...and carries no 9>&- of its own" \
  "0" "$(grep -c '^vfkit .*9>&-' "$LAUNCHER")"

# ---------------------------------------------------------------------
# 4. The run-dir + lock block is WIRED INTO THE LAUNCHER.
#
# Everything above establishes that lockf behaves and that the cleaner reads
# it correctly. Neither establishes the half that silently regresses: that the
# launcher actually creates its run dir under the runs root and actually takes
# the lock. A guard can be written, tested, and never wired.
#
# So slice the launcher's own block by line range -- the same extraction
# config-test.sh uses on the mount loop -- wrap it in a harness that sources
# the real lib and supplies the one variable the block reads from earlier in
# the launcher ($REPO_SRC), and run it. The fixture then travels the real code.
# ---------------------------------------------------------------------
RUNBLOCK_START="$(grep -n '^RUN_ID="\$(date ' "$LAUNCHER" | head -1 | cut -d: -f1)"
RUNBLOCK_END="$(awk -v s="${RUNBLOCK_START:-0}" 'NR >= s && /^exec 9>>"\$RUN\/run.lock"$/ { found = NR } found && NR > found && /^fi$/ { print NR; exit }' "$LAUNCHER")"

if [ -z "$RUNBLOCK_START" ] || [ -z "$RUNBLOCK_END" ]; then
  FAIL=$((FAIL + 1))
  echo "FAIL - run-dir/lock block extraction from claude-vm.sh (start=[$RUNBLOCK_START] end=[$RUNBLOCK_END])"
else
  RUNBLOCK="$WORK/run-block.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf '. %s\n' "\"$LIB\""
    echo 'REPO_SRC="$1"'
    sed -n "${RUNBLOCK_START},${RUNBLOCK_END}p" "$LAUNCHER"
    echo 'umask "$OLD_UMASK"'
    # Park holding the lock so the caller can observe it from outside, and
    # print $RUN so the caller knows where it landed.
    echo 'echo "$RUN"'
    echo 'sleep 60181'
  } > "$RUNBLOCK"

  RB_ROOT="$WORK/wired-runs"
  RB_REPO="$WORK/wired-repo"
  mkdir -p "$RB_REPO"
  RB_OUT="$WORK/run-block.out"
  CLAUDE_VM_RUNS_ROOT="$RB_ROOT" /bin/bash "$RUNBLOCK" "$RB_REPO" > "$RB_OUT" 2>&1 &
  echo $! >> "$PIDFILE"
  sleep 2
  RB_RUN="$(head -1 "$RB_OUT" 2>/dev/null || true)"

  assert_eq "wired: the launcher creates its run dir under the runs root" \
    "inside" "$(path_inside "$RB_RUN" "$RB_ROOT")"
  assert_eq "wired: ...and the run dir really exists" \
    "present" "$(exists "$RB_RUN")"
  assert_eq "wired: ...and it is NOT inside the repo it was launched against" \
    "outside" "$(path_inside "$RB_RUN" "$RB_REPO")"
  assert_eq "wired: the launcher created run.lock" \
    "present" "$(exists "$RB_RUN/run.lock")"
  assert_eq "wired: the launcher HOLDS that lock while it runs (rc 75 -> LIVE)" \
    "75" "$(test_acquire_rc "$RB_RUN/run.lock")"
  # The cleaner must therefore spare it -- the wiring proved end to end.
  RB_SWEEP="$(CLAUDE_VM_RUNS_ROOT="$RB_ROOT" "$CLEANER" 2>&1)"
  assert_eq "wired: the cleaner spares the run a real launcher block is holding" \
    "present" "$(exists "$RB_RUN")"

  pkill -f 'sleep 60181' 2>/dev/null || true
  sleep 1
  assert_eq "wired: once that launcher is gone the lock releases (rc 0 -> DEAD)" \
    "0" "$(test_acquire_rc "$RB_RUN/run.lock")"
fi

# ---------------------------------------------------------------------
# 3. bin/claude-vm-cleanup
#
# Driven against a synthetic runs root: a run dir is just a directory holding
# run.lock and run.meta, and the cleaner reads nothing else. CLAUDE_VM_RUNS_ROOT
# points it at this suite's own tree, so nothing outside $WORK is ever a
# candidate.
# ---------------------------------------------------------------------
ROOT="$WORK/runs"
mkdir -p "$ROOT"

# make_run <run-id> <repo-src> -- a run dir with a clone, a socket dir, a
# sacrificial long-lived process recorded as its gvproxy_pid, and a run.meta
# in the launcher's own `key=value` shape. Prints the recorded pid.
make_run() {
  local id="$1" repo="$2" run="$ROOT/$1"
  mkdir -p "$run"
  printf 'clone-bytes\n' > "$run/guest-clone.raw"
  local sock_dir
  sock_dir="$(mktemp -d "$WORK/claude-vm-sock.XXXXXX")"
  : > "$sock_dir/net.sock"
  # stdout/stderr redirected because make_run is called inside a `$(...)`:
  # a backgrounded child inherits the substitution's stdout PIPE, and the
  # capture then blocks until that child exits rather than until make_run
  # returns. Same reason endpoint-test.sh redirects its perl listeners.
  sleep 600 >/dev/null 2>&1 &
  local victim=$!
  echo "$victim" >> "$PIDFILE"
  {
    printf 'run_id=%s\n' "$id"
    printf 'repo_src=%s\n' "$repo"
    printf 'repo_mount=clone\n'
    printf 'worktree=%s/worktree\n' "$run"
    printf 'copy_back=local\n'
    printf 'proxy_pid=%s\n' "$victim"
    printf 'gvproxy_pid=%s\n' "$victim"
    printf 'gvproxy_sock=%s/net.sock\n' "$sock_dir"
  } > "$run/run.meta"
  printf '%s\t%s\n' "$victim" "$sock_dir"
}

REPO_ONE="$WORK/repo-one"

# A DEAD run: run.lock exists and nobody holds it.
DEAD_INFO="$(make_run dead-1 "$REPO_ONE")"
DEAD_PID="${DEAD_INFO%%	*}"
DEAD_SOCK_DIR="${DEAD_INFO#*	}"
: > "$ROOT/dead-1/run.lock"

# A LIVE SIBLING in the SAME repo -- the shape the issue names: reaping by
# existence would delete this run's disk out from under a running VM.
LIVE_INFO="$(make_run live-1 "$REPO_ONE")"
LIVE_PID="${LIVE_INFO%%	*}"
LIVE_SOCK_DIR="${LIVE_INFO#*	}"
LIVE_HOLDER="$(lock_holder "$ROOT/live-1/run.lock" live1 closed)"

# A dead run belonging to a DIFFERENT repo, so the sweep is shown to be
# host-scoped rather than per-repo.
OTHER_INFO="$(make_run dead-2 "$WORK/repo-two")"
OTHER_PID="${OTHER_INFO%%	*}"
: > "$ROOT/dead-2/run.lock"

sleep 1

# --dry-run first: it must reach the same verdicts and change nothing.
DRY_OUT="$(CLAUDE_VM_RUNS_ROOT="$ROOT" "$CLEANER" --dry-run 2>&1)"
assert_eq "cleaner --dry-run: reports both dead runs and the live one" \
  "2 dead run(s) would be reaped, 1 live run(s) spared, 0 skipped." \
  "$(printf '%s\n' "$DRY_OUT" | sed -n 's/^claude-vm-cleanup: \(.*would be reaped.*\)$/\1/p')"
assert_eq "cleaner --dry-run: the dead run dir still exists afterwards" \
  "present" "$(exists "$ROOT/dead-1")"
assert_eq "cleaner --dry-run: the recorded process is still alive afterwards" \
  "running" "$(alive "$DEAD_PID")"

# The real sweep.
OUT="$(CLAUDE_VM_RUNS_ROOT="$ROOT" "$CLEANER" 2>&1)"
sleep 1

assert_eq "cleaner: the dead run's dir is gone, clone included" \
  "absent" "$(exists "$ROOT/dead-1")"
assert_eq "cleaner: the dead run's guest-clone.raw is gone with it" \
  "absent" "$(exists "$ROOT/dead-1/guest-clone.raw")"
assert_eq "cleaner: the dead run's recorded process is killed" \
  "gone" "$(alive "$DEAD_PID")"
assert_eq "cleaner: the dead run's recorded socket dir is removed" \
  "absent" "$(exists "$DEAD_SOCK_DIR")"

assert_eq "cleaner: a dead run in ANOTHER repo is reaped in the same sweep (host-scoped)" \
  "absent" "$(exists "$ROOT/dead-2")"
assert_eq "cleaner: that other repo's recorded process is killed too" \
  "gone" "$(alive "$OTHER_PID")"

# The live sibling, untouched on every axis.
assert_eq "cleaner: the LIVE sibling's run dir survives" \
  "present" "$(exists "$ROOT/live-1")"
assert_eq "cleaner: the LIVE sibling's clone survives" \
  "present" "$(exists "$ROOT/live-1/guest-clone.raw")"
assert_eq "cleaner: the LIVE sibling's recorded process is NOT killed" \
  "running" "$(alive "$LIVE_PID")"
assert_eq "cleaner: the LIVE sibling's socket dir survives" \
  "present" "$(exists "$LIVE_SOCK_DIR")"
assert_eq "cleaner: it says so, naming the spared run" \
  "1" "$(printf '%s\n' "$OUT" | grep -c 'SPARED  live-1')"
assert_eq "cleaner: the tally reports 2 reaped and 1 spared" \
  "1" "$(printf '%s\n' "$OUT" | grep -c 'reaped 2 dead run(s), spared 1 live run(s), skipped 0')"

kill -9 "$LIVE_HOLDER" 2>/dev/null || true

# A run dir with NO run.lock at all -- a run that died before it took one.
# It is dead, and the test-acquire CREATES the file, which must not confuse
# the verdict.
mkdir -p "$ROOT/nolock-1"
printf 'run_id=nolock-1\nrepo_src=%s\n' "$REPO_ONE" > "$ROOT/nolock-1/run.meta"
NOLOCK_OUT="$(CLAUDE_VM_RUNS_ROOT="$ROOT" "$CLEANER" 2>&1)"
assert_eq "cleaner: a run dir with no run.lock is dead and is reaped" \
  "absent" "$(exists "$ROOT/nolock-1")"

# An empty runs root is a clean no-op, not an error.
EMPTY_ROOT="$WORK/empty-runs"
mkdir -p "$EMPTY_ROOT"
EMPTY_OUT="$(CLAUDE_VM_RUNS_ROOT="$EMPTY_ROOT" "$CLEANER" 2>&1)"
assert_eq "cleaner: an empty runs root reaps nothing and exits cleanly" \
  "1" "$(printf '%s\n' "$EMPTY_OUT" | grep -c 'reaped 0 dead run(s), spared 0 live run(s), skipped 0')"

# An ABSENT runs root likewise -- an operator who has never launched.
ABSENT_OUT="$(CLAUDE_VM_RUNS_ROOT="$WORK/never-existed" "$CLEANER" 2>&1)"
ABSENT_RC=$?
assert_eq "cleaner: an absent runs root exits 0 with a plain message" "0" "$ABSENT_RC"
assert_eq "cleaner: ...and says there is nothing to do" \
  "1" "$(printf '%s\n' "$ABSENT_OUT" | grep -c 'nothing to do')"

# A run.meta naming a socket dir that is NOT one of claude-vm's own mktemp
# dirs must not have an rm -rf aimed at it. The run dir is still reaped.
mkdir -p "$ROOT/badsock-1"
BADSOCK_DIR="$WORK/not-a-claude-vm-sock-dir"
mkdir -p "$BADSOCK_DIR"
{
  printf 'run_id=badsock-1\n'
  printf 'repo_src=%s\n' "$REPO_ONE"
  printf 'gvproxy_sock=%s/net.sock\n' "$BADSOCK_DIR"
} > "$ROOT/badsock-1/run.meta"
BADSOCK_OUT="$(CLAUDE_VM_RUNS_ROOT="$ROOT" "$CLEANER" 2>&1)"
assert_eq "cleaner: a foreign socket-dir path is left alone rather than rm -rf'd" \
  "present" "$(exists "$BADSOCK_DIR")"
assert_eq "cleaner: ...and it says why" \
  "1" "$(printf '%s\n' "$BADSOCK_OUT" | grep -c 'is not a claude-vm-sock.\* mktemp dir')"
assert_eq "cleaner: ...while still reaping that run's dir" \
  "absent" "$(exists "$ROOT/badsock-1")"

# ---------------------------------------------------------------------
echo ""
echo "runs-cleanup-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
