#!/usr/bin/env bash
#
# sdlc-test.sh -- drive plugins/sdlc/bin/sdlc-agent-result-persist's
# records modes against a state root of its own: the round-0 seed write,
# the carry form that builds a later round's records file from the
# carried round, an edits file and the new records, each refusal the
# carry form makes, and print-records with and without a --round bound.
#
# Needs only bash and the POSIX utilities. Reaches no network.
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

# persist <args...>: runs the script against PR 7 of o/r, leaving the
# exit status in RC and stderr in ERR.
persist() {
  "$PERSIST" --owner o --repo r --pr 7 "$@" >/dev/null 2>"$CASE/err" </dev/null
  RC=$?
  ERR=$(cat "$CASE/err")
}

round_records() {
  cat "$XDG_STATE_HOME/sdlc/o/r/pr7/round$1/records" 2>/dev/null
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
check "$([ -d "$XDG_STATE_HOME/sdlc/o/r/pr7/round1" ] && echo made || echo absent)" "absent" \
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
mv "$XDG_STATE_HOME/sdlc/o/r/pr7/round2" "$XDG_STATE_HOME/sdlc/o/r/pr7/round2.voided-20260101T000000Z"
printf 'T1\tstate\tdisproved\nT1\tstate-detail\tfinding 1, High\nT1\tsettled-at\taaa\n' >"$CASE/edits"
persist --mode records --round 1 --carry --edits "$CASE/edits"
check "$RC" "0" "voided: a voided round above --round does not refuse the carry"
check "$(round_records 1)" "$ROUND1" "voided: the carry reads the round below"

# --- print-records -----------------------------------------------------

# print_records <args...>: runs print-records, leaving stdout in OUT.
print_records() {
  OUT=$("$PERSIST" --owner o --repo r --pr 7 --mode print-records "$@" 2>"$CASE/err" </dev/null)
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
mv "$XDG_STATE_HOME/sdlc/o/r/pr7/round2" "$XDG_STATE_HOME/sdlc/o/r/pr7/round2.voided-20260101T000000Z"
print_records --round 1
check "$RC" "0" "print-records: a voided round above --round does not refuse the read"
check "$OUT" "round 0
$SEED" "print-records: past a voided round above, --round reads the round below"

new_case carry-other-mode
persist --mode review --round 1 --carry
check "$RC" "2" "refusal: --carry outside --mode records exits non-zero"
check_contains "$ERR" "--carry is not accepted in --mode review" "refusal: --carry outside --mode records says so"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
