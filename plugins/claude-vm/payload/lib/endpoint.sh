#!/usr/bin/env bash
#
# endpoint.sh -- per-run network/IPC endpoint acquisition for claude-vm
# (issue #179).
#
# A claude-vm run owns two host endpoints that MUST be unique per run so that N
# concurrent runs off one immutable base image do not collide:
#
#   - an SSH-forward TCP port for gvproxy (gvproxy's -ssh-port; default 2222,
#     which every instance would otherwise grab -> the second run fails with
#     `bind: address already in use`);
#   - the gvproxy<->vfkit unixgram socket (net.sock).
#
# (There is no vfkit REST control socket: the guest powers itself off, so vfkit
# needs no host->guest REST channel -- issue #179.)
#
# A unique PATH is necessary but NOT sufficient: a stale socket file left by a
# dead run occupies the path with no listener, and bind() then fails
# `address already in use` exactly like a busy TCP port. So each acquisition
# here does two things: (1) verify the endpoint is not LIVE-in-use (a live
# listener), and (2) clear a stale corpse (a path that exists but has no
# listener) out of the way before the real consumer binds it.
#
# These helpers are PURE host-side probes (no VM, no network egress, no host
# mutation beyond removing a caller-owned stale socket file) so they are
# unit-testable. macOS-only, like the rest of claude-vm: they rely on tools
# that ship in the base macOS install (/usr/bin/perl, /usr/sbin/lsof), NOT on
# python3/nc/anything a user might not have.
#
# This file is idempotent to source (guarded below) and sets no global state.

# Guard against double-sourcing (the launcher and the test suite may both
# source this alongside config.sh).
if [ -n "${CLAUDE_VM_ENDPOINT_SH_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDE_VM_ENDPOINT_SH_SOURCED=1

# ---------------------------------------------------------------------
# claude_vm_tcp_port_in_use <port>
#
# Return 0 (true) when something is LISTENING on 127.0.0.1:<port> right now,
# 1 (false) when the port is free. Uses a real connect attempt via bash's
# /dev/tcp -- a connect that succeeds proves a live listener, which is the
# liveness signal we want (not "is a file present"). A refused/failed connect
# means nothing is accepting there.
#
# The connect is wrapped in a short-timeout subshell so a filtered/black-holed
# port cannot hang the probe. On a loopback address a live listener answers
# effectively instantly; 1s is generous.
# ---------------------------------------------------------------------
claude_vm_tcp_port_in_use() {
  local port="$1"
  # An empty/non-numeric port is never "in use" -- let the caller's own
  # validation handle the malformed case.
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # `timeout` is not on stock macOS; use a background connect + bounded wait.
  # bash /dev/tcp opens a TCP connection; success == a listener accepted it.
  (
    exec 3<>"/dev/tcp/127.0.0.1/$port"
  ) >/dev/null 2>&1 &
  local probe_pid=$!
  local waited=0
  while kill -0 "$probe_pid" 2>/dev/null; do
    if [ "$waited" -ge 10 ]; then
      kill "$probe_pid" 2>/dev/null || true
      wait "$probe_pid" 2>/dev/null || true
      # Hung connect -> treat as "in use" (something is there but not answering
      # cleanly); the caller will pick a different port, which is the safe bias.
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$probe_pid" 2>/dev/null
  return $?
}

# ---------------------------------------------------------------------
# claude_vm_acquire_free_tcp_port
#
# Race-safely obtain a free loopback TCP port and print it on stdout. Asks the
# kernel to assign an ephemeral port (bind to 127.0.0.1:0, read back the
# assigned port), which is the standard race-safe way to get a port nobody
# else holds -- far better than "pick 2222+N and hope". The socket is closed
# immediately, so there is a small TOCTOU window before the real consumer
# (gvproxy) binds it; the kernel avoids immediately re-handing a just-released
# ephemeral port, so in practice the assigned port is still free when gvproxy
# grabs it. The caller records the acquired port in run.meta the moment it is
# confirmed live.
#
# Returns 0 and prints the port on success; returns 1 and prints nothing if no
# port could be acquired (perl missing or bind failed).
# ---------------------------------------------------------------------
claude_vm_acquire_free_tcp_port() {
  local port
  port="$(
    /usr/bin/perl -MSocket -e '
      socket(S, PF_INET, SOCK_STREAM, getprotobyname("tcp")) or exit 1;
      bind(S, sockaddr_in(0, inet_aton("127.0.0.1"))) or exit 1;
      my ($p) = sockaddr_in(getsockname(S));
      print "$p\n";
      close(S);
    ' 2>/dev/null
  )" || return 1
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  echo "$port"
  return 0
}

# ---------------------------------------------------------------------
# claude_vm_unix_sock_live <path>
#
# Return 0 (true) when there is a LIVE listener bound to the AF_UNIX socket at
# <path>, 1 (false) when the path is absent OR is a stale corpse (a socket file
# with no process listening on it). `[ -S <path> ]` only tests that a socket
# FILE exists -- a corpse from a dead run passes that, which is exactly the bug
# in the old gvproxy readiness check. lsof reports which processes hold the
# socket open; if any process has it open, it is live.
#
# Requires /usr/sbin/lsof (base macOS). If lsof is somehow unavailable, we
# conservatively fall back to the file-existence test so the readiness loop
# does not falsely fail on a healthy run -- the liveness upgrade is best-effort
# hardening, not a hard dependency.
# ---------------------------------------------------------------------
claude_vm_unix_sock_live() {
  local path="$1"
  [ -n "$path" ] && [ -S "$path" ] || return 1
  if [ -x /usr/sbin/lsof ]; then
    # lsof exits 0 and prints a line when a process holds the socket open.
    if /usr/sbin/lsof -- "$path" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  # lsof missing: fall back to file existence (already true here).
  return 0
}

# ---------------------------------------------------------------------
# claude_vm_clear_stale_unix_sock <path>
#
# If <path> is a socket FILE with no live listener (a corpse from a dead run),
# remove it so the real consumer can bind() the path without hitting
# `address already in use`. If a live listener holds it, do NOT remove it and
# return 1 (the caller must pick a different path -- removing a live sibling's
# socket would break that sibling). If the path is absent, nothing to do.
#
# Returns 0 when the path is now free to bind (absent, or a corpse we cleared);
# returns 1 when a LIVE listener holds the path (caller must not use it).
# ---------------------------------------------------------------------
claude_vm_clear_stale_unix_sock() {
  local path="$1"
  [ -n "$path" ] || return 0
  if [ ! -e "$path" ]; then
    return 0
  fi
  if claude_vm_unix_sock_live "$path"; then
    # A live listener owns this path -- likely a concurrent sibling run. Do not
    # touch it.
    return 1
  fi
  # A corpse (socket file, or any leftover file at the path) with no listener:
  # clear it so bind() can reuse the path.
  rm -f "$path" 2>/dev/null || return 1
  return 0
}

# NOTE (issue #179): there are deliberately NO vfkit REST helpers here. An
# earlier pass drove guest shutdown from the host over vfkit's `--restful-uri`
# REST channel (POST {"state":"Stop"}/{"state":"HardStop"}). That model was
# replaced: the guest powers ITSELF off when claude quits (the boot launcher
# runs `systemctl poweroff` on claude's exit 0), so vfkit needs no REST control
# socket and the host needs no shutdown driver -- vfkit runs foreground and
# exits on its own when the guest halts.
