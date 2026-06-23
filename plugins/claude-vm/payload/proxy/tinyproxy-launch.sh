#!/usr/bin/env bash
#
# tinyproxy-launch.sh -- the BUNDLED DEFAULT claude-vm forward proxy.
#
# This is the default `proxy.cmd`: claude-vm.sh runs it (via `eval`) to
# start the forward proxy that confines the guest's egress to the
# allowlist. It bridges the launcher's interface to tinyproxy:
#
#   - reads the egress allowlist from $CLAUDE_VM_EGRESS_ALLOWLIST (the
#     newline-delimited host file claude-vm.sh writes from egress.allow),
#   - renders a tinyproxy.conf whose `Allow`/`Filter` directives confine
#     outbound connections to exactly those hosts (FAIL-CLOSED: an empty
#     allowlist permits nothing),
#   - binds the port the guest's HTTPS_PROXY points at ($CLAUDE_VM_PROXY_PORT),
#   - execs tinyproxy in the foreground so claude-vm.sh's PROXY_PID tracks
#     the real proxy process and its EXIT/INT/TERM trap kills it cleanly.
#
# tinyproxy is configured by a conf file rather than flags for
# host-allowlisting, so this wrapper renders the conf from the
# launcher-provided allowlist instead of carrying a baked-in list. The
# global-config skill's `proxy.cmd` default points here.
#
# Requires: tinyproxy (brew install tinyproxy).

set -euo pipefail

ALLOWLIST="${CLAUDE_VM_EGRESS_ALLOWLIST:?tinyproxy-launch: CLAUDE_VM_EGRESS_ALLOWLIST is not set (the launcher exports it)}"
PORT="${CLAUDE_VM_PROXY_PORT:-3128}"
# Bind address the guest reaches the proxy on. The guest's HTTPS_PROXY
# targets the gvproxy host alias, which gvproxy forwards to a listener on
# the host loopback, so binding 127.0.0.1 is correct and avoids exposing
# the proxy on other host interfaces. Overridable for unusual setups.
LISTEN_ADDR="${CLAUDE_VM_PROXY_LISTEN_ADDR:-127.0.0.1}"

command -v tinyproxy >/dev/null 2>&1 || {
  echo "tinyproxy-launch: 'tinyproxy' is required (brew install tinyproxy) but was not found on PATH." >&2
  exit 1
}
[ -f "$ALLOWLIST" ] || {
  echo "tinyproxy-launch: allowlist file does not exist: $ALLOWLIST" >&2
  exit 1
}

# Render the tinyproxy conf alongside the allowlist (the launcher's
# per-run CONFIG_DIR), so it is removed when the run dir is. A transient
# TMPDIR file would leak: this script ends in `exec tinyproxy`, which
# replaces the process before any EXIT trap could fire. Anchoring the conf
# to the run-owned dir sidesteps that -- the launcher owns its lifecycle.
# Created with a tightened umask; it carries no secret but owner-only is tidy.
CONF_DIR="$(cd "$(dirname "$ALLOWLIST")" && pwd)"
umask 077
CONF="$CONF_DIR/tinyproxy.conf"
FILTER="$CONF_DIR/tinyproxy.filter"

{
  printf 'Port %s\n' "$PORT"
  printf 'Listen %s\n' "$LISTEN_ADDR"
  printf 'Timeout 600\n'
  # No on-disk logging by default; surface to the launcher's stderr.
  printf 'LogLevel Notice\n'

  # Egress confinement. tinyproxy's `Filter` applies a host allowlist when
  # FilterDefaultDeny is on: only hosts matching a filter line are
  # permitted; everything else is refused. This is the fail-closed
  # behavior the launcher's empty-allowlist warning depends on -- an empty
  # allowlist file yields an empty filter file, so NOTHING is permitted.
  printf 'FilterDefaultDeny Yes\n'
  printf 'FilterExtended On\n'
  printf 'Filter "%s"\n' "$FILTER"
} > "$CONF"

# Build the filter file: one anchored regex per allowlisted host so a host
# matches itself exactly (and its subdomains), not as a substring of an
# unrelated host. Blank lines and comments in the allowlist are skipped.
: > "$FILTER"
while IFS= read -r host; do
  # Trim surrounding whitespace.
  host="${host#"${host%%[![:space:]]*}"}"
  host="${host%"${host##*[![:space:]]}"}"
  [ -z "$host" ] && continue
  case "$host" in \#*) continue ;; esac
  # Escape regex-significant dots; anchor so "github.com" matches
  # "github.com" and "*.github.com" but not "evilgithub.com".
  esc="$(printf '%s\n' "$host" | sed 's/\./\\./g')"
  printf '(^|\\.)%s$\n' "$esc" >> "$FILTER"
done < "$ALLOWLIST"

echo "tinyproxy-launch: starting tinyproxy on $LISTEN_ADDR:$PORT, egress confined to $ALLOWLIST" >&2

# Foreground (-d) so the launcher's PROXY_PID is the real tinyproxy and its
# trap can kill it. -c points at the rendered conf.
exec tinyproxy -d -c "$CONF"
