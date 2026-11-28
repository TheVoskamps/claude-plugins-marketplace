#!/usr/bin/env bash
#
# sdlc-pr-monitor-test.sh -- drive plugins/sdlc/bin/sdlc-pr-monitor
# against stub pr-view and pr-ready-to-merge executables serving a
# scripted sequence of polls, and a stub sleep executable that advances
# a fake clock, so no case waits: each terminal line, the gate's report
# compacted onto the poll line, a gate exit 3 for a merge state still
# UNKNOWN and for a PR that merged or closed after the state read, the
# unchanged-poll bound, a state change resetting the count, one run
# polling on to a terminal line however long it takes, the sleep
# chunking of a long interval, a recoverable pr-view or
# pr-ready-to-merge failure retried after the retry wait up to the retry
# limit, the usage errors, a failing pr-view or pr-ready-to-merge, a
# failing command the script does not wrap, and a failing removal of the
# temporary file on exit.
#
# Needs bash and the POSIX utilities. Reaches no network.
#
# Usage: sdlc-pr-monitor-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR="$TEST_DIR/../bin/sdlc-pr-monitor"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-pr-monitor-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0
PR='h.example/o/r#7'

# check <actual> <expected> <label>: passes when the two are equal, and
# otherwise prints both and counts a failure in FAILURES.
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

# check_contains <actual> <substring> <label>: passes when the actual
# text contains the substring, and otherwise prints both and counts a
# failure in FAILURES.
check_contains() {
  case "$1" in
    *"$2"*) echo "PASS  $3" ;;
    *)
      echo "FAIL  $3"
      echo "      expected to contain: $2"
      echo "      actual:              $1"
      FAILURES=$((FAILURES + 1))
      ;;
  esac
}

# The stubs. pr-view and pr-ready-to-merge each serve the file for their
# n-th call, <kind>.<n>, and repeat <kind>.last past the end, logging
# their arguments to <kind>.args; when <kind>.fail exists they print it
# and exit 1 instead, and when <kind>.err.<n> exists the n-th call
# prints it on stderr alone and exits 1. When <kind>.rc.<n> exists the
# n-th call exits with the status it holds after serving its file.
# sleep adds its argument to the fake clock and logs it.
mkdir -p "$SANDBOX/bin"
for kind in view gate; do
  case "$kind" in
    view) name=pr-view ;;
    gate) name=pr-ready-to-merge ;;
  esac
  cat >"$SANDBOX/bin/$name" <<EOF
#!/bin/sh
d="$SANDBOX/serve"
n=\$(cat "\$d/$kind.n" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" >"\$d/$kind.n"
echo "\$*" >>"\$d/$kind.args"
if [ -f "\$d/$kind.fail" ]; then
  cat "\$d/$kind.fail"
  echo "$name: stub failure" >&2
  exit 1
fi
if [ -f "\$d/$kind.err.\$n" ]; then
  cat "\$d/$kind.err.\$n" >&2
  exit 1
fi
if [ -f "\$d/$kind.\$n" ]; then cat "\$d/$kind.\$n"; else cat "\$d/$kind.last"; fi
if [ -f "\$d/$kind.rc.\$n" ]; then
  echo "$name: stub exit \$(cat "\$d/$kind.rc.\$n")" >&2
  exit "\$(cat "\$d/$kind.rc.\$n")"
fi
EOF
done
cat >"$SANDBOX/bin/sleep" <<EOF
#!/bin/sh
echo "\$1" >>"$SANDBOX/serve/sleeps"
c=\$(cat "$SANDBOX/serve/clock")
echo \$((c + \$1)) >"$SANDBOX/serve/clock"
EOF
chmod +x "$SANDBOX/bin/"*

# reset: empties the served sequences, the sleep log and the counters,
# and sets the fake clock.
reset() {
  rm -rf "$SANDBOX/serve"
  mkdir -p "$SANDBOX/serve"
  echo 1000 >"$SANDBOX/serve/clock"
  : >"$SANDBOX/serve/sleeps"
}

# serve <kind> <file>...: serves each file's text in turn as the n-th
# call's output, the last one repeating.
serve() {
  local kind=$1 n=0 f
  shift
  for f in "$@"; do
    n=$((n + 1))
    cp "$f" "$SANDBOX/serve/$kind.$n"
  done
  cp "$f" "$SANDBOX/serve/$kind.last"
}

# block <name> <mergeStateStatus> [<running check>]: writes a gate report
# to $SANDBOX/<name>, in the shape pr-ready-to-merge prints.
block() {
  {
    echo "PR $PR: mergeable MERGEABLE, mergeStateStatus $2 — meaning"
    echo "reviewDecision: REVIEW_REQUIRED"
    if [ -n "${3:-}" ]; then
      printf 'checks running:\n  %s: status IN_PROGRESS\n' "$3"
    else
      echo "checks running: none"
    fi
    echo "checks not green: none"
  } >"$SANDBOX/$1"
}

for s in OPEN MERGED CLOSED; do echo "$s" >"$SANDBOX/$s"; done
block blocked BLOCKED
block blocked-ci BLOCKED ci
block clean CLEAN
block behind BEHIND
block dirty DIRTY
printf 'PR %s: merge state still computing, attempt 2 of 3 — waiting 10 s.\n' "$PR" >"$SANDBOX/blocked-wait"
cat "$SANDBOX/blocked" >>"$SANDBOX/blocked-wait"
sed 's/^  /	/' "$SANDBOX/blocked-ci" >"$SANDBOX/blocked-ci-tab"
sed 's/mergeable MERGEABLE, mergeStateStatus BLOCKED — .*/mergeable UNKNOWN, mergeStateStatus UNKNOWN — still computing after the whole retry schedule/' \
  "$SANDBOX/blocked" >"$SANDBOX/unknown"
: >"$SANDBOX/empty"

# run <arg>...: runs the monitor with the stubs first on PATH, leaving
# stdout in OUT, stderr in ERR, the status in RC, the last stdout line
# in LAST, the sleep log in SLEEPS and the fake seconds slept in SLEPT.
run() {
  OUT=$(PATH="$SANDBOX/bin:$PATH" "$MONITOR" "$@" 2>"$SANDBOX/err")
  RC=$?
  ERR=$(cat "$SANDBOX/err")
  LAST=${OUT##*$'\n'}
  SLEEPS=$(tr '\n' ' ' <"$SANDBOX/serve/sleeps")
  SLEPT=$(($(cat "$SANDBOX/serve/clock") - 1000))
}

# polls: the number of `Polled` lines in OUT.
polls() {
  printf '%s\n' "$OUT" | grep -c '^Polled '
}

# --- each terminal line -----------------------------------------------

reset
serve view "$SANDBOX/MERGED"
run "$PR" 60 3 45 2
check "$RC" 0 "merged: exit 0"
check "$OUT" "Polled $PR: MERGED
Merged" "merged: the poll line, then Merged"
check "$SLEEPS" "" "merged: no wait before the first poll"
check "$(cat "$SANDBOX/serve/view.args")" "$PR --json state,mergedAt,closedAt --jq .state" "merged: pr-view reads the state"
check "$(cat "$SANDBOX/serve/gate.n" 2>/dev/null || echo 0)" 0 "merged: the gate does not run on a merged PR"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/CLOSED"
serve gate "$SANDBOX/blocked"
run "$PR" 60 3 45 2
check "$RC" 0 "closed: exit 0"
check "$LAST" "Closed without merging" "closed: the terminal line"
check "$(polls)" 2 "closed: a poll per interval"
check "$SLEEPS" "60 " "closed: one wait between the polls"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked" "$SANDBOX/behind"
run "$PR" 60 3 45 2
check "$RC" 0 "behind: exit 0"
check "$LAST" "BEHIND" "behind: the terminal line"
check_contains "$OUT" "Polled $PR: OPEN; PR $PR: mergeable MERGEABLE, mergeStateStatus BEHIND" "behind: the poll line carries the gate's state"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/dirty"
run "$PR" 60 3 45 2
check "$RC" 0 "dirty: exit 0"
check "$LAST" "DIRTY" "dirty: the terminal line"
check "$(polls)" 1 "dirty: one poll"

# --- the poll line ----------------------------------------------------

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked-ci" "$SANDBOX/blocked-wait"
run "$PR" 60 3 45 2
check "$(printf '%s\n' "$OUT" | sed -n 1p)" \
  "Polled $PR: OPEN; PR $PR: mergeable MERGEABLE, mergeStateStatus BLOCKED — meaning; reviewDecision: REVIEW_REQUIRED; checks running: ci: status IN_PROGRESS; checks not green: none" \
  "poll line: the report on one line, a check entry joined onto its label"
check_contains "$(printf '%s\n' "$OUT" | sed -n 2p)" "mergeStateStatus BLOCKED" "poll line: a gate wait announcement is dropped"
check "$(printf '%s\n' "$OUT" | grep -c 'still computing')" 0 "poll line: no wait announcement reaches stdout"
check "$LAST" "Merged" "poll line: polling continues past BLOCKED"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked-ci-tab"
run "$PR" 60 3 45 2
check_contains "$(printf '%s\n' "$OUT" | sed -n 1p)" "checks running: ci: status IN_PROGRESS; checks not green" \
  "poll line: a tab-indented check entry is joined onto its label"

# --- a gate exit 3 --------------------------------------------------------

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/unknown" "$SANDBOX/behind"
echo 3 >"$SANDBOX/serve/gate.rc.1"
run "$PR" 60 3 45 2
check "$RC" 0 "still unknown: exit 0"
check_contains "$(printf '%s\n' "$OUT" | sed -n 1p)" "mergeable UNKNOWN, mergeStateStatus UNKNOWN" "still unknown: the poll line carries the UNKNOWN report"
check "$(polls)" 2 "still unknown: polled again"
check "$LAST" "BEHIND" "still unknown: polling goes on to the next state"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/empty"
echo 3 >"$SANDBOX/serve/gate.rc.1"
run "$PR" 60 3 45 2
check "$RC" 0 "merged under the gate: exit 0"
check "$OUT" "Polled $PR: MERGED
Merged" "merged under the gate: pr-view is read again and reports Merged"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/CLOSED"
serve gate "$SANDBOX/empty"
echo 3 >"$SANDBOX/serve/gate.rc.1"
run "$PR" 60 3 45 2
check "$LAST" "Closed without merging" "closed under the gate: the terminal line"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/empty"
echo 3 >"$SANDBOX/serve/gate.rc.1"
run "$PR" 60 3 45 2
check "$RC" 1 "refused while open: exit 1"
check_contains "$ERR" "pr-ready-to-merge $PR failed" "refused while open: the error names the gate"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
echo 3 >"$SANDBOX/serve/gate.rc.1"
run "$PR" 60 3 45 2
check "$RC" 1 "refused while open with a report: exit 1"
check "$ERR" "pr-ready-to-merge: stub exit 3
$(cat "$SANDBOX/blocked")
sdlc-pr-monitor: pr-ready-to-merge $PR failed" \
  "refused while open with a report: the gate's stderr, then its report, then the script's line"

# --- the unchanged-poll bound -----------------------------------------

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
run "$PR" 60 3 45 2
check "$RC" 0 "bound: exit 0"
check "$LAST" "No change after 3 polls" "bound: the terminal line"
check "$(polls)" 4 "bound: three unchanged polls after the first"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked" "$SANDBOX/blocked" "$SANDBOX/blocked-ci" "$SANDBOX/blocked-ci" "$SANDBOX/blocked-ci"
run "$PR" 60 2 45 2
check "$LAST" "No change after 2 polls" "reset: the terminal line"
check "$(polls)" 5 "reset: a changed state restarts the count"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked" "$SANDBOX/blocked-wait"
run "$PR" 60 1 45 2
check "$LAST" "No change after 1 polls" "wait announcement: no state change of its own"
check "$(polls)" 2 "wait announcement: the second poll is the unchanged one"

# --- one run to a terminal line ----------------------------------------

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
run "$PR" 150 10 45 2
check "$RC" 0 "single run: exit 0"
check "$(polls)" 11 "single run: polls on past any wall-time limit until the bound"
check "$LAST" "No change after 10 polls" "single run: ends on the terminal line"
check "$SLEPT" 1500 "single run: an interval of sleep between every two polls"
check "$(printf '%s\n' "$OUT" | grep -vc '^Polled ')" 1 "single run: no line but the poll lines and the terminal line"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked" "$SANDBOX/blocked" "$SANDBOX/blocked" "$SANDBOX/blocked-ci"
run "$PR" 300 3 45 2
check "$(polls)" 7 "single run: a change after the count reached two restarts it"
check "$LAST" "No change after 3 polls" "single run: the restarted count reaches the bound"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked"
run "$PR" 600 10 45 2
check "$RC" 0 "interval 600: exit 0"
check "$(polls)" 3 "interval 600: polled"
check "$SLEEPS" "60 60 60 60 60 60 60 60 60 60 60 60 60 60 60 60 60 60 60 60 " "interval 600: each wait in chunks of at most 60 s"
check "$LAST" "Merged" "interval 600: ends on the terminal line"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked"
run "$PR" 150 10 45 2
check "$SLEEPS" "60 60 30 " "chunking: a remainder under 60 s is one last sleep"

# --- recoverable failures ---------------------------------------------

printf '%s\n' 'error connecting to api.github.com' \
  'check your internet connection or https://githubstatus.com' \
  'pr-view: gh pr view failed (exit 1)' >"$SANDBOX/connect-err"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/OPEN" "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked"
cp "$SANDBOX/connect-err" "$SANDBOX/serve/view.err.2"
run "$PR" 60 10 45 2
check "$RC" 0 "view connect error: exit 0"
check "$(printf '%s\n' "$OUT" | sed -n 2p)" \
  "Polled $PR: recoverable failure 1/2: error connecting to api.github.com" \
  "view connect error: the failure's poll line carries the first stderr line"
check "$(printf '%s\n' "$OUT" | grep -c -e 'githubstatus' -e 'gh pr view failed')" 0 \
  "view connect error: no later stderr line reaches stdout"
check "$LAST" "Merged" "view connect error: polling goes on to the terminal line"
check "$SLEEPS" "60 45 60 " "view connect error: the retry waits <retry-wait>, the next poll <interval>"
check "$ERR" "" "view connect error: nothing reaches stderr"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked"
echo 'HTTP 502: Bad Gateway (https://api.github.com/graphql)' >"$SANDBOX/serve/gate.err.1"
run "$PR" 60 10 45 2
check "$RC" 0 "gate 5xx: exit 0"
check "$(printf '%s\n' "$OUT" | sed -n 1p)" \
  "Polled $PR: recoverable failure 1/2: HTTP 502: Bad Gateway (https://api.github.com/graphql)" \
  "gate 5xx: retried like a pr-view failure"
check "$(cat "$SANDBOX/serve/gate.n")" 1 "gate 5xx: the retried poll reads pr-view again first"
check "$LAST" "Merged" "gate 5xx: the retried poll reaches the terminal line"

# recoverable_case <stderr> <label>: a first pr-view call failing with
# the stderr is retried.
recoverable_case() {
  reset
  serve view "$SANDBOX/OPEN" "$SANDBOX/MERGED"
  serve gate "$SANDBOX/blocked"
  echo "$1" >"$SANDBOX/serve/view.err.1"
  run "$PR" 60 10 45 2
  check "$RC.$LAST" "0.Merged" "recoverable: $2 is retried"
}
recoverable_case 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout' "timeout"
recoverable_case 'read tcp: i/o timed out' "timed out"
recoverable_case 'HTTP 503: Service Unavailable' "HTTP 503"
recoverable_case 'API rate limit exceeded for user ID 1' "rate limit"
recoverable_case 'HTTP 429: Too Many Requests' "HTTP 429"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
printf '%s\n' 'GraphQL: Could not resolve to a PullRequest with the number of 7.' \
  'pr-view: gh pr view failed (exit 1)' >"$SANDBOX/serve/view.err.1"
run "$PR" 60 10 45 2
check "$RC" 1 "non-recoverable: exit 1"
check "$ERR" "GraphQL: Could not resolve to a PullRequest with the number of 7.
pr-view: gh pr view failed (exit 1)
sdlc-pr-monitor: pr-view $PR failed" "non-recoverable: the call's stderr verbatim, then the script's line"
check "$OUT" "" "non-recoverable: no poll line"
check "$SLEEPS" "" "non-recoverable: no retry wait"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
for n in 1 2 3; do echo "timeout $n" >"$SANDBOX/serve/view.err.$n"; done
run "$PR" 60 10 45 2
check "$RC" 1 "past max-retries: exit 1"
check "$OUT" "Polled $PR: recoverable failure 1/2: timeout 1
Polled $PR: recoverable failure 2/2: timeout 2" "past max-retries: a poll line per retried failure"
check "$ERR" "timeout 3
sdlc-pr-monitor: pr-view $PR failed" "past max-retries: the last failure's stderr verbatim, then the script's line"
check "$SLEEPS" "45 45 " "past max-retries: a retry wait per retried failure"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/OPEN" "$SANDBOX/OPEN" "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked"
echo 'timeout' >"$SANDBOX/serve/view.err.1"
echo 'timeout' >"$SANDBOX/serve/view.err.3"
run "$PR" 60 10 45 1
check "$RC" 0 "completed poll: exit 0"
check "$(printf '%s\n' "$OUT" | grep -c 'recoverable failure 1/1')" 2 "completed poll: resets the consecutive-failure count"
check "$LAST" "Merged" "completed poll: polling goes on to the terminal line"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
echo 'rate limit' >"$SANDBOX/serve/gate.err.2"
echo 'rate limit' >"$SANDBOX/serve/gate.err.3"
run "$PR" 60 2 45 2
check "$LAST" "No change after 2 polls" "unchanged count: the terminal line"
check "$(printf '%s\n' "$OUT" | grep -c '^Polled .*: OPEN;')" 3 "unchanged count: recoverable failures neither advance nor reset it"
check "$(printf '%s\n' "$OUT" | grep -c 'recoverable failure')" 2 "unchanged count: both failures retried"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked"
echo 'timeout' >"$SANDBOX/serve/view.err.1"
run "$PR" 60 10 150 2
check "$SLEEPS" "60 60 30 " "retry wait: in chunks of at most 60 s"

# --- refusals and failures --------------------------------------------

# usage_case <arg>...: runs the monitor with the arguments and expects
# exit 2.
usage_case() {
  run "$@"
  check "$RC" 2 "usage: $* exits 2"
}
usage_case "$PR" 60
# A call without <retry-wait> and <max-retries> is refused, never run
# with values of the script's own.
usage_case "$PR" 60 3
usage_case "$PR" 60 3 45
usage_case "$PR" 60 3 45 2 0
usage_case "$PR" x 3 45 2
usage_case "$PR" 60 -1 45 2
usage_case "$PR" 0 3 45 2
usage_case "$PR" 60 0 45 2
usage_case "$PR" 60 3 0 2
usage_case "$PR" 60 3 45 0
usage_case "$PR" 60 3 y 2
usage_case "$PR" 60 3 45 -1
check "$OUT" "" "usage: nothing polled"
run "$PR" 60 3 45 0
check_contains "$ERR" "<max-retries> must be at least 1" "usage: a <max-retries> below 1 is named"
run "$PR" 60 3 0 2
check_contains "$ERR" "<retry-wait> must be at least 1" "usage: a <retry-wait> below 1 is named"

reset
echo "gh: no such PR" >"$SANDBOX/serve/view.fail"
run "$PR" 60 3 45 2
check "$RC" 1 "pr-view fails: exit 1"
check_contains "$ERR" "pr-view $PR failed" "pr-view fails: the error names pr-view"
reset
serve view "$SANDBOX/OPEN"
cp "$SANDBOX/blocked" "$SANDBOX/serve/gate.fail"
run "$PR" 60 3 45 2
check "$RC" 1 "gate fails: exit 1"
check_contains "$ERR" "pr-ready-to-merge: stub failure" "gate fails: the gate's own error passes through"
check_contains "$ERR" "mergeStateStatus BLOCKED" "gate fails: the gate's report is on stderr"
check_contains "$ERR" "pr-ready-to-merge $PR failed" "gate fails: the error names the gate"

reset
serve view "$SANDBOX/MERGED"
PATH="$SANDBOX/bin:$PATH" "$MONITOR" "$PR" 60 3 45 2 >&- 2>"$SANDBOX/err"
RC=$?
check "$RC" 1 "unwrapped failure: a failing echo exits 1"
check_contains "$(cat "$SANDBOX/err")" "\`echo \"Polled \$pr: MERGED\"\` failed" "unwrapped failure: the error names the command"

# A failing rm in the EXIT trap leaves the exit status as it was.
mkdir -p "$SANDBOX/rm-fails"
printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/rm-fails/rm"
chmod +x "$SANDBOX/rm-fails/rm"
reset
serve view "$SANDBOX/MERGED"
OUT=$(PATH="$SANDBOX/rm-fails:$SANDBOX/bin:$PATH" "$MONITOR" "$PR" 60 3 45 2 2>"$SANDBOX/err")
RC=$?
check "$RC.$(cat "$SANDBOX/err")" "0." "exit trap: a failed temporary-file removal keeps exit 0 and prints nothing"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All cases passed."
else
  echo "$FAILURES case(s) failed."
  exit 1
fi
