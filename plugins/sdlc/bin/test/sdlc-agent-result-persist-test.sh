#!/usr/bin/env bash
#
# sdlc-agent-result-persist-test.sh -- drive the carry form of
# plugins/sdlc/bin/sdlc-agent-result-persist --mode records against a
# sandboxed XDG_STATE_HOME: rounds are seeded with the plain records
# form, carried forward with --carry, and read back with the print modes.
#
# Reaches no network and writes nothing outside its own sandbox.
#
# Usage: sdlc-agent-result-persist-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSIST="$TEST_DIR/../sdlc-agent-result-persist"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-agent-result-persist-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0

export XDG_STATE_HOME="$SANDBOX/state"
TAB=$(printf '\t')
PR_N=0

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

# A case that stores a round gets a PR of its own, so no case reads
# another's rounds. Refusal cases write nothing and may share one.
new_pr() {
  PR_N=$((PR_N + 1))
}

persist() {
  "$PERSIST" --owner acme --repo widgets --pr "$PR_N" "$@"
}

round_dir() {
  printf '%s\n' "$XDG_STATE_HOME/sdlc/acme/widgets/pr$PR_N/round$1"
}

# Writes stdin to a sandbox file and prints its path.
stage() {
  path="$SANDBOX/$1"
  cat > "$path"
  printf '%s\n' "$path"
}

seed() {
  persist --mode records --round "$1" --from "$(stage "seed-$PR_N-$1")"
}

# Runs a carry into round 2 over whatever the case seeded, and checks
# that it exits non-zero, names what it refused, and leaves round 2
# unwritten. A trailing --round overrides the round it carries into.
check_refused() {
  label=$1
  expected=$2
  shift 2
  output=$(persist --mode records --round 2 --carry "$@" 2>&1)
  status=$?
  check "$([ "$status" -ne 0 ] && echo nonzero || echo zero)" nonzero "$label: exits non-zero"
  check_contains "$output" "$expected" "$label: names what it refused"
  check "$([ -e "$(round_dir 2)" ] && echo written || echo absent)" absent "$label: writes nothing"
}

ROUND1_RECORDS='T1
claim: The diff satisfies acceptance criterion "a" of #7.
issues: #7
settle-mode: semantic
pointers: plugins/x/bin/x, "main"
state: retired
state-detail: survived
settled-at: aaaa

T2
claim: The flag is refused outside records.
issues: #7
settle-mode: mechanical
pointers: plugins/x/bin/x
state: disproved
state-detail: finding 1, Low
settled-at: aaaa
severity-override: Low'

# --- a carried round with a retirement edit ---------------------------------

new_pr
printf '%s\n' "$ROUND1_RECORDS" | seed 1 >/dev/null
edits=$(stage "edits-$PR_N" <<EOF
T2${TAB}state${TAB}retired
T2${TAB}state-detail${TAB}human-refuted
T2${TAB}settled-at${TAB}bbbb
EOF
)
persist --mode records --round 2 --carry --edits "$edits" --from "$(stage "new-$PR_N" </dev/null)"
check "$?" 0 "retirement: the carry exits zero"
check "$(persist --mode print-round-records --round 2)" 'T1
claim: The diff satisfies acceptance criterion "a" of #7.
issues: #7
settle-mode: semantic
pointers: plugins/x/bin/x, "main"
state: retired
state-detail: survived
settled-at: aaaa

T2
claim: The flag is refused outside records.
issues: #7
settle-mode: mechanical
pointers: plugins/x/bin/x
state: retired
state-detail: human-refuted
settled-at: bbbb
severity-override: Low' "retirement: only the edited fields of the edited record change"
check "$(persist --mode print-records | head -n 1)" "round 2" "retirement: print-records selects the carried round"

# --- an empty-delta carry ---------------------------------------------------

new_pr
printf '%s\n' "$ROUND1_RECORDS" | seed 1 >/dev/null
persist --mode records --round 2 --carry --edits "$(stage "edits-$PR_N" </dev/null)" \
  --from "$(stage "new-$PR_N" </dev/null)"
check "$?" 0 "empty delta: the carry exits zero with an empty edits file and an empty payload"
check "$(persist --mode print-round-records --round 2)" "$ROUND1_RECORDS" \
  "empty delta: the records carry forward unchanged"

new_pr
printf '%s\n' "$ROUND1_RECORDS" | seed 1 >/dev/null
printf '' | persist --mode records --round 2 --carry
check "$?" 0 "empty delta: an empty stdin payload is accepted"
check "$(persist --mode print-round-records --round 2)" "$ROUND1_RECORDS" \
  "empty delta: the stdin form carries the records forward unchanged"

# --- appended minted records ------------------------------------------------

new_pr
printf '%s\n' "$ROUND1_RECORDS" | seed 1 >/dev/null
edits=$(stage "edits-$PR_N" <<EOF
T2${TAB}severity-override${TAB}High
EOF
)
minted=$(stage "new-$PR_N" <<'EOF'
T3
claim: "The carry drops a record."
issues: #7
settle-mode: semantic
pointers: plugins/x/bin/x
state: disproved
state-detail: finding 2, High
settled-at: bbbb

T4
claim: The edits grammar splits at the second tab.
issues: #7
settle-mode: mechanical
pointers: plugins/x/bin/x
state: retired
state-detail: survived
settled-at: bbbb
EOF
)
persist --mode records --round 2 --carry --edits "$edits" --from "$minted"
check "$?" 0 "minted: the carry exits zero"
check "$(persist --mode print-round-records --round 2)" "${ROUND1_RECORDS%Low}High

$(cat "$minted")" "minted: the new records follow the carried ones in id order"

# --- a round-0 seed carried into round 1 ------------------------------------

new_pr
seed 0 >/dev/null <<'EOF'
T1
claim: The seed claim.
issues: #7
settle-mode: semantic
pointers: plugins/x/bin/x

T2
claim: The rejected claim.
issues: #7
settle-mode: mechanical
pointers: plugins/x/bin/x
state: retired
state-detail: human-refuted
settled-at: aaaa
EOF
edits=$(stage "edits-$PR_N" <<EOF
T1${TAB}settled-at${TAB}cccc
T1${TAB}state${TAB}retired
T1${TAB}state-detail${TAB}survived
EOF
)
persist --mode records --round 1 --carry --edits "$edits"  </dev/null
check "$?" 0 "seed: round 0 carries into round 1"
check "$(persist --mode print-round-records --round 1)" 'T1
claim: The seed claim.
issues: #7
settle-mode: semantic
pointers: plugins/x/bin/x
state: retired
state-detail: survived
settled-at: cccc

T2
claim: The rejected claim.
issues: #7
settle-mode: mechanical
pointers: plugins/x/bin/x
state: retired
state-detail: human-refuted
settled-at: aaaa' "seed: the added fields land in records-file order"

new_pr
seed 0 >/dev/null <<'EOF'
T1
claim: The seed claim.
issues: #7
settle-mode: semantic
pointers: plugins/x/bin/x
severity-override: Low
EOF
edits=$(stage "edits-$PR_N" <<EOF
T1${TAB}state${TAB}unsettled
T1${TAB}state-detail${TAB}
EOF
)
persist --mode records --round 1 --carry --edits "$edits" </dev/null
check "$(persist --mode print-round-records --round 1)" 'T1
claim: The seed claim.
issues: #7
settle-mode: semantic
pointers: plugins/x/bin/x
state: unsettled
state-detail:
severity-override: Low' "seed: an added field goes ahead of a later one, and an empty value is stored"

# --- refusals ---------------------------------------------------------------

new_pr
printf '%s\n' "$ROUND1_RECORDS" | seed 1 >/dev/null

check_refused "unknown id" "names T9, which no carried record has" \
  --edits "$(printf 'T9\tstate\tretired\n' | stage refuse-id)" </dev/null
check_refused "field outside the four" "names field claim" \
  --edits "$(printf 'T1\tclaim\tsomething else\n' | stage refuse-field)" </dev/null
check_refused "state outside the three" "sets state survived" \
  --edits "$(printf 'T1\tstate\tsurvived\n' | stage refuse-state)" </dev/null
check_refused "two edits to one field" "--edits line 2" \
  --edits "$(printf 'T1\tstate-detail\ta\nT1\tstate-detail\tb\n' | stage refuse-dup)" </dev/null
check_refused "new record already carried" "--from line 1 (T2) starts a new record whose id is already carried" \
  --from "$(printf 'T2\nclaim: x\nstate: disproved\n' | stage refuse-carried)"
check_refused "new record off the sequence" "whose next id is T3" \
  --from "$(printf 'T4\nclaim: x\nstate: disproved\n' | stage refuse-sequence)"
check_refused "round not lower" "is not lower than --round" --round 1 </dev/null

new_pr
check_refused "no carried round" "found no round" </dev/null

new_pr
seed 0 >/dev/null <<'EOF'
T1
claim: The seed claim.
issues: #7

T2
claim: The other seed claim.
issues: #7
EOF
check_refused "an unstamped seed record" "would leave T1, T2 without a state" </dev/null

new_pr
printf '%s\n' "$ROUND1_RECORDS" | seed 1 >/dev/null
output=$(printf '%s\n' "$ROUND1_RECORDS" | persist --mode records --round 2 \
  --edits "$(printf 'T1\tstate\tretired\n' | stage refuse-nocarry)" 2>&1)
check "$?" 2 "--edits without --carry: exits non-zero"
check_contains "$output" "--edits is accepted only with --carry" "--edits without --carry: names the refusal"
check "$([ -e "$(round_dir 2)" ] && echo written || echo absent)" absent "--edits without --carry: writes nothing"

output=$(persist --mode review --round 2 --carry </dev/null 2>&1)
check "$?" 2 "--carry outside records: exits non-zero"
check_contains "$output" "--carry is not accepted in --mode review" "--carry outside records: names the refusal"

output=$(persist --mode review --round 2 \
  --edits "$(printf 'T1\tstate\tretired\n' | stage refuse-editsmode)" </dev/null 2>&1)
check "$?" 2 "--edits outside records: exits non-zero"
check_contains "$output" "--edits is not accepted in --mode review" "--edits outside records: names the refusal"

check_refused "an empty --edits value" "--edits names no file" --edits "" </dev/null

# --- the plain form stores its payload whole --------------------------------

new_pr
printf 'anything at all\n' | persist --mode records --round 3
check "$(persist --mode print-round-records --round 3)" "anything at all" "plain form: stores its payload byte for byte"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all cases passed"
else
  echo "$FAILURES case(s) failed"
fi
[ "$FAILURES" -eq 0 ]
