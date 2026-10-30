#!/usr/bin/env bash
#
# sdlc-agent-result-persist-test.sh -- drive the read modes
# plugins/sdlc/bin/sdlc-agent-result-persist derives a review round from:
#
#   - --mode next over a fixture log per arm it names -- no log, a moved
#     head, generate, disprove, verify, dispose -- and over the states it
#     prints: outstanding, in flight, overdue past --deadline-minutes, and
#     returned without saving; a stopped after its enter, a duplicate
#     leave, a malformed DISPROVED report that earns no verifier, a
#     generator re-spawned at another effort, and a --full round's live
#     list.
#   - --mode dispose over result files for every row of the disposition
#     table, the state each row stamps, the severity derivation -- a
#     class-underivable finding and a human override on a theorem --
#     the verdicts with an unsettled theorem forcing BLOCKED and a member
#     of --issues no record tags, the refusal without --loop-exited, and
#     the round that spawned nothing.
#   - --mode summary over a stored records file and review file.
#
# Every fixture is built under mktemp -d with its own state root. The
# first failing case ends the run.
#
# Run directly:
#
#   plugins/sdlc/bin/test/sdlc-agent-result-persist-test.sh
#
# Reaches no network.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSIST="$TEST_DIR/../sdlc-agent-result-persist"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-agent-result-persist-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
PR='h.example/o/r#7'
TAB=$(printf '\t')
PASSED=0

pass() {
  PASSED=$((PASSED + 1))
  echo "ok   - $1"
}

fail() {
  echo "FAIL - $1"
  shift
  for line in "$@"; do
    echo "        $line"
  done
  exit 1
}

assert_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected: [$2]" "actual:   [$3]"
  fi
}

assert_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to contain: [$2]" "actual: [$3]" ;;
  esac
}

assert_lacks() {
  case "$3" in
    *"$2"*) fail "$1" "expected not to contain: [$2]" "actual: [$3]" ;;
    *) pass "$1" ;;
  esac
}

# new_case <name>: a state root and scratch directory of the case's own.
new_case() {
  CASE="$SANDBOX/$1"
  mkdir -p "$CASE/state"
  export XDG_STATE_HOME="$CASE/state"
  PR_DIR="$CASE/state/sdlc/h.example/o/r/pr7"
}

# run <args...>: runs the script against the PR, leaving stdout in OUT,
# stderr in ERR and the exit status in RC.
run() {
  OUT=$("$PERSIST" --pr "$PR" "$@" 2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
}

# must <args...>: run, and end the suite when the call fails.
must() {
  run "$@"
  [ "$RC" -eq 0 ] || fail "setup call failed: $*" "exit: $RC" "stderr: $ERR"
}

# as_child <agent-id> <args...>: runs the script from a directory named
# agent-<agent-id>, the way a child's worktree names its agent id, as run
# does, and ends the suite when the call fails.
as_child() {
  local id=$1
  shift
  mkdir -p "$CASE/agent-$id"
  OUT=$(cd "$CASE/agent-$id" && "$PERSIST" --pr "$PR" "$@" 2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
  [ "$RC" -eq 0 ] || fail "child call failed: $*" "exit: $RC" "stderr: $ERR"
}

# record <id> <claim> <issues>: one unstamped seed record.
record() {
  printf '%s\nclaim: %s\nissues: %s\nsettle-mode: semantic\npointers: a.md\n' "$1" "$2" "$3"
}

# add_seed <id> <claim> <issues> [<line>...]: appends a record to the
# case's seed, each further argument a field line of its own.
add_seed() {
  [ ! -s "$CASE/seed" ] || printf '\n' >>"$CASE/seed"
  record "$1" "$2" "$3" >>"$CASE/seed"
  shift 3
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >>"$CASE/seed"
}

# seed: stores the case's seed as round 0's records.
seed() {
  must --mode records --round 0 --from "$CASE/seed"
}

# report <path> <line>...: writes a child's report, one argument a line.
report() {
  local path=$1
  shift
  printf '%s\n' "$@" >"$path"
}

# survived, disproved, disproved_unquoted, refuted, stands and
# stands_classless <theorem> [<class>]: each writes to $CASE/r, the file
# leave hands over, the report shape it is named for answering
# <theorem>. disproved and stands take the consequence class as <class>;
# disproved_unquoted is malformed, lacking its evidence quote, and
# stands_classless carries no class line.
survived() { report "$CASE/r" "VERDICT: SURVIVED" "THEOREM: $1" "CHECKED: read a.md"; }
disproved() {
  report "$CASE/r" "VERDICT: DISPROVED" "THEOREM: $1" "COUNTEREXAMPLE: it breaks" \
    "EVIDENCE: in \`a.md\` at line 1:" "> the quoted text" "CONSEQUENCE: it ships broken" \
    "CONSEQUENCE-CLASS: $2"
}
disproved_unquoted() {
  report "$CASE/r" "VERDICT: DISPROVED" "THEOREM: $1" "COUNTEREXAMPLE: it breaks" \
    "EVIDENCE: in \`a.md\` at line 1:" "CONSEQUENCE: it ships broken" \
    "CONSEQUENCE-CLASS: defect-no-shipped-breakage"
}
refuted() { report "$CASE/r" "VERDICT: REFUTED" "THEOREM: $1" "REASON: the quote is from main"; }
stands() { report "$CASE/r" "VERDICT: STANDS" "THEOREM: $1" "CONSEQUENCE: it ships broken" "CONSEQUENCE-CLASS: $2"; }
stands_classless() { report "$CASE/r" "VERDICT: STANDS" "THEOREM: $1" "CONSEQUENCE: it ships broken"; }

# leave <agent-id> <theorem> <stage> <agent>: a child's enter, then its
# leave carrying the report last written.
leave() {
  as_child "$1" --mode enter --round 1 --theorem "$2" --stage "$3"
  as_child "$1" --mode leave --round 1 --theorem "$2" --stage "$3" --agent "$4" --from "$CASE/r"
}

# a_generated_list: round 1 anchored with its theorem list settled and no
# new theorem in it.
a_generated_list() {
  must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
  report "$CASE/r" "no new theorems"
  leave G list generate theorem-generator
}

# first_line, rest: the arm and the lines below it.
first_line() { printf '%s\n' "$OUT" | sed -n 1p; }
rest() { printf '%s\n' "$OUT" | sed 1d; }

# --- next: no log, a moved head, generate -----------------------------------

new_case next-no-log
add_seed T1 "a claim" "#1"
seed
run --mode next --round 1
assert_eq "next: exits 0 with no round log" "0" "$RC"
assert_eq "next: no round log is the no-log arm alone" "no-log" "$OUT"

new_case next-moved-head
add_seed T1 "a claim" "#1"
seed
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
run --mode next --round 1 --head-sha bbb
assert_eq "next: an anchor naming another head is the moved-head arm" "moved-head" "$OUT"
run --mode next --round 1 --head-sha aaa
assert_eq "next: an anchor naming --head-sha is not a moved head" "generate" "$(first_line)"
run --mode next --round 1
assert_eq "next: without --head-sha the head is not compared" "generate" "$(first_line)"

new_case next-generate
add_seed T1 "a claim" "#1"
seed
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
run --mode next --round 1
assert_eq "next: an unsettled list is the generate arm" "generate" "$(first_line)"
assert_eq "next: a list no generator has entered is outstanding" "generate${TAB}list${TAB}outstanding${TAB}${TAB}" "$(rest)"
as_child G --mode enter --round 1 --theorem list --stage generate
run --mode next --round 1
assert_eq "next: a generator in flight keeps the generate arm" "generate" "$(first_line)"
assert_contains "next: the generator in flight names its agent id" "generate${TAB}list${TAB}in-flight${TAB}G${TAB}" "$(rest)"

new_case next-generator-settled
add_seed T1 "a claim" "#1"
seed
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
must --mode spawn --round 1 --theorem list --stage generate --agent theorem-generator --model default --effort low
report "$CASE/r" "no new theorems"
leave G list generate theorem-generator
run --mode next --round 1
assert_eq "next: the generator's file settles the list" "disprove" "$(first_line)"
run --mode print --round 1
assert_contains "print: a result line per result file" \
  "result list theorem-generator $PR_DIR/round1/list-theorem-generator" "$OUT"
must --mode spawn --round 1 --theorem list --stage generate --agent theorem-generator --model default --effort medium
run --mode next --round 1
assert_eq "next: a spawn at another effort leaves a settled list settled" "disprove" "$(first_line)"

# --- next: disprove, its child states, and the barrier --------------------

new_case next-disprove
add_seed T1 "first" "#1"
add_seed T2 "second" "#1"
add_seed T3 "third" "#1"
seed
a_generated_list
run --mode next --round 1
assert_eq "next: a settled list with live theorems unattacked is the disprove arm" "disprove" "$(first_line)"
assert_eq "next: every live theorem without a child is outstanding" \
  "disprove${TAB}T1${TAB}outstanding${TAB}${TAB}
disprove${TAB}T2${TAB}outstanding${TAB}${TAB}
disprove${TAB}T3${TAB}outstanding${TAB}${TAB}" "$(rest)"

as_child A --mode enter --round 1 --theorem T1 --stage disprove
as_child B --mode enter --round 1 --theorem T2 --stage disprove
"$PERSIST" --pr "$PR" --mode stopped --round 1 --theorem T2 --stage disprove --agent-id B >/dev/null
as_child C --mode enter --round 1 --theorem T3 --stage disprove
"$PERSIST" --pr "$PR" --mode return --round 1 --theorem T3 --stage disprove --agent-id C >/dev/null
run --mode next --round 1 --deadline-minutes 15
assert_eq "next: a child in flight keeps the disprove arm" "disprove" "$(first_line)"
assert_contains "next: a child in flight is printed in flight" "disprove${TAB}T1${TAB}in-flight${TAB}A${TAB}" "$(rest)"
assert_lacks "next: a theorem with a child in flight is never outstanding" "disprove${TAB}T1${TAB}outstanding" "$(rest)"
assert_contains "next: a stopped after its enter leaves the theorem outstanding" "disprove${TAB}T2${TAB}outstanding${TAB}${TAB}" "$(rest)"
assert_contains "next: a child that returned without a leave is returned-unsaved before its deadline" \
  "disprove${TAB}T3${TAB}returned-unsaved${TAB}C${TAB}" "$(rest)"

# A child that entered long ago is past any deadline.
printf 'enter T1 disprove 2000-01-01T00:00:00Z D -\n' >>"$PR_DIR/round1/log"
run --mode next --round 1 --deadline-minutes 15
assert_contains "next: a child past --deadline-minutes is overdue" \
  "disprove${TAB}T1${TAB}overdue${TAB}D${TAB}2000-01-01T00:00:00Z" "$(rest)"
run --mode next --round 1
assert_contains "next: without --deadline-minutes nothing is overdue" "disprove${TAB}T1${TAB}in-flight${TAB}D${TAB}" "$(rest)"

new_case next-verify-dispose
add_seed T1 "first" "#1"
add_seed T2 "second" "#1"
add_seed T3 "third" "#1"
seed
a_generated_list
survived T1
leave A T1 disprove theorem-disprover
disproved T2 defect-no-shipped-breakage
leave B T2 disprove theorem-disprover
disproved_unquoted T3
leave C T3 disprove theorem-disprover
run --mode next --round 1
assert_eq "next: no live theorem outstanding and a DISPROVED report unverified is the verify arm" "verify" "$(first_line)"
assert_eq "next: only the well-formed DISPROVED report earns a verifier" "verify${TAB}T2${TAB}outstanding${TAB}${TAB}" "$(rest)"
as_child V --mode enter --round 1 --theorem T2 --stage verify
run --mode next --round 1
assert_eq "next: a verifier in flight keeps the verify arm" "verify" "$(first_line)"
stands T2 optional-polish
as_child V --mode leave --round 1 --theorem T2 --stage verify --agent counterexample-verifier --from "$CASE/r"
run --mode next --round 1
assert_eq "next: no theorem outstanding in the verify stage is the dispose arm" "dispose" "$OUT"

new_case next-duplicate-leave
add_seed T1 "first" "#1"
seed
a_generated_list
disproved T1 defect-no-shipped-breakage
leave A T1 disprove theorem-disprover
survived T1
leave B T1 disprove theorem-disprover
assert_eq "duplicate leave: both leave records stay in the log" "2" \
  "$(awk '$1 == "leave" && $2 == "T1"' "$PR_DIR/round1/log" | wc -l | tr -d ' ')"
run --mode next --round 1
assert_eq "next: a duplicate leave settles its theorem once, from the later report" "dispose" "$OUT"
run --mode dispose --round 1 --issues 1
assert_eq "dispose: a duplicate leave takes the one file there is, the later child's" \
  "T1${TAB}verified-survived${TAB}-${TAB}-${TAB}retired${TAB}survived" "$(printf '%s\n' "$OUT" | sed -n 1p)"

new_case next-new-records-and-full
add_seed T1 "first" "#1"
add_seed T2 "second" "#1" "state: retired" "state-detail: human-refuted"
add_seed T3 "third" "#1" "state: retired" "state-detail: survived"
seed
a_generated_list
record T4 "a new one" "#1" >"$CASE/new"
printf 'T1\tstate\tretired\nT1\tstate-detail\tsubject removed\n' >"$CASE/edits"
run --mode next --round 1 --edits "$CASE/edits" --from "$CASE/new"
assert_eq "next: a theorem this round's edits retire is not live, and a --from record is" \
  "disprove${TAB}T4${TAB}outstanding${TAB}${TAB}" "$(rest)"
run --mode next --round 1 --full --from "$CASE/new"
assert_eq "next: --full puts a retired theorem back on the live list, never a human-refuted one" \
  "disprove${TAB}T1${TAB}outstanding${TAB}${TAB}
disprove${TAB}T3${TAB}outstanding${TAB}${TAB}
disprove${TAB}T4${TAB}outstanding${TAB}${TAB}" "$(rest)"
printf 'T9\tstate\tretired\n' >"$CASE/bad-edits"
run --mode next --round 1 --edits "$CASE/bad-edits"
assert_eq "next: an edit naming no carried record is refused" "2" "$RC"
assert_contains "next: the refusal names the edit" "names T9, which no carried record has" "$ERR"

# --- dispose: every row, the severities and the verdicts -------------------

new_case dispose-rows
add_seed T1 "survives" "#1"
add_seed T2 "is refuted" "#1"
add_seed T3 "stands at polish" "#1"
add_seed T4 "verifier malformed" "#2"
add_seed T5 "nothing derives a class" "#2"
add_seed T7 "overridden by a human" "#3"
add_seed T8 "never verified" "#4"
add_seed T9 "disprover malformed" "#4"
add_seed T10 "never disproved" "#5"
seed
a_generated_list
survived T1
leave D1 T1 disprove theorem-disprover
disproved T2 defect-no-shipped-breakage
leave D2 T2 disprove theorem-disprover
refuted T2
leave V2 T2 verify counterexample-verifier
disproved T3 defect-no-shipped-breakage
leave D3 T3 disprove theorem-disprover
stands T3 optional-polish
leave V3 T3 verify counterexample-verifier
disproved T4 defect-no-shipped-breakage
leave D4 T4 disprove theorem-disprover
stands_classless T4
leave V4 T4 verify counterexample-verifier
disproved T5 not-a-class
leave D5 T5 disprove theorem-disprover
stands_classless T5
leave V5 T5 verify counterexample-verifier
disproved T7 behavior-broken-or-criterion-unmet
leave D7 T7 disprove theorem-disprover
stands T7 behavior-broken-or-criterion-unmet
leave V7 T7 verify counterexample-verifier
disproved T8 breaks-production
leave D8 T8 disprove theorem-disprover
report "$CASE/r" "VERDICT: SURVIVED" "THEOREM: T9"
leave D9 T9 disprove theorem-disprover
printf 'T7\tseverity-override\tLow\n' >"$CASE/edits"

run --mode dispose --round 1 --edits "$CASE/edits" --loop-exited
assert_eq "dispose: without --issues it is refused" "2" "$RC"
assert_contains "dispose: the refusal names --issues" "--issues is required in --mode dispose" "$ERR"

run --mode dispose --round 1 --edits "$CASE/edits" --issues "1 2 3 4 5"
assert_eq "dispose: without --loop-exited a theorem with no result file for its stage exits non-zero" "3" "$RC"
assert_eq "dispose: without --loop-exited no row and no verdict is printed" "" "$OUT"
assert_contains "dispose: the refusal names the theorem missing its verifier" "T8 (verify)" "$ERR"
assert_contains "dispose: the refusal names the theorem missing its disprover" "T10 (disprove)" "$ERR"

run --mode dispose --round 1 --edits "$CASE/edits" --loop-exited --issues "#1, #2 #3,#4 #5 #6"
assert_eq "dispose: with --loop-exited it exits 0" "0" "$RC"
assert_eq "dispose: every row of the disposition table, its state, severity and the verdicts, a member no record tags approved" \
"T1${TAB}verified-survived${TAB}-${TAB}-${TAB}retired${TAB}survived
T2${TAB}verified-refuted${TAB}-${TAB}-${TAB}retired${TAB}disproved-but-refuted
T3${TAB}finding${TAB}optional-polish${TAB}Low${TAB}disproved${TAB}finding 3, Low
T4${TAB}finding-verifier-malformed${TAB}defect-no-shipped-breakage${TAB}Medium${TAB}disproved${TAB}finding 2, Medium
T5${TAB}finding-verifier-malformed${TAB}class-underivable${TAB}High${TAB}disproved${TAB}finding 1, High, class-underivable
T7${TAB}finding${TAB}behavior-broken-or-criterion-unmet${TAB}Low${TAB}disproved${TAB}finding 4, Low
T8${TAB}disproved-unverified${TAB}-${TAB}-${TAB}disproved${TAB}unverified
T9${TAB}unsettled-disprover-malformed${TAB}-${TAB}-${TAB}unsettled${TAB}-
T10${TAB}unsettled-no-verdict${TAB}-${TAB}-${TAB}unsettled${TAB}-
verdict${TAB}1${TAB}APPROVED
verdict${TAB}2${TAB}NEEDS_CHANGES
verdict${TAB}3${TAB}APPROVED
verdict${TAB}4${TAB}BLOCKED
verdict${TAB}5${TAB}BLOCKED
verdict${TAB}6${TAB}APPROVED
verdict${TAB}overall${TAB}BLOCKED" "$OUT"

run --mode dispose --round 1 --edits "$CASE/edits" --loop-exited --issues "6 3"
assert_eq "dispose: the members come first, in the order given, then each other issue a record tags" \
  "6 3 1 2 4 5 overall" "$(printf '%s\n' "$OUT" | awk -F '\t' '$1 == "verdict" { printf "%s%s", sep, $2; sep = " " }')"

run --mode dispose --round 1 --edits "$CASE/edits" --loop-exited --issues '1 *'
assert_eq "dispose: an --issues member that is no issue is refused" "2" "$RC"

printf 'T3\tseverity-override\tsevere\n' >"$CASE/bad-edits"
run --mode dispose --round 1 --edits "$CASE/bad-edits" --loop-exited --issues 1
assert_eq "dispose: an override that is no severity is refused" "2" "$RC"
assert_contains "dispose: the refusal names the override" "the severity-override of T3 is severe" "$ERR"

new_case dispose-approved
add_seed T1 "survives" "#1"
add_seed T2 "polish" "#1"
seed
a_generated_list
survived T1
leave D1 T1 disprove theorem-disprover
disproved T2 optional-polish
leave D2 T2 disprove theorem-disprover
stands T2 optional-polish
leave V2 T2 verify counterexample-verifier
run --mode dispose --round 1 --issues 1
assert_eq "dispose: only Low findings approve" \
  "verdict${TAB}1${TAB}APPROVED
verdict${TAB}overall${TAB}APPROVED" "$(printf '%s\n' "$OUT" | grep '^verdict')"

new_case dispose-spawned-nothing
add_seed T1 "a" "#1" "state: retired" "state-detail: survived"
add_seed T2 "b" "#1" "state: disproved" "state-detail: finding 1, Medium"
add_seed T3 "c" "#2" "state: unsettled"
must --mode records --round 1 --from "$CASE/seed"
must --mode anchor --round 2 --head-sha aaa --round-type code-and-instruction-markdown
run --mode dispose --round 2 --issues "1 2"
assert_eq "dispose: a round that spawned nothing gives no row and carries each verdict forward" \
  "verdict${TAB}1${TAB}NEEDS_CHANGES
verdict${TAB}2${TAB}BLOCKED
verdict${TAB}overall${TAB}BLOCKED" "$OUT"

# --- summary ---------------------------------------------------------------

new_case summary
add_seed T1 "the first claim" "#1"
add_seed T2 "the second claim" "#1"
seed
a_generated_list
survived T1
leave D1 T1 disprove theorem-disprover
disproved T2 behavior-broken-or-criterion-unmet
leave D2 T2 disprove theorem-disprover
stands T2 behavior-broken-or-criterion-unmet
leave V2 T2 verify counterexample-verifier
printf 'T1\tstate\tretired\nT1\tstate-detail\tsurvived\nT1\tsettled-at\taaa\nT2\tstate\tdisproved\nT2\tstate-detail\tfinding 1, High\n' \
  >"$CASE/edits"
must --mode records --carry --round 1 --edits "$CASE/edits"
cat >"$CASE/review" <<'EOF'
## Verdicts

- #1 — NEEDS_CHANGES (1 High)
- **Overall — NEEDS_CHANGES**

## Review method

Head aaa, a delta round over round 0.

```text
## not a heading inside a fence
```

## Disproved theorems

T2: the argued counterexample, > the quoted text

## Findings

**Finding:** the argued finding text

## Overall verdict

Fix finding 1 to approve.

## Closing-line corrections

none
EOF
must --mode review --round 1 --from "$CASE/review"
run --mode summary --round 1
assert_eq "summary: exits 0" "0" "$RC"
cat >"$CASE/expected" <<'EOF'
## Verdicts

- #1 — NEEDS_CHANGES (1 High)
- **Overall — NEEDS_CHANGES**

## Review method

Head aaa, a delta round over round 0.

```text
## not a heading inside a fence
```

## Theorems

Detail for this round is under `${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/h.example/o/r/pr7/`.

- T1 — retired, survived — was unattacked — `round1/T1-theorem-disprover`
- T2 — disproved, finding 1, High — was unattacked — `round1/review`, `round1/T2-counterexample-verifier`, `round1/T2-theorem-disprover`

## Findings

- 1 — High — from T2, #1 — `round1/review`

## Overall verdict

Fix finding 1 to approve.

## Closing-line corrections

none
EOF
assert_eq "summary: the body, in order" "$(cat "$CASE/expected")" "$OUT"
assert_lacks "summary: no argued text" "the argued" "$OUT"
assert_lacks "summary: no quoted counterexample" "the quoted text" "$OUT"
assert_lacks "summary: no records" "the first claim" "$OUT"

# Round 2 carries T1 forward retired; its detail is in round 1.
must --mode anchor --round 2 --head-sha bbb --round-type code-and-instruction-markdown
printf 'T2\tstate\tretired\nT2\tstate-detail\tsurvived\nT2\tsettled-at\tbbb\n' >"$CASE/edits2"
survived T2
as_child D3 --mode leave --round 2 --theorem T2 --stage disprove --agent theorem-disprover --from "$CASE/r"
must --mode records --carry --round 2 --edits "$CASE/edits2"
must --mode review --round 2 --from "$CASE/review"
run --mode summary --round 2
assert_contains "summary: a carried-forward retired theorem points at the older round" \
  "- T1 — retired, survived — unchanged — \`round1/T1-theorem-disprover\`" "$OUT"
assert_contains "summary: a theorem settled this round says what it was" \
  "- T2 — retired, survived — was disproved, finding 1, High — \`round2/T2-theorem-disprover\`" "$OUT"

sed '/^## Overall verdict/,/^Fix/d' "$CASE/review" >"$CASE/short-review"
must --mode review --round 2 --from "$CASE/short-review"
run --mode summary --round 2
assert_eq "summary: a review missing a copied section is refused" "2" "$RC"
assert_contains "summary: the refusal names the section" '"## Overall verdict"' "$ERR"

echo "$PASSED passed"
