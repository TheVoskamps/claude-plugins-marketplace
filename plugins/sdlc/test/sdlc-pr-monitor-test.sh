#!/usr/bin/env bash
#
# sdlc-pr-monitor-test.sh -- drive plugins/sdlc/bin/sdlc-pr-monitor
# against stub pr-view and pr-ready-to-merge executables serving a
# scripted sequence of polls, and stub sleep and date executables that
# advance and read a fake clock, so no case waits: each terminal line,
# the unchanged-poll bound with and without a count carried in, a state
# change resetting the count, the `continue` exit at the wall-time
# budget, the sleep chunking, the refusal of an interval above 540, the
# usage errors, and a failing pr-view or pr-ready-to-merge.
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
# n-th call, <kind>.<n>, and repeat <kind>.last past the end, or fail
# when <kind>.fail exists. sleep adds its argument to the fake clock and
# logs it; date prints the clock for `+%s`.
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
  exit 3
fi
if [ -f "\$d/$kind.\$n" ]; then cat "\$d/$kind.\$n"; else cat "\$d/$kind.last"; fi
EOF
done
cat >"$SANDBOX/bin/sleep" <<EOF
#!/bin/sh
echo "\$1" >>"$SANDBOX/serve/sleeps"
c=\$(cat "$SANDBOX/serve/clock")
echo \$((c + \$1)) >"$SANDBOX/serve/clock"
EOF
cat >"$SANDBOX/bin/date" <<EOF
#!/bin/sh
[ "\$1" = +%s ] && exec cat "$SANDBOX/serve/clock"
exec /bin/date "\$@"
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
run "$PR" 60 3
check "$RC" 0 "merged: exit 0"
check "$OUT" "Polled $PR: MERGED
Merged" "merged: the poll line, then Merged"
check "$SLEEPS" "" "merged: no wait before the first poll"
check "$(cat "$SANDBOX/serve/view.args")" "$PR --json state,mergedAt,closedAt --jq .state" "merged: pr-view reads the state"
check "$(cat "$SANDBOX/serve/gate.n" 2>/dev/null || echo 0)" 0 "merged: the gate does not run on a merged PR"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/CLOSED"
serve gate "$SANDBOX/blocked"
run "$PR" 60 3
check "$RC" 0 "closed: exit 0"
check "$LAST" "Closed without merging" "closed: the terminal line"
check "$(polls)" 2 "closed: a poll per interval"
check "$SLEEPS" "60 " "closed: one wait between the polls"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked" "$SANDBOX/behind"
run "$PR" 60 3
check "$RC" 0 "behind: exit 0"
check "$LAST" "BEHIND" "behind: the terminal line"
check_contains "$OUT" "Polled $PR: OPEN; PR $PR: mergeable MERGEABLE, mergeStateStatus BEHIND" "behind: the poll line carries the gate's state"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/dirty"
run "$PR" 60 3
check "$RC" 0 "dirty: exit 0"
check "$LAST" "DIRTY" "dirty: the terminal line"
check "$(polls)" 1 "dirty: one poll"

# --- the poll line ----------------------------------------------------

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked-ci" "$SANDBOX/blocked-wait"
run "$PR" 60 3
check "$(printf '%s\n' "$OUT" | sed -n 1p)" \
  "Polled $PR: OPEN; PR $PR: mergeable MERGEABLE, mergeStateStatus BLOCKED — meaning; reviewDecision: REVIEW_REQUIRED; checks running: ci: status IN_PROGRESS; checks not green: none" \
  "poll line: the report on one line, a check entry joined onto its label"
check_contains "$(printf '%s\n' "$OUT" | sed -n 2p)" "mergeStateStatus BLOCKED" "poll line: a gate wait announcement is dropped"
check "$(printf '%s\n' "$OUT" | grep -c 'still computing')" 0 "poll line: no wait announcement reaches stdout"
check "$LAST" "Merged" "poll line: polling continues past BLOCKED"

# --- the unchanged-poll bound -----------------------------------------

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
run "$PR" 60 3
check "$RC" 0 "bound: exit 0"
check "$LAST" "No change after 3 polls" "bound: the terminal line"
check "$(polls)" 4 "bound: three unchanged polls after the first"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked" "$SANDBOX/blocked" "$SANDBOX/blocked-ci" "$SANDBOX/blocked-ci" "$SANDBOX/blocked-ci"
run "$PR" 60 2
check "$LAST" "No change after 2 polls" "reset: the terminal line"
check "$(polls)" 5 "reset: a changed state restarts the count"

reset
serve view "$SANDBOX/OPEN" "$SANDBOX/OPEN" "$SANDBOX/MERGED"
serve gate "$SANDBOX/blocked" "$SANDBOX/blocked-wait"
run "$PR" 60 1
check "$LAST" "No change after 1 polls" "wait announcement: no state change of its own"
check "$(polls)" 2 "wait announcement: the second poll is the unchanged one"

# --- the continue exit at the wall-time budget, and a count carried in --

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
run "$PR" 150 10
check "$RC" 0 "continue: exit 0"
check "$(polls)" 4 "continue: polls until the next wait would pass 540 s"
check "$SLEEPS" "60 60 30 60 60 30 60 60 30 " "continue: each wait in chunks of at most 60 s"
check "$SLEPT" 450 "continue: no more than 540 s slept"
case "$LAST" in
  "continue 3 "[0-9]*) check ok ok "continue: carries the count and a state token" ;;
  *) check "$LAST" "continue 3 <token>" "continue: carries the count and a state token" ;;
esac
token=${LAST##* }

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
run "$PR" 150 4 3 "$token"
check "$LAST" "No change after 4 polls" "carried: the count carried in reaches the bound"
check "$(polls)" 1 "carried: one poll"
check "$SLEEPS" "60 60 30 " "carried: the call starts with the skipped wait"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked-ci"
run "$PR" 150 4 3 "$token"
check "$(polls)" 3 "carried: a different state resets a carried count"
check "$LAST" "continue 2 ${LAST##* }" "carried: the reset count runs to the budget"
check "$SLEPT" 450 "carried: the resumed wait counts against the budget"

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
run "$PR" 540 10
check "$(polls)" 2 "interval 540: two polls in a call that starts with one"
check "$SLEEPS" "60 60 60 60 60 60 60 60 60 " "interval 540: one wait of nine chunks"
check "$LAST" "continue 1 ${LAST##* }" "interval 540: then continue"
reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
run "$PR" 540 10 1 "${LAST##* }"
check "$(polls)" 1 "interval 540: a resumed call polls once"
check "$SLEPT" 540 "interval 540: after waiting the whole interval, and no more"
check "$LAST" "continue 2 ${LAST##* }" "interval 540: the carried count advances"

# --- refusals and failures --------------------------------------------

reset
serve view "$SANDBOX/OPEN"
serve gate "$SANDBOX/blocked"
run "$PR" 541 3
check "$RC" 2 "interval 541: exit 2"
check_contains "$ERR" "lower merge-poll-interval-seconds" "interval 541: the error names the config key"
check "$OUT" "" "interval 541: nothing polled"

for args in "$PR 60" "$PR 60 3 0" "$PR x 3" "$PR 60 -1" "$PR 0 3" "$PR 60 0" "$PR 60 3 y z"; do
  # shellcheck disable=SC2086 # each case is split into its arguments
  run $args
  check "$RC" 2 "usage: $args exits 2"
done

reset
echo "gh: no such PR" >"$SANDBOX/serve/view.fail"
run "$PR" 60 3
check "$RC" 1 "pr-view fails: exit 1"
check_contains "$ERR" "pr-view $PR failed" "pr-view fails: the error names pr-view"

reset
serve view "$SANDBOX/OPEN"
cp "$SANDBOX/blocked" "$SANDBOX/serve/gate.fail"
run "$PR" 60 3
check "$RC" 1 "gate fails: exit 1"
check_contains "$ERR" "pr-ready-to-merge: stub failure" "gate fails: the gate's own error passes through"
check_contains "$ERR" "mergeStateStatus BLOCKED" "gate fails: the gate's report is on stderr"
check_contains "$ERR" "pr-ready-to-merge $PR failed" "gate fails: the error names the gate"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All cases passed."
else
  echo "$FAILURES case(s) failed."
  exit 1
fi
