#!/usr/bin/env bash
#
# sdlc-test.sh -- drive plugins/sdlc/bin/sdlc-agent-result-persist's
# records and round-log modes against a state root of its own: the
# round-0 seed write, the carry form that builds a later round's records
# file from the carried round, an edits file and the new records, each
# refusal the carry form makes, print-records with and without a --round
# bound, the path leave prints, stopped's --agent-id and
# print-in-flight's matching of a stopped to its child, a generator's
# leave refused for ids that do not continue the carried records,
# print-root's state root and its signpost, and the repository's state
# directory: its repo.yml, the move of state from the layout that
# predates the host segment, and --mode repos. It also drives the --pr
# reference and its refusals, --mode list's repository operand against
# a stub gh, and sdlc-orchestrate-analysis's resolution of its PR
# against a stub pr-view and its reading of a fixer brief. It checks
# that a command a script does not handle exits through that script's
# own failure exit, and drives sdlc-pr-round,
# sdlc-pr-adjustments, sdlc-fixer-brief and sdlc-records-chain against a
# stub gh serving a PR's reviews and comments, and
# sdlc-pr-post-theorem-records against a stub sdlc-records-chain and a
# stub pr-comment.
#
# Needs bash, jq and the POSIX utilities. Reaches no network.
#
# Usage: sdlc-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSIST="$TEST_DIR/../bin/sdlc-agent-result-persist"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0
TAB=$(printf '\t')

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

# Each case gets a state root and a scratch directory of its own, so no
# case reads a round another one wrote.
new_case() {
  CASE="$SANDBOX/$1"
  mkdir -p "$CASE/state"
  export XDG_STATE_HOME="$CASE/state"
}

# persist <args...>: runs the script against PR 7 of h.example/o/r,
# leaving the exit status in RC and stderr in ERR.
persist() {
  "$PERSIST" --pr 'h.example/o/r#7' "$@" >/dev/null 2>"$CASE/err" </dev/null
  RC=$?
  ERR=$(cat "$CASE/err")
}

round_records() {
  cat "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round$1/records" 2>/dev/null
}

SEED='T1
claim: the seed claim
issues: #1
settle-mode: semantic
pointers: a.md

T2
claim: the rejected seed claim
issues: #1
settle-mode: mechanical
pointers: b.md
state: retired
state-detail: human-refuted'

ROUND1='T1
claim: the seed claim
issues: #1
settle-mode: semantic
pointers: a.md
state: disproved
state-detail: finding 1, High
settled-at: aaa

T2
claim: the rejected seed claim
issues: #1
settle-mode: mechanical
pointers: b.md
state: retired
state-detail: human-refuted'

# seed_round <n> <records>: stores <records> as round <n>'s records file
# through the plain form.
seed_round() {
  printf '%s\n' "$2" >"$CASE/seed"
  persist --mode records --round "$1" --from "$CASE/seed"
  check "$RC" "0" "seed: round $1's records are stored by the plain form"
}

# --- the plain form ----------------------------------------------------

new_case plain
seed_round 0 "$SEED"
check "$(round_records 0)" "$SEED" "plain: the payload is stored byte for byte"

# --- a round-0 seed carried into round 1 -------------------------------

new_case seed-into-round1
seed_round 0 "$SEED"
printf 'T1\tstate\tdisproved\nT1\tstate-detail\tfinding 1, High\nT1\tsettled-at\taaa\n' >"$CASE/edits"
persist --mode records --round 1 --carry --edits "$CASE/edits"
check "$RC" "0" "seed carry: round 1 is written"
check "$(round_records 1)" "$ROUND1" "seed carry: the stamped seed record gains its fields after the others, in order"
check "$(round_records 0)" "$SEED" "seed carry: round 0's records are left as they were"

new_case seed-unstamped
seed_round 0 "$SEED"
persist --mode records --round 1 --carry
check "$RC" "2" "seed carry: a seed record left without state is refused"
check_contains "$ERR" "without a state: T1" "seed carry: the refusal names the unstamped id"
check "$(round_records 1)" "" "seed carry: a refused carry writes nothing"
check "$([ -d "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1" ] && echo made || echo absent)" "absent" \
  "seed carry: a refused carry creates no round directory"

# --- a carried round with a retirement edit ----------------------------

new_case retirement
seed_round 0 "$SEED"
seed_round 1 "$ROUND1"
printf 'T1\tstate\tretired\nT1\tstate-detail\thuman-refuted\n' >"$CASE/edits"
persist --mode records --round 2 --carry --edits "$CASE/edits"
check "$RC" "0" "retirement: round 2 is written"
check "$(round_records 2)" 'T1
claim: the seed claim
issues: #1
settle-mode: semantic
pointers: a.md
state: retired
state-detail: human-refuted
settled-at: aaa

T2
claim: the rejected seed claim
issues: #1
settle-mode: mechanical
pointers: b.md
state: retired
state-detail: human-refuted' "retirement: edited fields change in place and nothing else does"

# All four fields are added to a record holding none, from edits in the
# reverse of the canonical order, so a swap of any adjacent pair fails.
new_case added-field-order
seed_round 0 "$SEED"
printf 'T1\tseverity-override\tLow\nT1\tsettled-at\tbbb\nT1\tstate-detail\tfinding 1, High\nT1\tstate\tdisproved\n' >"$CASE/edits"
persist --mode records --round 1 --carry --edits "$CASE/edits"
check "$RC" "0" "added fields: round 1 is written"
check "$(round_records 1 | sed -n '5,9p')" 'pointers: a.md
state: disproved
state-detail: finding 1, High
settled-at: bbb
severity-override: Low' "added fields: lines a record lacks are appended in the canonical order"

new_case empty-value
seed_round 0 "$SEED"
seed_round 1 "$ROUND1"
printf 'T1\tstate-detail\t\n' >"$CASE/edits"
persist --mode records --round 2 --carry --edits "$CASE/edits"
check "$RC" "0" "empty value: an edit may carry an empty value"
check "$(round_records 2 | sed -n '7p')" "state-detail:" "empty value: the field is kept with no value"

# --- an empty-delta carry ----------------------------------------------

new_case empty-delta
seed_round 0 "$SEED"
seed_round 1 "$ROUND1"
persist --mode records --round 2 --carry
check "$RC" "0" "empty delta: a carry with no edits and no new records is written"
check "$(round_records 2)" "$ROUND1" "empty delta: the records carry forward unchanged"

new_case empty-from
seed_round 0 "$SEED"
seed_round 1 "$ROUND1"
: >"$CASE/new"
persist --mode records --round 2 --carry --from "$CASE/new"
check "$RC" "0" "empty delta: an empty --from file is accepted with --carry"
check "$(round_records 2)" "$ROUND1" "empty delta: an empty --from file appends nothing"

# --- appended minted records -------------------------------------------

new_case minted
seed_round 0 "$SEED"
seed_round 1 "$ROUND1"
printf 'T3\nclaim: minted\nissues: #1\nsettle-mode: semantic\npointers: c.md\nstate: disproved\n\nT4\nclaim: generated\nissues: #1\nsettle-mode: mechanical\npointers: d.md\nstate: retired\n' >"$CASE/new"
persist --mode records --round 2 --carry --from "$CASE/new"
check "$RC" "0" "minted: new records are appended"
check "$(round_records 2)" "$ROUND1

T3
claim: minted
issues: #1
settle-mode: semantic
pointers: c.md
state: disproved

T4
claim: generated
issues: #1
settle-mode: mechanical
pointers: d.md
state: retired" "minted: the result holds the carried records, then the new ones, in id order"

# --- refusals ----------------------------------------------------------

# refused <label> <expected message fragment> <args...>: runs a carry
# into round 2 over a stored round 1 and checks it was refused, said
# why, and wrote nothing.
refused() {
  label=$1
  fragment=$2
  shift 2
  persist --mode records --round 2 "$@"
  check "$RC" "2" "refusal: $label exits non-zero"
  check_contains "$ERR" "$fragment" "refusal: $label names the offending line"
  check "$(round_records 2)" "" "refusal: $label writes nothing"
}

new_case refusals
seed_round 0 "$SEED"
seed_round 1 "$ROUND1"

printf 'T9\tstate\tretired\n' >"$CASE/edits"
refused "an edit to an id no record has" "names T9, which no carried record has" \
  --carry --edits "$CASE/edits"

printf 'T1\tclaim\tsomething else\n' >"$CASE/edits"
refused "an edit to a field outside the four" "names field claim" \
  --carry --edits "$CASE/edits"

printf 'T1\tstate\tsurvived\n' >"$CASE/edits"
refused "a state outside the three" "sets state survived" \
  --carry --edits "$CASE/edits"

printf 'T1\tstate\tretired\nT1\tstate\tunsettled\n' >"$CASE/edits"
refused "a second edit to the same field" "edits state of T1 a second time: T1${TAB}state${TAB}unsettled" \
  --carry --edits "$CASE/edits"

printf 'T1 state retired\n' >"$CASE/edits"
refused "an edit line without tabs" "line 1 is not <id><tab><field><tab><value>" \
  --carry --edits "$CASE/edits"

printf 'T2\nclaim: reused\nissues: #1\nsettle-mode: semantic\npointers: x\nstate: disproved\n' >"$CASE/new"
refused "a new record with a carried id" "the new record T2 has an id a carried record already holds" \
  --carry --from "$CASE/new"

printf 'T4\nclaim: skipped\nissues: #1\nsettle-mode: semantic\npointers: x\nstate: disproved\n' >"$CASE/new"
refused "a new record skipping an id" "the new record T4 is not the next id in sequence, which is T3" \
  --carry --from "$CASE/new"

printf 'T3\nclaim: unstamped\nissues: #1\nsettle-mode: semantic\npointers: x\n' >"$CASE/new"
refused "a new record without state" "without a state: T3" \
  --carry --from "$CASE/new"

printf 'T1\tstate\tretired\n' >"$CASE/edits"
refused "--edits without --carry" "--edits is accepted only with --carry" \
  --edits "$CASE/edits" --from "$CASE/edits"

new_case no-carried-round
persist --mode records --round 1 --carry
check "$RC" "2" "refusal: --carry with no carried round exits non-zero"
check_contains "$ERR" "found no round below --round 1 under" "refusal: --carry with no carried round says so"
check "$(round_records 1)" "" "refusal: --carry with no carried round writes nothing"

new_case no-round-below
seed_round 1 "$ROUND1"
persist --mode records --round 1 --carry
check "$RC" "2" "refusal: --carry with records only at --round exits non-zero"
check_contains "$ERR" "found no round below --round 1" "refusal: --carry with records only at --round says so"
check "$(round_records 1)" "$ROUND1" "refusal: --carry with records only at --round leaves them as they were"

# A resumed reviewer whose earlier instance stored this round's records
# stores them again: the carry reads the round below, never the round's
# own records, so the same edits rebuild the same file.
new_case resume-restore
seed_round 0 "$SEED"
printf 'T1\tstate\tdisproved\nT1\tstate-detail\tfinding 1, High\nT1\tsettled-at\taaa\n' >"$CASE/edits"
persist --mode records --round 1 --carry --edits "$CASE/edits"
check "$RC" "0" "resume: the first instance's carry is written"
persist --mode records --round 1 --carry --edits "$CASE/edits"
check "$RC" "0" "resume: a carry into the latest records round is accepted"
check "$(round_records 1)" "$ROUND1" "resume: the re-stored round is rebuilt from the round below, unchanged"
check "$(round_records 0)" "$SEED" "resume: the round below is left as it was"

printf 'T1\tstate\tunsettled\nT1\tstate-detail\t\nT1\tsettled-at\tbbb\n' >"$CASE/edits"
persist --mode records --round 1 --carry --edits "$CASE/edits"
check "$RC" "0" "resume: a carry with different edits is accepted"
check "$(round_records 1)" 'T1
claim: the seed claim
issues: #1
settle-mode: semantic
pointers: a.md
state: unsettled
state-detail:
settled-at: bbb

T2
claim: the rejected seed claim
issues: #1
settle-mode: mechanical
pointers: b.md
state: retired
state-detail: human-refuted' "resume: the edits apply to the round below, not to the round's stored records"

new_case above-round
seed_round 0 "$SEED"
seed_round 1 "$ROUND1"
seed_round 2 "$ROUND1"
persist --mode records --round 1 --carry
check "$RC" "2" "refusal: carrying below a round holding records exits non-zero"
check_contains "$ERR" "--mode records --carry --round 1 refused: round 2, above it, holds a records file" \
  "refusal: carrying below a round holding records names both rounds"
check "$(round_records 1)" "$ROUND1" "refusal: carrying below a round holding records leaves its records as they were"

new_case above-round-voided
seed_round 0 "$SEED"
seed_round 2 "$ROUND1"
mv "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round2" "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round2.voided-20260101T000000Z"
printf 'T1\tstate\tdisproved\nT1\tstate-detail\tfinding 1, High\nT1\tsettled-at\taaa\n' >"$CASE/edits"
persist --mode records --round 1 --carry --edits "$CASE/edits"
check "$RC" "0" "voided: a voided round above --round does not refuse the carry"
check "$(round_records 1)" "$ROUND1" "voided: the carry reads the round below"

# --- print-records -----------------------------------------------------

# print_records <args...>: runs print-records, leaving stdout in OUT.
print_records() {
  OUT=$("$PERSIST" --pr 'h.example/o/r#7' --mode print-records "$@" 2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
}

new_case print-records
seed_round 0 "$SEED"
seed_round 1 "$ROUND1"
print_records
check "$OUT" "round 1
$ROUND1" "print-records: with no --round, the latest round's records are printed"
print_records --round 1
check "$OUT" "round 0
$SEED" "print-records: --round selects the latest round below it"
print_records --round 5
check "$(printf '%s\n' "$OUT" | sed -n 1p)" "round 1" "print-records: --round need not name a round holding records"

new_case print-records-none-below
seed_round 0 "$SEED"
print_records --round 0
check "$RC" "2" "print-records: no round below --round exits non-zero"
check_contains "$ERR" "no round below --round 0" "print-records: no round below --round says so"

new_case print-records-above-round
seed_round 0 "$SEED"
seed_round 1 "$ROUND1"
seed_round 2 "$ROUND1"
print_records --round 1
check "$RC" "2" "print-records: a round above --round holding records exits non-zero"
check "$OUT" "" "print-records: a round above --round holding records prints no records"
check_contains "$ERR" "--mode print-records --round 1 refused: round 2, above it, holds a records file" \
  "print-records: a round above --round holding records names both rounds"

new_case print-records-above-round-voided
seed_round 0 "$SEED"
seed_round 2 "$ROUND1"
mv "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round2" "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round2.voided-20260101T000000Z"
print_records --round 1
check "$RC" "0" "print-records: a voided round above --round does not refuse the read"
check "$OUT" "round 0
$SEED" "print-records: past a voided round above, --round reads the round below"

new_case carry-other-mode
persist --mode review --round 1 --carry
check "$RC" "2" "refusal: --carry outside --mode records exits non-zero"
check_contains "$ERR" "--carry is not accepted in --mode review" "refusal: --carry outside --mode records says so"

# --- a child's records, and which child is in flight -----------------------

round_log() {
  cat "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round$1/log" 2>/dev/null
}

# as_child <agent-id> <args...>: runs the script from a directory named
# agent-<agent-id>, the way a child's worktree names its agent id, leaving
# stdout in OUT, stderr in ERR and the exit status in RC.
as_child() {
  local id=$1
  shift
  mkdir -p "$CASE/agent-$id"
  OUT=$(cd "$CASE/agent-$id" && "$PERSIST" --pr 'h.example/o/r#7' "$@" 2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
}

# in_flight <stage> <agent>: runs print-in-flight, leaving stdout in OUT.
in_flight() {
  OUT=$("$PERSIST" --pr 'h.example/o/r#7' --mode print-in-flight --round 1 --stage "$1" --agent "$2" \
    2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
}

new_case stopped-needs-agent-id
as_child A --mode enter --round 1 --theorem T1 --stage disprove
LOG_BEFORE=$(round_log 1)
persist --mode stopped --round 1 --theorem T1 --stage disprove
check "$RC" "2" "stopped: without --agent-id is refused"
check_contains "$ERR" "--agent-id is required in --mode stopped" "stopped: the refusal names the flag"
check "$(round_log 1)" "$LOG_BEFORE" "stopped: a refused stopped appends nothing to the log"

new_case stopped-carries-agent-id
persist --mode stopped --round 1 --theorem T1 --stage disprove --agent-id A
check "$RC" "0" "stopped: with --agent-id is written"
check "$(round_log 1 | awk '{print $1, $2, $3, $5}')" "stopped T1 disprove A" "stopped: the record names the child it writes off"

new_case in-flight-late-stop
as_child A --mode enter --round 1 --theorem T1 --stage disprove
as_child B --mode enter --round 1 --theorem T1 --stage disprove
persist --mode stopped --round 1 --theorem T1 --stage disprove --agent-id A
in_flight disprove theorem-disprover
check "$RC" "0" "in flight: print-in-flight exits 0"
check "$(printf '%s\n' "$OUT" | awk '{print $1, $2}')" "T1 B" \
  "in flight: an original child's stopped landing after its replacement's enter leaves the replacement in flight"

new_case in-flight-states
as_child A --mode enter --round 1 --theorem T1 --stage disprove
as_child B --mode enter --round 1 --theorem T2 --stage disprove
as_child C --mode enter --round 1 --theorem T3 --stage disprove
as_child D --mode enter --round 1 --theorem T4 --stage verify
persist --mode stopped --round 1 --theorem T2 --stage disprove --agent-id B
printf 'VERDICT: SURVIVED\nTHEOREM: T3\nCHECKED: x\n' >"$CASE/report"
as_child C --mode leave --round 1 --theorem T3 --stage disprove --agent theorem-disprover --from "$CASE/report"
in_flight disprove theorem-disprover
check "$(printf '%s\n' "$OUT" | awk '{print $1, $2}')" "T1 A" \
  "in flight: a stopped child, a child that left and another stage's child are not in flight"

new_case in-flight-result-file
as_child A --mode enter --round 1 --theorem T1 --stage disprove
printf 'VERDICT: SURVIVED\nTHEOREM: T1\nCHECKED: x\n' \
  >"$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1/T1-theorem-disprover"
in_flight disprove theorem-disprover
check "$OUT" "" "in flight: a theorem whose result file exists has no child in flight"

new_case leave-prints-path
printf 'VERDICT: SURVIVED\nTHEOREM: T1\nCHECKED: x\n' >"$CASE/report"
as_child A --mode leave --round 1 --theorem T1 --stage disprove --agent theorem-disprover --from "$CASE/report"
check "$RC:$OUT" "0:$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1/T1-theorem-disprover" \
  "leave: prints the result file's path"

# --- a generator's ids against the carried records --------------------------

# theorem_list <first> <last>: prints a generator's list of the theorems
# T<first> to T<last>, with its closing count and a retirement.
theorem_list() {
  for n in $(seq "$1" "$2"); do
    printf 'T%s\nclaim: claim %s\nissues: #1\nsettle-mode: semantic\npointers: a.md\n\n' "$n" "$n"
  done
  printf 'Total: %s semantic\n\nRETIREMENTS\nT1 — removed by the delta.\n' "$(($2 - $1 + 1))"
}

# Round 1's records hold T1 to T17.
SEVENTEEN=$(for n in $(seq 1 17); do
  [ "$n" -eq 1 ] || printf '\n'
  printf 'T%s\nclaim: claim %s\nissues: #1\nsettle-mode: semantic\npointers: a.md\nstate: retired\n' "$n" "$n"
done)

new_case generate-collides
seed_round 1 "$SEVENTEEN"
theorem_list 1 2 >"$CASE/list"
as_child G --mode leave --round 2 --theorem list --stage generate --agent theorem-generator --from "$CASE/list"
check "$RC:$OUT" "2:" "generate ids: a list opening at T1 over records holding T1 to T17 is refused"
check_contains "$ERR" "the new record T1 has an id a carried record already holds; the next id in sequence is T18" \
  "generate ids: the refusal names the colliding id and the expected next id"
check "$([ -e "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round2/list-theorem-generator" ] && echo written || echo none)" "none" \
  "generate ids: a refused list writes no result file"
check "$(round_log 2 | grep -c '^leave')" "0" "generate ids: a refused list appends no leave record"

new_case generate-continues
seed_round 1 "$SEVENTEEN"
theorem_list 18 19 >"$CASE/list"
as_child G --mode leave --round 2 --theorem list --stage generate --agent theorem-generator --from "$CASE/list"
check "$RC" "0" "generate ids: a list opening at T18 over records holding T1 to T17 is stored"
check "$(round_log 2 | grep -c '^leave list generate')" "1" "generate ids: the stored list's leave record is appended"

new_case generate-skips
seed_round 1 "$SEVENTEEN"
printf 'T18\nclaim: a\nissues: #1\nsettle-mode: semantic\npointers: a.md\n\nT20\nclaim: b\nissues: #1\nsettle-mode: semantic\npointers: a.md\n' \
  >"$CASE/list"
as_child G --mode leave --round 2 --theorem list --stage generate --agent theorem-generator --from "$CASE/list"
check "$RC" "2" "generate ids: a list skipping an id is refused"
check_contains "$ERR" "the new record T20 is not the next id in sequence, which is T19" \
  "generate ids: the refusal names the out-of-sequence id and the expected next id"

new_case generate-round0
theorem_list 2 3 >"$CASE/list"
as_child G --mode leave --round 0 --theorem list --stage generate --agent theorem-generator --from "$CASE/list"
check "$RC" "2" "generate ids: a round-0 list opening at T2 is refused"
check_contains "$ERR" "the new record T2 is not the next id in sequence, which is T1" \
  "generate ids: a round-0 list must open at T1"

new_case generate-no-records
theorem_list 1 2 >"$CASE/list"
as_child G --mode leave --round 1 --theorem list --stage generate --agent theorem-generator --from "$CASE/list"
check "$RC" "0" "generate ids: a round with no records below it accepts a list opening at T1"

# --- the repository's state directory ------------------------------------

REPO_YML='schema-version: 1
host: h.example
owner: o
repo: r'

new_case repo-yml-new
seed_round 0 "$SEED"
check "$(cat "$XDG_STATE_HOME/sdlc/h.example/o/r/repo.yml" 2>/dev/null)" "$REPO_YML" \
  "state layout: a new state directory gets repo.yml naming its repository"

new_case repo-without-host
"$PERSIST" --pr 'o/r#7' --round 1 --mode print >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "refusal: --pr without a host is a usage error"
check_contains "$(cat "$CASE/err")" "--pr takes <host>/<owner>/<repo>#<n>: o/r#7" "refusal: the usage error names the form"

new_case pr-bare-number
"$PERSIST" --pr 7 --round 1 --mode print >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "refusal: a bare --pr number is a usage error"
check_contains "$(cat "$CASE/err")" "--pr takes <host>/<owner>/<repo>#<n>: 7" "refusal: a bare number gets the form"

new_case pr-hash-number
"$PERSIST" --pr '#7' --round 1 --mode print >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "refusal: a --pr of #N is a usage error"

new_case pr-no-number
"$PERSIST" --pr 'h.example/o/r#' --round 1 --mode print >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "refusal: a --pr without its number is a usage error"

new_case repo-flag-gone
"$PERSIST" --repo h.example/o/r --pr 'h.example/o/r#7' --round 1 --mode print >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "refusal: there is no --repo flag"

for dots in '../o/r#7' 'h.example/../r#7' 'h.example/o/..#7' './o/r#7' 'h.example/./r#7' 'h.example/o/.#7'; do
  new_case "pr-dots-$(printf '%s' "$dots" | tr -c 'A-Za-z0-9' '_')"
  "$PERSIST" --pr "$dots" --mode delete >/dev/null 2>"$CASE/err" </dev/null
  check "$?" "2" "refusal: --pr $dots is refused"
  check_contains "$(cat "$CASE/err")" "none may be . or ..: ${dots%#*}" "refusal: --pr $dots names the repository"
done

# A canonical --pr <host>/<owner>/<repo>#<n> reads its state from
# sdlc/<host>/<owner>/<repo>/pr<n>/.
new_case pr-same-directory
mkdir -p "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1"
printf 'anchor 2026-01-01T00:00:00Z abc\n' >"$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1/log"
OUT=$("$PERSIST" --pr 'h.example/o/r#7' --round 1 --mode print 2>"$CASE/err" </dev/null)
check "$OUT" "anchor 2026-01-01T00:00:00Z abc" "canonical --pr: reads the state directory sdlc/<host>/<owner>/<repo>/pr<n>/"

new_case repo-dot-segment
"$PERSIST" --mode list h.example/../r >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "refusal: a .. segment in list's repository is refused"

# migrate_case <name>: a state root holding round 0 of PR 7 in the layout
# that predates the host segment, at sdlc/o/r/.
migrate_case() {
  new_case "$1"
  mkdir -p "$XDG_STATE_HOME/sdlc/o/r/pr7/round0"
  printf '%s\n' "$SEED" >"$XDG_STATE_HOME/sdlc/o/r/pr7/round0/records"
}

migrate_case migrate-on-read
OUT=$("$PERSIST" --pr 'h.example/o/r#7' --mode print-records 2>"$CASE/err" </dev/null)
check "$?" "0" "migration: a read of old-layout state succeeds"
check "$OUT" "round 0
$SEED" "migration: the read sees the moved records"
check "$([ -e "$XDG_STATE_HOME/sdlc/o" ] && echo present || echo gone)" "gone" \
  "migration: the old directory is gone"
check "$(cat "$XDG_STATE_HOME/sdlc/h.example/o/r/repo.yml" 2>/dev/null)" "$REPO_YML" \
  "migration: the moved directory gets repo.yml"

migrate_case migrate-on-list
OUT=$("$PERSIST" --mode list h.example/o/r 2>"$CASE/err" </dev/null)
check "$OUT" "h.example/o/r#7" "migration: list moves old-layout state and lists it"

migrate_case migrate-conflict
mkdir -p "$XDG_STATE_HOME/sdlc/h.example/o/r"
"$PERSIST" --mode list h.example/o/r >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "migration: state at both paths is refused"
check "$([ -e "$XDG_STATE_HOME/sdlc/o/r/pr7/round0/records" ] && echo kept || echo moved)" "kept" \
  "migration: a refused move leaves the old state where it was"

# A <host>/<owner> directory of the current layout sits at the same depth
# as old-layout state, and is not mistaken for it.
new_case migrate-not-host-dir
"$PERSIST" --pr 'o/r/x#7' --round 0 --mode records --from /dev/stdin >/dev/null 2>&1 <<EOF
$SEED
EOF
"$PERSIST" --mode list h.example/o/r >/dev/null 2>"$CASE/err" </dev/null
check "$?" "0" "migration: a run beside a current-layout <host>/<owner> directory succeeds"
check "$([ -e "$XDG_STATE_HOME/sdlc/o/r/x/repo.yml" ] && echo kept || echo moved)" "kept" \
  "migration: a current-layout <host>/<owner> directory is not moved"

# --mode repos names every repository directory from its repo.yml, a
# directory whose repo.yml disagrees with its path, and old-layout state.
migrate_case repos
seed_round 0 "$SEED"
"$PERSIST" --pr 'h.example/o/x#7' --round 0 --mode records --from /dev/stdin >/dev/null 2>&1 <<EOF
$SEED
EOF
mkdir -p "$XDG_STATE_HOME/sdlc/old/one/pr3"
mv "$XDG_STATE_HOME/sdlc/h.example/o/x" "$XDG_STATE_HOME/sdlc/h.example/o/moved"
OUT=$("$PERSIST" --mode repos 2>"$CASE/err" </dev/null)
check "$OUT" "mismatch h.example/o/x h.example/o/moved
repo h.example/o/r h.example/o/r
old old/one old/one" "repos: each directory by its repo.yml, a mismatch, and old-layout state"
"$PERSIST" --mode repos --pr 'h.example/o/r#7' >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "repos: --pr is refused"
"$PERSIST" --mode repos h.example/o/r >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "repos: a repository operand is refused"

# A current-layout <host>/<owner> directory with no repo.yml beneath it,
# empty or holding a repository directory, holds no pr<n> directory of its
# own, and is not old-layout state.
new_case repos-no-repo-yml
mkdir -p "$XDG_STATE_HOME/sdlc/hostx/acme" "$XDG_STATE_HOME/sdlc/hostx/beta/r1"
OUT=$("$PERSIST" --mode repos 2>"$CASE/err" </dev/null)
check "$OUT" "" "repos: a <host>/<owner> directory without repo.yml is not reported old"
"$PERSIST" --mode list h.example/hostx/acme >/dev/null 2>"$CASE/err" </dev/null
check "$([ -d "$XDG_STATE_HOME/sdlc/hostx/acme" ] && echo kept || echo moved)" "kept" \
  "migration: a <host>/<owner> directory without repo.yml is not moved"

# A move that fails leaves no empty <host>/<owner> directory behind.
migrate_case migrate-mv-fails
mkdir -p "$CASE/fakebin"
printf '#!/bin/sh\nexit 1\n' >"$CASE/fakebin/mv"
chmod +x "$CASE/fakebin/mv"
PATH="$CASE/fakebin:$PATH" "$PERSIST" --mode list h.example/o/r >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "migration: a failed move is refused"
check "$([ -e "$XDG_STATE_HOME/sdlc/h.example" ] && echo left || echo removed)" "removed" \
  "migration: a failed move leaves no empty <host> directory"
check "$([ -e "$XDG_STATE_HOME/sdlc/o/r/pr7/round0/records" ] && echo kept || echo moved)" "kept" \
  "migration: a failed move leaves the old state where it was"

# --- list's repository operand -------------------------------------------

# list_case <name>: a state root holding PR 7's state for the current
# repository, gh.example/acme/r, PR 9's for acme/other, and PRs 8, 9 and
# 10 for elsewhere/r on that host, with a stub gh that reports the current
# repository and records each call.
list_case() {
  new_case "$1"
  for at in acme/r/pr7 acme/other/pr9 elsewhere/r/pr10 elsewhere/r/pr9 elsewhere/r/pr8; do
    mkdir -p "$XDG_STATE_HOME/sdlc/gh.example/$at"
  done
  mkdir -p "$CASE/bin"
  printf '#!/bin/sh\necho "$*" >>"%s/calls"\necho https://gh.example/acme/r\n' "$CASE" >"$CASE/bin/gh"
  chmod +x "$CASE/bin/gh"
}

# list <operand...>: runs --mode list with the stub gh on PATH, leaving
# stdout in OUT and the gh calls in CALLS.
list() {
  OUT=$(PATH="$CASE/bin:$PATH" "$PERSIST" --mode list "$@" 2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
  CALLS=$(cat "$CASE/calls" 2>/dev/null)
}

list_case list-current
list
check "$RC:$OUT" "0:gh.example/acme/r#7" "list: no operand lists the current repository, each PR as its --pr reference"
check "$CALLS" "repo view --json url --jq .url" "list: the current repository comes from gh repo view"

list_case list-repo
list other
check "$OUT" "gh.example/acme/other#9" "list: <repo> is under the current repository's owner, on its host"

list_case list-owner-repo
list elsewhere/r
check "$OUT" "gh.example/elsewhere/r#8
gh.example/elsewhere/r#9
gh.example/elsewhere/r#10" "list: <owner>/<repo> is on the current repository's host, in ascending PR order"

list_case list-host-owner-repo
list gh.example/elsewhere/r
check "$OUT:$CALLS" "gh.example/elsewhere/r#8
gh.example/elsewhere/r#9
gh.example/elsewhere/r#10:" "list: <host>/<owner>/<repo> needs no gh call"

list_case list-url
list https://gh.example/elsewhere/r/
check "$OUT:$CALLS" "gh.example/elsewhere/r#8
gh.example/elsewhere/r#9
gh.example/elsewhere/r#10:" "list: a repository URL is the same as <host>/<owner>/<repo>"

list_case list-bad
for bad in 'a/b/c/d' '/r' 'o//r' 'http://gh.example/o/r' 'https://gh.example/o'; do
  list "$bad"
  check "$RC" "2" "list: \`$bad\` is refused"
done
list one two
check "$RC" "2" "list: two repositories are refused"
check_contains "$ERR" "--mode list takes at most one repository" "list: two repositories say so"

list_case list-pr-refused
list --pr 'gh.example/acme/r#7'
check "$RC" "2" "list: --pr is refused"

list_case list-gh-fails
printf '#!/bin/sh\necho "gh: no remote" >&2\nexit 1\n' >"$CASE/bin/gh"
list r
check "$RC" "2" "list: a current repository gh cannot resolve is refused"
check_contains "$ERR" "cannot resolve the current repository with gh repo view" "list: the refusal names the lookup"

# --- sdlc-orchestrate-analysis's PR ----------------------------------------

# Every form of the PR reaches the same state: the script resolves it with
# pr-view --ref, stubbed here to resolve every form to h.example/o/r#7.
for given in 7 '#7' 'https://h.example/o/r/pull/7'; do
  new_case "analysis-$(printf '%s' "$given" | tr -c 'A-Za-z0-9' '_')"
  mkdir -p "$CASE/bin" "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1"
  printf 'anchor 2026-01-01T00:00:00Z abc\n' >"$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1/log"
  printf '#!/bin/sh\necho "pr-view $*" >>"%s/calls"\necho "h.example/o/r#7"\n' "$CASE" >"$CASE/bin/pr-view"
  printf '#!/bin/sh\necho "gh $*" >>"%s/calls"\nexit 1\n' "$CASE" >"$CASE/bin/gh"
  ln -s "$PERSIST" "$CASE/bin/sdlc-agent-result-persist"
  chmod +x "$CASE/bin/pr-view" "$CASE/bin/gh"
  OUT=$(PATH="$CASE/bin:$PATH" "$TEST_DIR/../bin/sdlc-orchestrate-analysis" "$given" 2>"$CASE/err" </dev/null)
  check "$?" "0" "analysis $given: exit 0"
  check "$(sed -n 1p "$CASE/calls")" "pr-view $given --ref" "analysis $given: resolves the PR once with pr-view --ref"
  check_contains "$OUT" "| 1 | whole round | 2026-01-01T00:00:00Z |" "analysis $given: reports the canonical reference's round"
  check_contains "$(cat "$CASE/calls")" "gh api --hostname h.example repos/o/r/pulls/7" \
    "analysis $given: reads the timeline on the reference's host and repository"
  check "$(cat "$CASE/err")" "" "analysis $given: the sources it finds missing cost no line on stderr"
done

# A timeline carrying a fixer brief: the report names it as one, and
# lists the finding it rules on.
new_case analysis-fixer-brief
mkdir -p "$CASE/bin" "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1"
printf 'anchor 2026-01-01T00:00:00Z abc\n' >"$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1/log"
printf '#!/bin/sh\necho "h.example/o/r#7"\n' >"$CASE/bin/pr-view"
printf '[{"event": "commented", "created_at": "2026-01-01T00:05:00Z", "body": "%s"}]\n' \
  '<!-- sdlc:fixer-brief -->\nFindings to address:\n- T1: the defect — in scope' >"$CASE/timeline.json"
cat >"$CASE/bin/gh" <<STUB
#!/usr/bin/env bash
expr=
prev=
for a in "\$@"; do
  [ "\$prev" = --jq ] && expr=\$a
  prev=\$a
done
case "\$*" in
  *pulls/7*) echo https://h.example/o/r/pull/7 ;;
  *timeline*) jq -r "\$expr" "$CASE/timeline.json" ;;
  *) exit 1 ;;
esac
STUB
ln -s "$PERSIST" "$CASE/bin/sdlc-agent-result-persist"
chmod +x "$CASE/bin/pr-view" "$CASE/bin/gh"
OUT=$(PATH="$CASE/bin:$PATH" "$TEST_DIR/../bin/sdlc-orchestrate-analysis" 7 2>"$CASE/err" </dev/null)
check "$?" "0" "analysis: a timeline with a fixer brief exits 0"
check_contains "$OUT" "| fixer brief posted |" "analysis: the brief's timeline row names it a fixer brief"
check_contains "$OUT" "Accepted into the fixer brief posted 2026-01-01T00:05:00Z:" \
  "analysis: the brief's finding is listed as a ruling"

new_case operand-other-mode
"$PERSIST" --mode delete --pr 'h.example/o/r#7' h.example/o/r >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "refusal: a mode other than list takes no repository operand"

# --- unhandled failures in the persist and analysis scripts ---------------
# A command a script does not handle exits through the script's own
# failure exit, naming the command, and never with the command's status.

new_case persist-unhandled
printf 'not a directory\n' >"$CASE/state-file"
XDG_STATE_HOME="$CASE/state-file" "$PERSIST" --pr 'h.example/o/r#7' --mode anchor --round 1 --head-sha abc \
  >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "persist: an unwritable state root exits 2, not mkdir's status"
check_contains "$(cat "$CASE/err")" "sdlc-agent-result-persist: \`mkdir -p \"\$dir\"\` failed (exit 1)" \
  "persist: the message names the failed command"

new_case analysis-unhandled
mkdir -p "$CASE/bin"
printf '#!/bin/sh\necho "h.example/o/r#7"\n' >"$CASE/bin/pr-view"
printf '#!/bin/sh\nexit 1\n' >"$CASE/bin/gh"
printf '#!/bin/sh\nexit 9\n' >"$CASE/bin/sort"
ln -s "$PERSIST" "$CASE/bin/sdlc-agent-result-persist"
chmod +x "$CASE/bin/pr-view" "$CASE/bin/gh" "$CASE/bin/sort"
PATH="$CASE/bin:$PATH" "$TEST_DIR/../bin/sdlc-orchestrate-analysis" 7 >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "analysis: a failing sort exits 2, not sort's 9"
check_contains "$(cat "$CASE/err")" "failed (exit 9)" "analysis: the message names the failed command's status"

# --- sdlc's PR reads -------------------------------------------------------
# A stub gh serves a case's pr.json for every `gh pr view` and records the
# call; a case that touches `gh-fails` makes it fail. A recording
# sdlc-agent-result-persist hands every call to the real one.

# pr_case <name> <json>: a case whose PR is <json>.
pr_case() {
  new_case "$1"
  mkdir -p "$CASE/bin"
  printf '%s\n' "$2" >"$CASE/pr.json"
  cat >"$CASE/bin/gh" <<STUB
#!/bin/sh
echo "gh \$*" >>"$CASE/calls"
if [ -f "$CASE/gh-fails" ]; then echo "stub gh: refused" >&2; exit 1; fi
cat "$CASE/pr.json"
STUB
  cat >"$CASE/bin/sdlc-agent-result-persist" <<STUB
#!/bin/sh
echo "persist \$*" >>"$CASE/calls"
exec "$PERSIST" "\$@"
STUB
  chmod +x "$CASE/bin/gh" "$CASE/bin/sdlc-agent-result-persist"
}

# pr_read <script> <args...>: runs one of the scripts with the stubs on
# PATH, leaving OUT, ERR, RC and CALLS.
pr_read() {
  local script=$1
  shift
  OUT=$(PATH="$CASE/bin:$PATH" "$TEST_DIR/../bin/$script" "$@" 2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
  CALLS=$(cat "$CASE/calls" 2>/dev/null)
}

for script in sdlc-pr-round sdlc-pr-adjustments sdlc-fixer-brief sdlc-records-chain; do
  check "$([ -x "$TEST_DIR/../bin/$script" ] && echo yes)" "yes" "$script is executable"
done

pr_case round-two '{"reviews": [{"submittedAt": "2026-01-01T00:00:00Z"}, {"submittedAt": "2026-01-02T00:00:00Z"}]}'
pr_read sdlc-pr-round 'h.example/o/r#7'
check "$RC:$OUT" "0:3" "pr-round: two reviews make round 3"
check "$CALLS" "gh pr view 7 --repo h.example/o/r --json reviews" "pr-round: reads the reviews of the reference's PR"

pr_case round-none '{"reviews": []}'
pr_read sdlc-pr-round 'h.example/o/r#7'
check "$RC:$OUT" "0:1" "pr-round: no review makes round 1"

pr_case round-refs '{"reviews": []}'
for bad in 7 '#7' 'o/r#7' 'https://h.example/o/r/pull/7' 'h.example/o/r/x#7' 'h.example/o/..#7' 'h.example/o/r#'; do
  pr_read sdlc-pr-round "$bad"
  check "$RC:$CALLS" "2:" "pr-round: \`$bad\` is a usage error that reads nothing"
done

pr_case round-gh-fails '{"reviews": []}'
touch "$CASE/gh-fails"
pr_read sdlc-pr-round 'h.example/o/r#7'
check "$RC" "1" "pr-round: a failed gh read exits 1"
check_contains "$ERR" "stub gh: refused" "pr-round: gh's own error passes through"
check_contains "$ERR" "sdlc-pr-round: gh pr view of h.example/o/r#7 failed (exit 1)" "pr-round: the script's line names the read"

pr_case round-unhandled '{"reviews": []}'
printf '#!/bin/sh\nexit 9\n' >"$CASE/bin/jq"
chmod +x "$CASE/bin/jq"
pr_read sdlc-pr-round 'h.example/o/r#7'
check "$RC:$OUT" "1:" "pr-round: an unhandled failure exits 1, not the command's 9"
check_contains "$ERR" "failed (exit 9)" "pr-round: the message names the failed command's status"

# Comments out of order, so every read must sort them by createdAt.
BRIEF_OLD='<!-- sdlc:fixer-brief -->\nPR h.example/o/r#7, round 1.\nFindings to address: one'
BRIEF_NEW='<!-- sdlc:fixer-brief -->\r\nPR h.example/o/r#7, round 2.'
pr_case brief "{\"comments\": [
  {\"createdAt\": \"2026-01-03T00:00:00Z\", \"body\": \"$BRIEF_NEW\"},
  {\"createdAt\": \"2026-01-01T00:00:00Z\", \"body\": \"$BRIEF_OLD\"},
  {\"createdAt\": \"2026-01-02T00:00:00Z\", \"body\": \"A human remark\"}]}"
pr_read sdlc-fixer-brief 'h.example/o/r#7'
check "$RC" "0" "fixer-brief: exit 0 when the most recent comment is a brief"
check "$OUT" "$(printf '<!-- sdlc:fixer-brief -->\r\nPR h.example/o/r#7, round 2.')" \
  "fixer-brief: prints that comment's body, a web-form carriage return and all"
check "$CALLS" "gh pr view 7 --repo h.example/o/r --json comments" "fixer-brief: reads the PR's comments"

pr_read sdlc-fixer-brief --all 'h.example/o/r#7'
check "$RC" "0" "fixer-brief --all: exit 0"
check "$OUT" "$(printf -- '--- comment 2026-01-01T00:00:00Z ---\n<!-- sdlc:fixer-brief -->\nPR h.example/o/r#7, round 1.\nFindings to address: one\n--- comment 2026-01-03T00:00:00Z ---\n<!-- sdlc:fixer-brief -->\r\nPR h.example/o/r#7, round 2.')" \
  "fixer-brief --all: every brief, oldest first, each under its comment line"

pr_case brief-not-last "{\"comments\": [
  {\"createdAt\": \"2026-01-01T00:00:00Z\", \"body\": \"$BRIEF_OLD\"},
  {\"createdAt\": \"2026-01-02T00:00:00Z\", \"body\": \"Review adjustments for round 1:\\n- T3 rejected\"}]}"
pr_read sdlc-fixer-brief 'h.example/o/r#7'
check "$RC:$OUT" "3:" "fixer-brief: exit 3 and nothing on stdout when the most recent comment is no brief"
check_contains "$ERR" "Its first line is: Review adjustments for round 1:" "fixer-brief: stderr quotes that comment's first line"

pr_case brief-no-comment '{"comments": []}'
pr_read sdlc-fixer-brief 'h.example/o/r#7'
check "$RC:$OUT" "3:" "fixer-brief: exit 3 on a PR with no comment"
pr_read sdlc-fixer-brief --all 'h.example/o/r#7'
check "$RC:$OUT" "0:" "fixer-brief --all: no brief prints nothing and exits 0"

pr_case brief-usage '{"comments": []}'
pr_read sdlc-fixer-brief --every 'h.example/o/r#7'
check "$RC:$CALLS" "2:" "fixer-brief: an unknown flag is a usage error that reads nothing"

# chunk <day> <i>/<N>: prints one comment's JSON, created on 2026-01-0<day>,
# whose first line is the records marker for chunk <i> of <N>.
chunk() { printf '{"createdAt": "2026-01-0%sT00:00:00Z", "body": "<!-- sdlc:theorem-records %s -->\\ndetail"}' "$1" "$2"; }
pr_case chain-complete "{\"comments\": [$(chunk 4 3/3), $(chunk 2 1/3), $(chunk 1 2/3), $(chunk 3 1/2),
  {\"createdAt\": \"2026-01-05T00:00:00Z\", \"body\": \"<!-- sdlc:theorem-records i/N --> prose\"}]}"
pr_read sdlc-records-chain 'h.example/o/r#7'
check "$RC:$OUT" "0:complete${TAB}3" "records-chain: markers covering 1..N print complete and exit 0"

pr_case chain-partial "{\"comments\": [$(chunk 2 2/3), $(chunk 1 1/3)]}"
pr_read sdlc-records-chain 'h.example/o/r#7'
check "$RC" "3" "records-chain: an incomplete chain exits 3"
check "$OUT" "partial${TAB}1/3
partial${TAB}2/3" "records-chain: one partial line per marker, oldest first"

pr_case chain-none '{"comments": [{"createdAt": "2026-01-01T00:00:00Z", "body": "hello"}]}'
pr_read sdlc-records-chain 'h.example/o/r#7'
check "$RC:$OUT" "3:" "records-chain: no marker prints nothing and exits 3"

# The adjustment cut. Each case's PR carries a fixer brief, a records
# chunk and one adjustment, all after the cut, and one other comment,
# which falls before the cut in some cases and after it in others.

# adjust_json <reviews> <other body>: prints such a PR's JSON, its reviews
# the JSON array <reviews> and its other comment's body <other body>.
adjust_json() {
  printf '{"createdAt": "2026-01-01T00:00:00Z", "reviews": %s, "comments": [
    {"createdAt": "2026-01-05T00:00:00Z", "body": "Review adjustments for round 1:\\n- T2 rejected"},
    {"createdAt": "2026-01-04T00:00:00Z", "body": "<!-- sdlc:fixer-brief -->\\nFindings"},
    {"createdAt": "2026-01-04T12:00:00Z", "body": "<!-- sdlc:theorem-records 1/1 -->\\ndetail"},
    {"createdAt": "2026-01-02T00:00:00Z", "body": "%s"}]}' "$1" "$2"
}
ADJUSTMENT="--- comment 2026-01-05T00:00:00Z ---
Review adjustments for round 1:
- T2 rejected"

pr_case adjust-review "$(adjust_json '[{"submittedAt": "2026-01-03T00:00:00Z"}, {"submittedAt": "2026-01-02T12:00:00Z"}]' 'before the review')"
pr_read sdlc-pr-adjustments --pr 'h.example/o/r#7' --round 3
check "$RC" "0" "pr-adjustments: exit 0"
check "$OUT" "$ADJUSTMENT" "pr-adjustments: cuts at the newest review, and returns no marker comment"
check "$CALLS" "gh pr view 7 --repo h.example/o/r --json reviews,comments,createdAt" \
  "pr-adjustments: with a review, reads the PR alone"

pr_case adjust-log "$(adjust_json '[]' 'before the log ends')"
mkdir -p "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1"
printf 'anchor 2026-01-02T06:00:00Z abc\nspawn T1 disprove 2026-01-03T00:00:00Z theorem-disprover default default\n' \
  >"$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1/log"
pr_read sdlc-pr-adjustments --pr 'h.example/o/r#7' --round 2
check "$OUT" "$ADJUSTMENT" "pr-adjustments: with no review, cuts at the newest instant in the round below's log"
check_contains "$CALLS" "persist --mode print --pr h.example/o/r#7 --round 1" \
  "pr-adjustments: reads that log through sdlc-agent-result-persist --mode print"

pr_case adjust-seed "$(adjust_json '[]' 'after the PR opened')"
pr_read sdlc-pr-adjustments --pr 'h.example/o/r#7' --round 1
check "$RC" "0" "pr-adjustments: round 1 with no review exits 0"
check "$OUT" "--- comment 2026-01-02T00:00:00Z ---
after the PR opened
$ADJUSTMENT" "pr-adjustments: with no review and no log below, cuts at the PR's createdAt"

pr_case adjust-empty-log "$(adjust_json '[]' 'after the PR opened')"
mkdir -p "$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1"
: >"$XDG_STATE_HOME/sdlc/h.example/o/r/pr7/round1/log"
pr_read sdlc-pr-adjustments --pr 'h.example/o/r#7' --round 2
check "$OUT" "--- comment 2026-01-02T00:00:00Z ---
after the PR opened
$ADJUSTMENT" "pr-adjustments: an empty log below cuts at the PR's createdAt"

pr_case adjust-usage "$(adjust_json '[]' 'x')"
for args in "--pr h.example/o/r#7" "--round 2" "--pr h.example/o/r#7 --round 0" "--pr h.example/o/r#7 --round two" \
  "--pr 7 --round 2" "--pr h.example/o/r#7 --round 2 --full"; do
  read -r -a argv <<<"$args"
  pr_read sdlc-pr-adjustments "${argv[@]}"
  check "$RC:$CALLS" "2:" "pr-adjustments: \`$args\` is a usage error that reads nothing"
done

# --- the review-detail chain ------------------------------------------------
# sdlc-pr-post-theorem-records runs against the real
# sdlc-agent-result-persist and a state root of the case's own, with a
# stub sdlc-records-chain answering from the case's chain and chain-rc
# files and a stub pr-comment that keeps each body it is handed. PATH
# holds the stubs and the system directories alone, so no real pr-comment
# is reachable and bash is the one /usr/bin/env finds there.

POST="$TEST_DIR/../bin/sdlc-pr-post-theorem-records"
POST_PATH_TAIL=/usr/bin:/bin
PR_DIR_REL=sdlc/h.example/o/r/pr7

# post_case <name> [<chain line> <chain exit>]: a case whose PR carries
# the chain sdlc-records-chain reports, by default none. Its pr-comment
# refuses the post numbered in the case's comment-fails-at file, when the
# case writes one.
post_case() {
  new_case "$1"
  mkdir -p "$CASE/bin" "$CASE/posted"
  printf '%s' "${2-}" >"$CASE/chain"
  printf '%s' "${3-3}" >"$CASE/chain-rc"
  cat >"$CASE/bin/sdlc-records-chain" <<STUB
#!/bin/sh
echo "records-chain \$*" >>"$CASE/calls"
[ -s "$CASE/chain" ] && cat "$CASE/chain" && echo
exit \$(cat "$CASE/chain-rc")
STUB
  cat >"$CASE/bin/pr-comment" <<STUB
#!/bin/sh
n=\$(( \$(ls "$CASE/posted" | wc -l) + 1 ))
if [ "\$n" = "\$(cat "$CASE/comment-fails-at" 2>/dev/null)" ]; then echo "stub pr-comment: refused" >&2; exit 1; fi
cp "\$3" "$CASE/posted/\$n"
echo "pr-comment \$1 \$2" >>"$CASE/calls"
echo "https://h.example/o/r/pull/7#issuecomment-\$n"
STUB
  ln -s "$PERSIST" "$CASE/bin/sdlc-agent-result-persist"
  chmod +x "$CASE/bin/sdlc-records-chain" "$CASE/bin/pr-comment"
}

# state_file <round>/<file> <bytes> [<first line>]: writes a state file
# of <bytes> bytes, its last newline included, opening with <first line>
# and filled with x, and gives its round a log.
state_file() {
  local at="$XDG_STATE_HOME/$PR_DIR_REL/$1" fill=$(($2 - 1))
  mkdir -p "${at%/*}"
  [ -e "${at%/*}/log" ] || printf 'anchor 2026-01-01T00:00:00Z abc\n' >"${at%/*}/log"
  {
    if [ -n "${3-}" ]; then
      printf '%s\n' "$3"
      fill=$((fill - ${#3} - 1))
    fi
    head -c "$fill" /dev/zero | tr '\0' x
    printf '\n'
  } >"$at"
}

# post <args...>: runs the script with the stubs on PATH, leaving OUT,
# ERR, RC, CALLS and POSTED, the number of bodies pr-comment was handed.
post() {
  OUT=$(PATH="$CASE/bin:$POST_PATH_TAIL" "$POST" "$@" 2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
  CALLS=$(cat "$CASE/calls" 2>/dev/null)
  POSTED=$(find "$CASE/posted" -type f | wc -l | tr -d ' ')
}

# posted_headers <n>: the marker line and the headings of posted body <n>.
posted_headers() {
  grep -E '^(<!-- sdlc:theorem-records|## )' "$CASE/posted/$1"
}

check "$([ -x "$POST" ] && echo yes)" "yes" "sdlc-pr-post-theorem-records is executable"

new_case print-root
OUT=$("$PERSIST" --mode print-root --pr 'h.example/o/r#7' 2>"$CASE/err" </dev/null)
check "$?:$OUT" "0:$XDG_STATE_HOME/$PR_DIR_REL/
\${XDG_STATE_HOME:-\$HOME/.local/state}/$PR_DIR_REL/" "persist print-root: prints the PR's state root, expanded then as its signpost"
check "$([ -e "$XDG_STATE_HOME/sdlc" ] && echo made || echo absent)" "absent" "persist print-root: creates nothing"
"$PERSIST" --mode print-root --pr 'h.example/o/r#7' --round 1 >/dev/null 2>"$CASE/err" </dev/null
check "$?" "2" "persist print-root: --round is refused"

post_case post-existing "complete${TAB}2" 0
state_file round1/review 100
post 'h.example/o/r#7'
check "$RC:$OUT" "0:existing chain: 2 comments" "post: a complete chain already present is reported with its total"
check "$POSTED" "0" "post: a complete chain already present posts nothing"
check "$CALLS" "records-chain h.example/o/r#7" "post: asks sdlc-records-chain about the reference's PR"

post_case post-partial "partial${TAB}1/2" 3
mkdir -p "$XDG_STATE_HOME/$PR_DIR_REL/round0"
printf 'T1\nclaim: seed\n' >"$XDG_STATE_HOME/$PR_DIR_REL/round0/records"
state_file round1/T2-theorem-disprover 50
state_file round1/T1-counterexample-verifier 50
state_file round1/T1-theorem-disprover 50
state_file round1/list-theorem-generator-medium 50
state_file round1/list-theorem-generator 50
state_file round1/review 50
state_file round1/records 60 T1
state_file round2/review 50
post 'h.example/o/r#7'
check "$RC:$OUT" "0:https://h.example/o/r/pull/7#issuecomment-1" \
  "post: a partial chain gets a complete chain posted, its URL printed"
check "$(posted_headers 1)" "<!-- sdlc:theorem-records 1/1 -->
## \`round1/records\`
## \`round1/list-theorem-generator\`
## \`round1/list-theorem-generator-medium\`
## \`round1/review\`
## \`round1/T1-theorem-disprover\`
## \`round1/T1-counterexample-verifier\`
## \`round1/T2-theorem-disprover\`
## \`round2/review\`" "post: the pieces in assembly order, each headed by its path under the state root"
check "$(sed -n '3,5p' "$CASE/posted/1")" "## \`round1/records\`

T1" "post: the records piece leaves out print-records' round line"
check_contains "$CALLS" "pr-comment h.example/o/r#7 --body-file" "post: posts on the reference's PR by body file"

# Pieces of 25,000, 40,000 (T1's two reports) and 30,000 bytes: no two
# adjacent pieces fit one chunk.
post_case post-chunks
state_file round1/review 25000
state_file round1/T1-theorem-disprover 20000
state_file round1/T1-counterexample-verifier 20000
state_file round1/T2-theorem-disprover 30000
post 'h.example/o/r#7'
check "$RC:$OUT" "0:https://h.example/o/r/pull/7#issuecomment-1
https://h.example/o/r/pull/7#issuecomment-2
https://h.example/o/r/pull/7#issuecomment-3" "post: several chunks print one URL each, in chunk order"
check "$(for n in 1 2 3; do head -n 1 "$CASE/posted/$n"; done)" '<!-- sdlc:theorem-records 1/3 -->
<!-- sdlc:theorem-records 2/3 -->
<!-- sdlc:theorem-records 3/3 -->' "post: each chunk opens with its marker, the chain complete"
check "$(for n in 1 2 3; do [ "$(wc -c <"$CASE/posted/$n")" -le 60000 ] || echo "$n over"; done)" "" \
  "post: no chunk exceeds 60,000 bytes"
check "$(posted_headers 2)" "<!-- sdlc:theorem-records 2/3 -->
## \`round1/T1-theorem-disprover\`
## \`round1/T1-counterexample-verifier\`" "post: a theorem's disprover and verifier reports share one chunk"
check "$(awk '/^x+$/ { print length }' "$CASE/posted/2")" '19999
19999' "post: neither report in the shared chunk is cut"

post_case post-oversize
state_file round1/review 100
state_file round1/T1-theorem-disprover 70000 OVERSIZE-TOKEN
state_file round1/T1-counterexample-verifier 100
state_file round1/T2-theorem-disprover 100
post 'h.example/o/r#7'
check "$RC:$POSTED" "0:3" "post: an oversize piece is posted as a chunk of its own"
check "$(posted_headers 2)" '<!-- sdlc:theorem-records 2/3 -->
## Too large to post' "post: the oversize piece's chunk says it was too large"
check_contains "$(cat "$CASE/posted/2")" "- \`round1/T1-theorem-disprover\`
- \`round1/T1-counterexample-verifier\`" "post: the oversize chunk names each of the piece's files"
check "$(cat "$CASE/posted/"* | grep -c OVERSIZE-TOKEN)" "0" "post: no part of the oversize piece is posted"
check_contains "$(cat "$CASE/posted/2")" "\`\${XDG_STATE_HOME:-\$HOME/.local/state}/$PR_DIR_REL/\`" \
  "post: the oversize chunk names the PR's state root as its signpost"
check "$(grep -c -- "$XDG_STATE_HOME" "$CASE/posted/2")" "0" "post: the oversize chunk carries no expanded state path"
check "$(posted_headers 3)" "<!-- sdlc:theorem-records 3/3 -->
## \`round1/T2-theorem-disprover\`" "post: the pieces after it are posted whole"

post_case post-empty
post 'h.example/o/r#7'
check "$RC:$OUT:$POSTED" "0:nothing to assemble:0" "post: an empty state directory posts nothing"

post_case post-no-pr-comment
rm "$CASE/bin/pr-comment"
state_file round1/review 100
post 'h.example/o/r#7'
check "$RC:$OUT" "3:" "post: a missing pr-comment exits 3"
check_contains "$ERR" "pr-comment" "post: stderr names the missing pr-comment"
check "$CALLS" "" "post: a missing command is found before anything is read"

post_case post-command-fails
state_file round1/review 100
printf '#!/bin/sh\necho "stub tail: refused" >&2\nexit 7\n' >"$CASE/bin/tail"
chmod +x "$CASE/bin/tail"
post 'h.example/o/r#7'
check "$RC:$POSTED" "1:0" "post: a failed command it does not handle exits 1 and posts nothing"
check_contains "$ERR" "tail -c 1" "post: stderr names the command that failed"

post_case post-chain-fails "" 1
state_file round1/review 100
post 'h.example/o/r#7'
check "$RC:$OUT:$POSTED" "4::0" "post: a failed sdlc-records-chain exits 4 and posts nothing"

post_case post-comment-fails
state_file round1/review 40000
state_file round1/T1-theorem-disprover 40000
echo 2 >"$CASE/comment-fails-at"
post 'h.example/o/r#7'
check "$RC:$OUT" "5:https://h.example/o/r/pull/7#issuecomment-1" \
  "post: a failed post exits 5, the URLs already posted on stdout"
check_contains "$ERR" "chunk 2 of 2" "post: stderr names the chunk that failed"

post_case post-usage
for args in "" "7" "h.example/o/r#7 extra"; do
  read -r -a argv <<<"$args"
  post ${argv[@]+"${argv[@]}"}
  check "$RC:$CALLS" "2:" "post: \`$args\` is a usage error that reads nothing"
done

echo
echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
