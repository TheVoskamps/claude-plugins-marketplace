#!/usr/bin/env bash
#
# ch-capture-test.sh -- drive the real ch-capture launcher, under the
# bash 3.2 macOS ships, against a stub `claude` that records its argv and
# environment and sends one request through the proxy it was pointed at.
#
# Every case gets its own XDG_STATE_HOME, so the capture root holds
# exactly the one session directory that case created.
#
# Usage: ch-capture-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$TEST_DIR/../bin/ch-capture"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ch-capture-test.XXXXXX")"
FAILURES=0

check() {
  if [ "$1" = "$2" ]; then
    echo "PASS  $3"
  else
    echo "FAIL  $3"
    echo "      expected: $2"
    echo "      actual:   $1"
    FAILURES=$((FAILURES + 1))
  fi
}

# A stub `claude`: one argv entry per line into $STUB_OUT/argv and the
# base URL it was given into $STUB_OUT/base-url. With STUB_REQUEST=1 it
# also sends one GET through that URL; only a case whose upstream is a
# dead port sets it, so no case ever reaches the real API.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/claude" <<'STUB'
#!/usr/bin/env bash
: >"$STUB_OUT/argv"
for arg in "$@"; do printf '%s\n' "$arg" >>"$STUB_OUT/argv"; done
printf '%s\n' "${ANTHROPIC_BASE_URL:-}" >"$STUB_OUT/base-url"
if [ "${STUB_REQUEST:-}" = 1 ]; then
  python3 - "$ANTHROPIC_BASE_URL" >"$STUB_OUT/status" <<'PY'
import sys, urllib.error, urllib.request
try:
    print(urllib.request.urlopen(sys.argv[1] + "/v1/ping", timeout=10).status)
except urllib.error.HTTPError as error:
    print(error.code)
PY
fi
if [ -n "${STUB_SLEEP:-}" ]; then sleep "$STUB_SLEEP"; fi
exit "${STUB_RC:-0}"
STUB
chmod +x "$SANDBOX/bin/claude"

# A port nothing listens on, so every forwarded request is a 502 rather
# than a call to the real API.
CLOSED_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
DEAD_UPSTREAM="http://127.0.0.1:$CLOSED_PORT"

REPO="$SANDBOX/repo"
mkdir -p "$REPO/sub/dir"
git -C "$REPO" init -q
git -C "$REPO" remote add origin git@github.com:someone/widget.git
PLAIN="$SANDBOX/plain"
mkdir -p "$PLAIN"

# run_case <case-name> <cwd> <launcher args...>; leaves CASE_OUT and
# SESSION_DIR set and the launcher's exit status in CASE_RC.
run_case() {
  local name="$1" cwd="$2"
  shift 2
  CASE_OUT="$SANDBOX/$name"
  mkdir -p "$CASE_OUT/state"
  (
    cd "$cwd" || exit 99
    PATH="$SANDBOX/bin:$PATH" STUB_OUT="$CASE_OUT" XDG_STATE_HOME="$CASE_OUT/state" \
      GIT_CEILING_DIRECTORIES="$SANDBOX" /bin/bash "$LAUNCHER" "$@" 2>"$CASE_OUT/stderr"
  )
  CASE_RC=$?
  SESSION_DIR="$(find "$CASE_OUT/state/claude-harness-tools/captures" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
}

session_field() {
  python3 -c 'import json, sys; v = json.load(open(sys.argv[1]))[sys.argv[2]]; print(v if isinstance(v, (str, int)) else json.dumps(v))' \
    "$SESSION_DIR/session.json" "$1"
}

proxy_stopped() {
  if python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2)' \
    "$(session_field port)" 2>/dev/null; then
    echo "running"
  else
    echo "stopped"
  fi
}

argv_line() {
  sed -n "${1}p" "$CASE_OUT/argv"
}

# --- suffix, repo, forwarded args, default upstream -------------------
unset ANTHROPIC_BASE_URL
run_case named "$REPO/sub/dir" my run -- --flag "two words" -p
check "$CASE_RC" "0" "a clean claude exit is ch-capture's exit"
check "$(cat "$CASE_OUT/argv" | tr '\n' '|')" "--flag|two words|-p|--name|my run widget [harness-proxy]|" \
  "args after -- reach claude unchanged, followed by the computed --name"
check "$(session_field name)" "my run widget [harness-proxy]" "the session is named <suffix> <repo> [harness-proxy]"
check "$(session_field repo)" "widget" "repo is origin's last path segment minus .git"
check "$(session_field cwd)" "$(cd "$REPO" && pwd -P)" "claude runs from the repo root"
check "$(session_field upstream)" "https://api.anthropic.com" "upstream defaults to https://api.anthropic.com"
check "$(cat "$CASE_OUT/base-url")" "http://127.0.0.1:$(session_field port)" "claude is pointed at the proxy's port"
check "$(basename "$SESSION_DIR" | sed 's/^[0-9T.]*Z-//')" "my-run-widget-harness-proxy" "the session directory ends in the slugified name"
check "$(basename "$SESSION_DIR" | grep -cE '^[0-9]{8}T[0-9]{6}\.[0-9]{3}Z-')" "1" "the session directory starts with a millisecond stamp"
check "$(proxy_stopped)" "stopped" "the proxy is stopped after a normal exit"

# --- caller-supplied --name, both spellings ---------------------------
run_case name-space "$REPO" ignored suffix -- --name "Mine"
check "$(cat "$CASE_OUT/argv" | tr '\n' '|')" "--name|Mine [harness-proxy]|" "--name <v> is tagged in place and wins"
check "$(session_field name)" "Mine [harness-proxy]" "session.json carries the caller's tagged name"
run_case name-equals "$REPO" -- --name=Other -c
check "$(cat "$CASE_OUT/argv" | tr '\n' '|')" "--name=Other [harness-proxy]|-c|" "--name=<v> is tagged in place and wins"
run_case name-bare "$REPO" bare -- -c --name
check "$(cat "$CASE_OUT/argv" | tr '\n' '|')" "-c|--name|bare widget [harness-proxy]|" \
  "a trailing --name with no value is replaced by the computed --name"
run_case name-only-bare "$REPO" lone -- --name
check "$(cat "$CASE_OUT/argv" | tr '\n' '|')" "--name|lone widget [harness-proxy]|" \
  "a lone valueless --name is replaced by the computed --name"

# --- no repo, no suffix, caller's upstream, error exit ----------------
ANTHROPIC_BASE_URL="$DEAD_UPSTREAM" STUB_RC=3 STUB_REQUEST=1 run_case plain "$PLAIN"
check "$CASE_RC" "3" "a failing claude's status is ch-capture's exit"
check "$(session_field repo)" "(local)" "repo is (local) outside a git repo"
check "$(session_field name | grep -cE '^[A-Z][a-z]{2}[0-9]{2}-[0-9]{2}:[0-9]{2} \(local\) \[harness-proxy\]$')" "1" \
  "with no suffix the name opens with a date stamp"
check "$(session_field upstream)" "$DEAD_UPSTREAM" "upstream is the ANTHROPIC_BASE_URL in force at launch"
check "$(cat "$CASE_OUT/status")" "502" "a request from claude passes through the proxy"
check "$(find "$SESSION_DIR/000001" -type f | wc -l | tr -d ' ')" "4" "that request left a four-file request directory"
check "$(proxy_stopped)" "stopped" "the proxy is stopped after an error exit"

# --- Ctrl-C and SIGTERM ------------------------------------------------
# Job control puts the launcher in a process group of its own, so the
# INT below reaches the launcher and its claude the way a terminal's
# Ctrl-C reaches a foreground job.
set -m
for signal in INT TERM; do
  CASE_OUT="$SANDBOX/signal-$signal"
  mkdir -p "$CASE_OUT/state"
  (
    cd "$REPO" || exit 99
    PATH="$SANDBOX/bin:$PATH" STUB_OUT="$CASE_OUT" XDG_STATE_HOME="$CASE_OUT/state" STUB_SLEEP=3 \
      exec /bin/bash "$LAUNCHER" "$signal" 2>"$CASE_OUT/stderr"
  ) &
  JOB_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$CASE_OUT/base-url" ] && break
    sleep 0.1
  done
  SESSION_DIR="$(find "$CASE_OUT/state/claude-harness-tools/captures" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ "$signal" = INT ]; then
    kill -INT -- "-$JOB_PID"
  else
    kill -TERM "$JOB_PID"
  fi
  wait "$JOB_PID"
  check "$(proxy_stopped)" "stopped" "the proxy is stopped after SIG$signal"
done
set +m

if [ "$FAILURES" -gt 0 ]; then
  echo
  echo "$FAILURES failure(s); sandbox left at $SANDBOX"
  exit 1
fi
rm -rf "$SANDBOX"
echo
echo "all passed"
