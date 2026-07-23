#!/usr/bin/env bash
#
# endpoint-test.sh -- unit tests for claude-vm's per-run endpoint acquisition
# (payload/lib/endpoint.sh, issue #179).
#
# Exercises the PURE host-side endpoint primitives -- free-TCP-port
# acquisition, TCP-port liveness, unix-socket liveness (live listener vs stale
# corpse), and stale-corpse clearing -- with no VM and no vfkit. Real listeners
# are stood up with the base-macOS perl (TCP via IO::Socket::INET, unix via
# IO::Socket::UNIX) so the liveness checks are tested against genuine live and
# genuinely-dead endpoints, which is the exact bug class defect #4 is about (a
# stale socket FILE passing a mere `[ -S ]` existence check).
#
# Run directly:
#
#   plugins/claude-vm/payload/test/endpoint-test.sh
#
# Requires: /usr/bin/perl (base macOS). Skips cleanly if absent.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../lib/endpoint.sh"

# shellcheck source=../lib/endpoint.sh
. "$LIB"

if [ ! -x /usr/bin/perl ]; then
  echo "SKIP: /usr/bin/perl not available; endpoint tests skipped." >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-endpoint-test.XXXXXX")"
# Track any listener pids we spawn so a failure never leaves one behind.
LISTENER_PIDS=()
cleanup_test() {
  local p
  for p in ${LISTENER_PIDS[@]+"${LISTENER_PIDS[@]}"}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup_test EXIT

PASS=0
FAIL=0

assert_true() {
  local label="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); echo "ok   - $label"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $label (expected success, got failure)"
  fi
}

assert_false() {
  local label="$1"; shift
  if "$@"; then
    FAIL=$((FAIL + 1)); echo "FAIL - $label (expected failure, got success)"
  else
    PASS=$((PASS + 1)); echo "ok   - $label"
  fi
}

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

# ---------------------------------------------------------------------
# Real-listener helpers (perl)
# ---------------------------------------------------------------------

# Start a TCP listener on 127.0.0.1:<port>, backgrounded. Prints the pid on
# stdout. The listener's own stdout/stderr are redirected to /dev/null so a
# `$(...)` capture of the pid does not block waiting for the backgrounded
# process to close the inherited stdout fd.
start_tcp_listener() {
  local port="$1"
  /usr/bin/perl -MIO::Socket::INET -e '
    my $s = IO::Socket::INET->new(
      LocalAddr => "127.0.0.1", LocalPort => $ARGV[0],
      Proto => "tcp", Listen => 1, ReuseAddr => 1) or exit 1;
    sleep 30;
  ' "$port" >/dev/null 2>&1 &
  echo $!
}

# Start a unix-domain listener bound to <path>, backgrounded. Returns its pid.
# stdout/stderr redirected for the same reason as start_tcp_listener.
start_unix_listener() {
  local path="$1"
  /usr/bin/perl -MIO::Socket::UNIX -e '
    my $s = IO::Socket::UNIX->new(
      Local => $ARGV[0], Listen => 1) or exit 1;
    sleep 30;
  ' "$path" >/dev/null 2>&1 &
  echo $!
}

# ---------------------------------------------------------------------
# claude_vm_acquire_free_tcp_port
# ---------------------------------------------------------------------
PORT="$(claude_vm_acquire_free_tcp_port)"
RC=$?
assert_eq "acquire_free_tcp_port: succeeds (rc 0)" 0 "$RC"
case "$PORT" in
  ''|*[!0-9]*) FAIL=$((FAIL + 1)); echo "FAIL - acquire_free_tcp_port: prints a numeric port (got [$PORT])" ;;
  *)           PASS=$((PASS + 1)); echo "ok   - acquire_free_tcp_port: prints a numeric port ($PORT)" ;;
esac

# Two acquisitions should (almost always) differ -- the kernel hands out
# distinct ephemeral ports for two simultaneous binds. This guards the
# concurrency intent: N runs each get their own port.
P1="$(claude_vm_acquire_free_tcp_port)"
P2="$(claude_vm_acquire_free_tcp_port)"
if [ -n "$P1" ] && [ -n "$P2" ]; then
  PASS=$((PASS + 1)); echo "ok   - acquire_free_tcp_port: two acquisitions both numeric ($P1, $P2)"
else
  FAIL=$((FAIL + 1)); echo "FAIL - acquire_free_tcp_port: two acquisitions numeric"
fi

# ---------------------------------------------------------------------
# claude_vm_tcp_port_in_use
# ---------------------------------------------------------------------
# A freshly-acquired (unbound) port is NOT in use.
FREE_PORT="$(claude_vm_acquire_free_tcp_port)"
assert_false "tcp_port_in_use: a free port reads not-in-use" \
  claude_vm_tcp_port_in_use "$FREE_PORT"

# Stand up a real listener, then it MUST read in-use.
LPORT="$(claude_vm_acquire_free_tcp_port)"
LPID="$(start_tcp_listener "$LPORT")"
LISTENER_PIDS+=("$LPID")
# Give perl a moment to bind.
for _ in $(seq 1 30); do claude_vm_tcp_port_in_use "$LPORT" && break; sleep 0.1; done
assert_true "tcp_port_in_use: a live listener reads in-use" \
  claude_vm_tcp_port_in_use "$LPORT"

# After the listener dies, the port reads free again.
kill "$LPID" 2>/dev/null || true
wait "$LPID" 2>/dev/null || true
for _ in $(seq 1 30); do claude_vm_tcp_port_in_use "$LPORT" || break; sleep 0.1; done
assert_false "tcp_port_in_use: a dead listener's port reads not-in-use" \
  claude_vm_tcp_port_in_use "$LPORT"

# Malformed input never reads as in-use.
assert_false "tcp_port_in_use: empty input reads not-in-use" \
  claude_vm_tcp_port_in_use ""
assert_false "tcp_port_in_use: non-numeric input reads not-in-use" \
  claude_vm_tcp_port_in_use "not-a-port"

# ---------------------------------------------------------------------
# claude_vm_unix_sock_live -- the CORE of defect #4: a stale socket FILE with
# no listener must NOT read as live (the old `[ -S ]` check got this wrong).
# ---------------------------------------------------------------------
# Absent path: not live.
assert_false "unix_sock_live: absent path is not live" \
  claude_vm_unix_sock_live "$WORK/absent.sock"

# A live listener: live.
LIVE_SOCK="$WORK/live.sock"
USPID="$(start_unix_listener "$LIVE_SOCK")"
LISTENER_PIDS+=("$USPID")
for _ in $(seq 1 30); do [ -S "$LIVE_SOCK" ] && break; sleep 0.1; done
assert_true "unix_sock_live: a live listener's socket is live" \
  claude_vm_unix_sock_live "$LIVE_SOCK"

# Kill the listener but LEAVE the socket file behind -> a corpse. It must read
# NOT live even though the file still exists.
kill "$USPID" 2>/dev/null || true
wait "$USPID" 2>/dev/null || true
# The perl listener does not unlink on kill, so the file lingers -- exactly the
# stale-corpse scenario. Recreate it explicitly if the OS cleaned it up, so the
# test deterministically exercises "file present, no listener".
[ -e "$LIVE_SOCK" ] || : > "$LIVE_SOCK"
if [ -e "$LIVE_SOCK" ]; then
  PASS=$((PASS + 1)); echo "ok   - unix_sock_live: corpse setup (socket file lingers)"
else
  FAIL=$((FAIL + 1)); echo "FAIL - unix_sock_live: corpse setup (socket file lingers)"
fi
assert_false "unix_sock_live: a stale corpse (file, no listener) is NOT live" \
  claude_vm_unix_sock_live "$LIVE_SOCK"

# ---------------------------------------------------------------------
# claude_vm_clear_stale_unix_sock
# ---------------------------------------------------------------------
# Absent path: nothing to do, returns 0 (free to bind).
assert_true "clear_stale_unix_sock: absent path -> free to bind (rc 0)" \
  claude_vm_clear_stale_unix_sock "$WORK/nope.sock"

# A corpse: cleared, path now gone, returns 0.
CORPSE="$WORK/corpse.sock"
: > "$CORPSE"
assert_true "clear_stale_unix_sock: corpse -> cleared (rc 0)" \
  claude_vm_clear_stale_unix_sock "$CORPSE"
if [ -e "$CORPSE" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL - clear_stale_unix_sock: corpse file removed"
else
  PASS=$((PASS + 1)); echo "ok   - clear_stale_unix_sock: corpse file removed"
fi

# A LIVE listener's path: NOT cleared, returns 1 (caller must not stomp it),
# and the socket file survives.
GUARD_SOCK="$WORK/guard.sock"
GPID="$(start_unix_listener "$GUARD_SOCK")"
LISTENER_PIDS+=("$GPID")
for _ in $(seq 1 30); do [ -S "$GUARD_SOCK" ] && break; sleep 0.1; done
assert_false "clear_stale_unix_sock: live listener path -> refuses (rc 1)" \
  claude_vm_clear_stale_unix_sock "$GUARD_SOCK"
if [ -S "$GUARD_SOCK" ]; then
  PASS=$((PASS + 1)); echo "ok   - clear_stale_unix_sock: live listener's socket left intact"
else
  FAIL=$((FAIL + 1)); echo "FAIL - clear_stale_unix_sock: live listener's socket left intact"
fi
kill "$GPID" 2>/dev/null || true

# ---------------------------------------------------------------------
# claude_vm_vfkit_request_stop / claude_vm_vfkit_hard_stop
#
# These POST to vfkit's REST control socket. Test them against a tiny perl
# unix-socket HTTP server that answers ONE request with a fixed status, so the
# 2xx-vs-error contract the cleanup() fallback ladder depends on is exercised
# without a real vfkit. (A 4xx models vfkit refusing the stop because the guest
# is not booted far enough for canRequestStop -> caller falls back to force.)
# ---------------------------------------------------------------------
if [ ! -x /usr/bin/curl ]; then
  echo "SKIP: /usr/bin/curl not available; vfkit REST-call tests skipped." >&2
else
  # start_http_unix <path> <status-line> -> pid. Serves exactly one connection
  # with the given HTTP status, then exits. stdout redirected so $(...) does not
  # block on the inherited fd.
  start_http_unix() {
    local path="$1" status="$2"
    /usr/bin/perl -MIO::Socket::UNIX -e '
      my ($p, $st) = @ARGV;
      my $srv = IO::Socket::UNIX->new(Local => $p, Listen => 1) or exit 1;
      my $c = $srv->accept() or exit 1;
      # Drain the request headers (up to the blank line) so curl can send its body.
      local $/ = "\r\n";
      while (my $l = <$c>) { last if $l eq "\r\n"; }
      print $c "HTTP/1.1 $st\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
      close $c;
    ' "$path" "$status" >/dev/null 2>&1 &
    echo $!
  }

  # Absent socket -> request_stop fails (nothing to POST to).
  assert_false "vfkit_request_stop: absent socket -> failure" \
    claude_vm_vfkit_request_stop "$WORK/no-vfkit.sock"

  # A 200 responder -> request_stop succeeds.
  OK_SOCK="$WORK/vfkit-ok.sock"
  HPID="$(start_http_unix "$OK_SOCK" "200 OK")"
  LISTENER_PIDS+=("$HPID")
  for _ in $(seq 1 30); do [ -S "$OK_SOCK" ] && break; sleep 0.1; done
  assert_true "vfkit_request_stop: 200 response -> success" \
    claude_vm_vfkit_request_stop "$OK_SOCK"
  kill "$HPID" 2>/dev/null || true

  # A 400 responder (models canRequestStop false) -> request_stop FAILS, so the
  # caller falls back to HardStop/force. This is the crucial contract.
  BAD_SOCK="$WORK/vfkit-bad.sock"
  BPID="$(start_http_unix "$BAD_SOCK" "400 Bad Request")"
  LISTENER_PIDS+=("$BPID")
  for _ in $(seq 1 30); do [ -S "$BAD_SOCK" ] && break; sleep 0.1; done
  assert_false "vfkit_request_stop: 4xx response -> failure (caller must force)" \
    claude_vm_vfkit_request_stop "$BAD_SOCK"
  kill "$BPID" 2>/dev/null || true

  # hard_stop honors the same 2xx contract.
  HS_SOCK="$WORK/vfkit-hardstop.sock"
  HSPID="$(start_http_unix "$HS_SOCK" "200 OK")"
  LISTENER_PIDS+=("$HSPID")
  for _ in $(seq 1 30); do [ -S "$HS_SOCK" ] && break; sleep 0.1; done
  assert_true "vfkit_hard_stop: 200 response -> success" \
    claude_vm_vfkit_hard_stop "$HS_SOCK"
  kill "$HSPID" 2>/dev/null || true

  assert_false "vfkit_hard_stop: absent socket -> failure" \
    claude_vm_vfkit_hard_stop "$WORK/no-vfkit2.sock"
fi

# ---------------------------------------------------------------------
echo ""
echo "endpoint-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
