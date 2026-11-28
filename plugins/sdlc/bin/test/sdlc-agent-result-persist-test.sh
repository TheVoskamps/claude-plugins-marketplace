#!/usr/bin/env bash
#
# sdlc-agent-result-persist-test.sh -- drive the read modes
# plugins/sdlc/bin/sdlc-agent-result-persist derives a review round from,
# and the generator's leave whose list they read:
#
#   - --mode next over a fixture log per arm it names -- no log, a moved
#     head, generate, assess, disprove, verify, dispose -- and over the
#     states it prints: outstanding, in flight, overdue past
#     --deadline-minutes, a child that returned with no leave staying in
#     flight until its deadline, and spawned and yet to enter, overdue
#     past the deadline from its last spawn; a stopped
#     after its enter, one before its enter that leaves the theorem
#     outstanding, and a replacement spawned after such a write-off that
#     entered and was stopped, which leaves it outstanding too; a
#     duplicate leave, a malformed DISPROVED report that earns no
#     verifier, a generator re-spawned at another effort, and a --full
#     round's live list, with a theorem the assessor rejected that round
#     on it; a stage past the arm, the assess stage's included, whose
#     in-flight and spawned children are printed and whose overdue and
#     outstanding theorems are not; and a disprover or verifier spawned
#     or entered for a theorem no records file names, in the arm's stage
#     and past it.
#   - --mode leave --stage generate refusing a list whose COUNT: line is
#     missing or whose counts do not match its records' settle modes, and
#     storing one whose counts match; and, when the awk reading its ids or
#     its count line fails, removing its staging file.
#   - --mode leave --stage assess refusing an empty assessment, one with no
#     COUNT: line and one whose counts do not match its candidate and add
#     blocks, and storing one whose counts match, the lone line
#     COUNT: candidates 0, adds 0 included.
#   - --mode wait ending on a leave for a child in flight, on the earliest
#     child's deadline -- a child spawned and not yet entered included,
#     and a replacement spawned after its predecessor was written off --
#     and at once with no child in flight in the stage, a child written
#     off before its enter included, and a replacement that entered and
#     was stopped after such a write-off; and the refusal without
#     --deadline-minutes.
#   - --mode dispose over result files for every row of the disposition
#     table, the state each row stamps, the severity derivation -- a
#     class-underivable finding and a human override on a theorem --
#     the verdicts with an unsettled theorem forcing BLOCKED and a member
#     of --issues no record tags, the refusal without --loop-exited, the
#     round that spawned nothing, and a theorem the assessor rejected,
#     which only a --full round gives a row.
#   - --mode summary over a stored records file and review file, and the
#     review-round stamp it opens with; and --out over a new path, an
#     existing file, a refused and a failed render, a failed staging, a
#     missing parent directory, a directory, an empty value and another
#     mode.
#   - --mode rounds over rounds with and without a log, round 0 and a
#     voided round among them.
#   - --mode progress over a PR with no log, a round mid-disprove beside a
#     higher voided round, a round holding a review file, a log with no
#     child record and one with no anchor, and its refusal of --round,
#     --from and --edits.
#   - --mode enter naming the child's transcript under CLAUDE_CONFIG_DIR
#     when it is set, and under $HOME/.claude when it is unset or empty.
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

# unsettled <theorem> <line>...: writes to $CASE/r an UNSETTLED report
# answering <theorem>, each further argument a line of it, so a case
# chooses which of REASON and CHECKED it carries.
unsettled() {
  local theorem=$1
  shift
  report "$CASE/r" "VERDICT: UNSETTLED" "THEOREM: $theorem" "$@"
}

# subject_removed <theorem> <line>...: writes to $CASE/r a SUBJECT REMOVED
# report answering <theorem>, each further argument a line of it, as
# unsettled does.
subject_removed() {
  local theorem=$1
  shift
  report "$CASE/r" "VERDICT: SUBJECT REMOVED" "THEOREM: $theorem" "$@"
}

# leave <agent-id> <theorem> <stage> <agent>: a child's enter, then its
# leave carrying the report last written.
leave() {
  as_child "$1" --mode enter --round 1 --theorem "$2" --stage "$3"
  as_child "$1" --mode leave --round 1 --theorem "$2" --stage "$3" --agent "$4" --from "$CASE/r"
}

# a_generated_list: round 1 anchored with its theorem list settled and
# assessed, and no new theorem in it.
a_generated_list() {
  must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
  report "$CASE/r" "no new theorems" "COUNT: mechanical 0, semantic 0"
  leave G list generate theorem-generator
  report "$CASE/r" "COUNT: candidates 0, adds 0"
  leave S list assess theorem-assessor
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
report "$CASE/r" "no new theorems" "COUNT: mechanical 0, semantic 0"
leave G list generate theorem-generator
run --mode next --round 1
assert_eq "next: the generator's file settles the list" "assess" "$(first_line)"
run --mode print --round 1
assert_contains "print: a result line per result file" \
  "result list theorem-generator $PR_DIR/round1/list-theorem-generator" "$OUT"
must --mode spawn --round 1 --theorem list --stage generate --agent theorem-generator --model default --effort medium
run --mode next --round 1
assert_eq "next: a spawn at another effort leaves a settled list settled" "assess" "$(first_line)"

# --- leave: a generator's count line ----------------------------------------

# generate_leave <line>...: the generator G's leave for round 1, its report
# the arguments, one a line, run as run does so a refusal is observed.
generate_leave() {
  report "$CASE/r" "$@"
  mkdir -p "$CASE/agent-G"
  OUT=$(cd "$CASE/agent-G" && "$PERSIST" --pr "$PR" --mode leave --round 1 --theorem list --stage generate \
    --agent theorem-generator --from "$CASE/r" 2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
}

# no_result: whether round 1 holds no generator result file and no leave.
no_result() {
  [ ! -e "$PR_DIR/round1/list-theorem-generator" ] && ! grep -q '^leave' "$PR_DIR/round1/log" && echo none || echo written
}

new_case leave-generate-count
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
as_child G --mode enter --round 1 --theorem list --stage generate
generate_leave T1 "claim: a" "issues: #1" "settle-mode: mechanical" "pointers: a.md"
assert_eq "leave: a generator's list with no COUNT: line is refused" "2" "$RC"
assert_contains "leave: the refusal names the missing count line" \
  "does not end with a line COUNT: mechanical <m>, semantic <s>" "$ERR"
assert_eq "leave: a list refused for its count stores nothing" "none" "$(no_result)"
generate_leave T1 "claim: a" "issues: #1" "settle-mode: mechanical" "pointers: a.md" "" \
  T2 "claim: b" "issues: #1" "settle-mode: semantic" "pointers: a.md" "" "COUNT: mechanical 2, semantic 0"
assert_eq "leave: a COUNT: line that does not match the settle modes is refused" "2" "$RC"
assert_contains "leave: the refusal names the line and the records' counts" \
  '"COUNT: mechanical 2, semantic 0", and its records hold mechanical 1, semantic 1' "$ERR"
assert_eq "leave: a list refused for a wrong count stores nothing" "none" "$(no_result)"
generate_leave T1 "claim: a" "issues: #1" "settle-mode: mechanical" "pointers: a.md" "" \
  "COUNT: mechanical 1, semantic 0" "" RETIREMENTS "T9 — removed by the delta."
assert_eq "leave: a COUNT: line followed by RETIREMENTS is refused" "2" "$RC"
generate_leave T1 "claim: a" "issues: #1" "settle-mode: mechanical" "pointers: a.md" "" \
  T2 "claim: b" "issues: #1" "settle-mode: semantic" "pointers: a.md" "" \
  RETIREMENTS "T9 — removed by the delta." "" "COUNT: mechanical 1, semantic 1"
assert_eq "leave: a list whose COUNT: line, after its retirements, matches its settle modes is stored" "0:$PR_DIR/round1/list-theorem-generator" "$RC:$OUT"
assert_eq "leave: the stored list is the report" "$(cat "$CASE/r")" "$(cat "$PR_DIR/round1/list-theorem-generator")"

# A failed awk read of a generator's list removes its staging file. The
# shim fails the one awk call whose program holds the marker it is given
# and runs the real awk for every other.
REAL_AWK=$(command -v awk)
new_case leave-generate-awk-failure
mkdir -p "$CASE/shim" "$CASE/tmp"
report "$CASE/shim/awk" "#!/usr/bin/env bash" "for arg in \"\$@\"; do" \
  "  case \"\$arg\" in *\"\$FAIL_AWK_ON\"*) exit 1 ;; esac" "done" "exec \"$REAL_AWK\" \"\$@\""
chmod +x "$CASE/shim/awk"
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
as_child G --mode enter --round 1 --theorem list --stage generate
for marker in carried_file settle-mode:; do
  report "$CASE/r" T1 "claim: a" "issues: #1" "settle-mode: semantic" "pointers: a.md" "" "COUNT: mechanical 0, semantic 1"
  OUT=$(cd "$CASE/agent-G" && FAIL_AWK_ON=$marker TMPDIR="$CASE/tmp" PATH="$CASE/shim:$PATH" "$PERSIST" --pr "$PR" \
    --mode leave --round 1 --theorem list --stage generate --agent theorem-generator --from "$CASE/r" 2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
  assert_eq "leave: a failed awk read of the list ($marker) is refused" "2" "$RC"
  assert_contains "leave: the refusal says the report could not be read ($marker)" "could not read the" "$ERR"
  assert_eq "leave: a failed awk read of the list ($marker) leaves no staging file" "" "$(ls -A "$CASE/tmp")"
  assert_eq "leave: a failed awk read of the list ($marker) stores nothing" "none" "$(no_result)"
done

# --- next: assess, between generate and disprove ---------------------------

new_case next-assess
add_seed T1 "a claim" "#1"
seed
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
report "$CASE/r" "no new theorems" "COUNT: mechanical 0, semantic 0"
leave G list generate theorem-generator
run --mode next --round 1
assert_eq "next: a settled, unassessed list is the assess arm" "assess" "$(first_line)"
assert_eq "next: no disprove line is printed before the list is assessed" \
  "assess${TAB}list${TAB}outstanding${TAB}${TAB}" "$(rest)"
as_child S --mode enter --round 1 --theorem list --stage assess
run --mode next --round 1
assert_eq "next: an assessor in flight keeps the assess arm" "assess" "$(first_line)"
assert_contains "next: the assessor in flight names its agent id" "assess${TAB}list${TAB}in-flight${TAB}S${TAB}" "$(rest)"
: >"$CASE/empty"
run --mode leave --round 1 --theorem list --stage assess --agent theorem-assessor --from "$CASE/empty"
assert_eq "leave: an empty assessment is refused" "2" "$RC"
report "$CASE/r" "T1" "action: accept" "reason: it tests the criterion" "" "COUNT: candidates 1, adds 0"
as_child S --mode leave --round 1 --theorem list --stage assess --agent theorem-assessor --from "$CASE/r"
assert_eq "leave: an assessment needs no THEOREM: line and prints its result file" \
  "$PR_DIR/round1/list-theorem-assessor" "$OUT"
run --mode next --round 1
assert_eq "next: the assessor's file settles the assessment" "disprove" "$(first_line)"
assert_eq "next: the assessed list's live theorems are outstanding" \
  "disprove${TAB}T1${TAB}outstanding${TAB}${TAB}" "$(rest)"

# --- leave: an assessor's count line ----------------------------------------

# assess_leave <line>...: the assessor S's leave for round 1, its report
# the arguments, one a line, run as run does so a refusal is observed.
assess_leave() {
  report "$CASE/r" "$@"
  mkdir -p "$CASE/agent-S"
  OUT=$(cd "$CASE/agent-S" && "$PERSIST" --pr "$PR" --mode leave --round 1 --theorem list --stage assess \
    --agent theorem-assessor --from "$CASE/r" 2>"$CASE/err" </dev/null)
  RC=$?
  ERR=$(cat "$CASE/err")
}

# no_assessment: whether round 1 holds no assessor result file and no
# assess leave.
no_assessment() {
  [ ! -e "$PR_DIR/round1/list-theorem-assessor" ] && ! grep -q '^leave list assess' "$PR_DIR/round1/log" \
    && echo none || echo written
}

new_case leave-assess-count
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
report "$CASE/r" "no new theorems" "COUNT: mechanical 0, semantic 0"
leave G list generate theorem-generator
as_child S --mode enter --round 1 --theorem list --stage assess
: >"$CASE/empty"
run --mode leave --round 1 --theorem list --stage assess --agent theorem-assessor --from "$CASE/empty"
assert_eq "leave: an empty assessment is refused even though a count line could be zero" "2" "$RC"
assert_contains "leave: the empty assessment's refusal names the empty payload" "is empty" "$ERR"
assert_eq "leave: an empty assessment stores nothing" "none" "$(no_assessment)"
assess_leave T1 "action: accept" "reason: it tests the criterion"
assert_eq "leave: an assessment with no COUNT: line is refused" "2" "$RC"
assert_contains "leave: the refusal names the missing assessment count line" \
  "does not end with a line COUNT: candidates <n>, adds <m>" "$ERR"
assert_eq "leave: an assessment refused for its count stores nothing" "none" "$(no_assessment)"
assess_leave T1 "action: accept" "reason: it tests the criterion" "" ADDS "claim: c" "issues: #1" \
  "settle-mode: semantic" "pointers: a.md" "reason: uncovered" "" "COUNT: candidates 1, adds 2"
assert_eq "leave: a COUNT: line that does not match the blocks is refused" "2" "$RC"
assert_contains "leave: the refusal names the line and the blocks' counts" \
  '"COUNT: candidates 1, adds 2", and its blocks hold candidates 1, adds 1' "$ERR"
assert_eq "leave: an assessment refused for a wrong count stores nothing" "none" "$(no_assessment)"
assess_leave "COUNT: candidates 0, adds 0"
assert_eq "leave: an assessment of nothing that found no gap is stored" "0:$PR_DIR/round1/list-theorem-assessor" "$RC:$OUT"
assert_eq "leave: the stored assessment is the report" "$(cat "$CASE/r")" "$(cat "$PR_DIR/round1/list-theorem-assessor")"
assert_contains "leave: the stored assessment writes a leave line" "leave list assess" "$(cat "$PR_DIR/round1/log")"
run --mode next --round 1
assert_eq "next: an assessment of nothing settles the assess stage" "dispose" "$(first_line)"

new_case leave-assess-count-blocks
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
report "$CASE/r" "no new theorems" "COUNT: mechanical 0, semantic 0"
leave G list generate theorem-generator
as_child S --mode enter --round 1 --theorem list --stage assess
assess_leave T1 "action: merge" "reason: same claim" "partners: T2" "claim: ab" "" \
  T3 "action: accept" "reason: fine" "" ADDS "claim: c" "issues: #1" "settle-mode: semantic" \
  "pointers: a.md" "reason: uncovered" "" "claim: d" "issues: #1" "settle-mode: semantic" \
  "pointers: a.md" "reason: uncovered" "" "COUNT: candidates 2, adds 2"
assert_eq "leave: an assessment whose COUNT: line matches its candidate and add blocks is stored" \
  "0:$PR_DIR/round1/list-theorem-assessor" "$RC:$OUT"

new_case wait-assess
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
printf 'enter list assess 2000-01-01T00:00:00Z S -\n' >>"$PR_DIR/round1/log"
run --mode wait --round 1 --stage assess --deadline-minutes 15
assert_eq "wait: an assessor past its deadline is waited on in the assess stage" \
  "deadline${TAB}list${TAB}S" "$OUT"
run --mode wait --round 1 --stage disprove --deadline-minutes 15
assert_eq "wait: an assessor in flight is not waited on in another stage" "none" "$OUT"

new_case next-past-the-arm
add_seed T1 "first" "#1"
add_seed T2 "second" "#1"
add_seed T3 "third" "#1"
add_seed T4 "fourth" "#1"
seed
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
report "$CASE/r" "no new theorems" "COUNT: mechanical 0, semantic 0"
leave G list generate theorem-generator
as_child A --mode enter --round 1 --theorem T1 --stage disprove
must --mode spawn --round 1 --theorem T2 --stage disprove --agent theorem-disprover --model default --effort low
printf 'enter T3 disprove 2000-01-01T00:00:00Z D -\n' >>"$PR_DIR/round1/log"
run --mode next --round 1 --deadline-minutes 15
assert_eq "next: a child in flight past the arm leaves the arm where it is" "assess" "$(first_line)"
assert_contains "next: a child in flight in a stage past the arm is printed in flight" \
  "disprove${TAB}T1${TAB}in-flight${TAB}A${TAB}" "$(rest)"
assert_contains "next: a child spawned in a stage past the arm is printed spawned" \
  "disprove${TAB}T2${TAB}spawned${TAB}-${TAB}" "$(rest)"
assert_lacks "next: an overdue child in a stage past the arm is not printed" "disprove${TAB}T3" "$(rest)"
assert_lacks "next: an outstanding theorem in a stage past the arm is not printed" "disprove${TAB}T4" "$(rest)"

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
assert_contains "next: a child that returned without a leave stays in flight before its deadline" \
  "disprove${TAB}T3${TAB}in-flight${TAB}C${TAB}" "$(rest)"
assert_lacks "next: a child that returned without a leave is not outstanding" \
  "disprove${TAB}T3${TAB}outstanding" "$(rest)"

# A child that entered long ago is past any deadline, and one that also
# returned is overdue on the same terms.
printf 'enter T1 disprove 2000-01-01T00:00:00Z D -\n' >>"$PR_DIR/round1/log"
printf 'enter T3 disprove 2000-01-01T00:00:00Z E -\n' >>"$PR_DIR/round1/log"
"$PERSIST" --pr "$PR" --mode return --round 1 --theorem T3 --stage disprove --agent-id E >/dev/null
run --mode next --round 1 --deadline-minutes 15
assert_contains "next: a child past --deadline-minutes is overdue" \
  "disprove${TAB}T1${TAB}overdue${TAB}D${TAB}2000-01-01T00:00:00Z" "$(rest)"
assert_contains "next: a child that returned without a leave is overdue past its deadline" \
  "disprove${TAB}T3${TAB}overdue${TAB}E${TAB}2000-01-01T00:00:00Z" "$(rest)"
survived T3
as_child E --mode leave --round 1 --theorem T3 --stage disprove --agent theorem-disprover --from "$CASE/r"
run --mode next --round 1 --deadline-minutes 15
assert_lacks "next: a returned child's own leave ends its flight" "disprove${TAB}T3${TAB}" "$(rest)"
run --mode next --round 1
assert_contains "next: without --deadline-minutes nothing is overdue" "disprove${TAB}T1${TAB}in-flight${TAB}D${TAB}" "$(rest)"

new_case next-spawned
add_seed T1 "first" "#1"
add_seed T2 "second" "#1"
add_seed T3 "third" "#1"
seed
a_generated_list
must --mode spawn --round 1 --theorem T1 --stage disprove --agent theorem-disprover --model default --effort default
must --mode spawn --round 1 --theorem T2 --stage disprove --agent theorem-disprover --model default --effort default
as_child B --mode enter --round 1 --theorem T2 --stage disprove
"$PERSIST" --pr "$PR" --mode stopped --round 1 --theorem T2 --stage disprove --agent-id B >/dev/null
must --mode spawn --round 1 --theorem T2 --stage disprove --agent theorem-disprover --model default --effort default
printf 'spawn T3 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
run --mode next --round 1 --deadline-minutes 15
assert_eq "next: a child spawned and yet to enter keeps the disprove arm" "disprove" "$(first_line)"
assert_contains "next: a theorem spawned and not entered is spawned" "disprove${TAB}T1${TAB}spawned${TAB}-${TAB}" "$(rest)"
assert_lacks "next: a theorem spawned and not entered is never outstanding" "disprove${TAB}T1${TAB}outstanding" "$(rest)"
assert_contains "next: a replacement spawned after a stopped is spawned" "disprove${TAB}T2${TAB}spawned${TAB}-${TAB}" "$(rest)"
assert_contains "next: a spawn past --deadline-minutes with no enter is overdue" \
  "disprove${TAB}T3${TAB}overdue${TAB}-${TAB}2000-01-01T00:00:00Z" "$(rest)"
as_child A --mode enter --round 1 --theorem T1 --stage disprove
run --mode next --round 1 --deadline-minutes 15
assert_contains "next: the spawned child's enter puts it in flight" "disprove${TAB}T1${TAB}in-flight${TAB}A${TAB}" "$(rest)"

new_case next-written-off-before-enter
add_seed T1 "first" "#1"
seed
a_generated_list
printf 'spawn T1 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
must --mode stopped --round 1 --theorem T1 --stage disprove --agent-id -
run --mode next --round 1 --deadline-minutes 15
assert_eq "next: a child written off before its enter is outstanding" \
  "disprove${TAB}T1${TAB}outstanding${TAB}${TAB}" "$(rest)"
must --mode spawn --round 1 --theorem T1 --stage disprove --agent theorem-disprover --model default --effort default
run --mode next --round 1 --deadline-minutes 15
assert_contains "next: a spawn after the write-off is spawned" "disprove${TAB}T1${TAB}spawned${TAB}-${TAB}" "$(rest)"
assert_lacks "next: a spawn after the write-off is not outstanding" "disprove${TAB}T1${TAB}outstanding" "$(rest)"

new_case next-replacement-entered-and-stopped
add_seed T1 "first" "#1"
seed
a_generated_list
printf 'spawn T1 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
must --mode stopped --round 1 --theorem T1 --stage disprove --agent-id -
printf 'spawn T1 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
as_child B --mode enter --round 1 --theorem T1 --stage disprove
must --mode stopped --round 1 --theorem T1 --stage disprove --agent-id B
run --mode next --round 1 --deadline-minutes 15
assert_eq "next: a replacement that entered and was stopped leaves the theorem outstanding" \
  "disprove${TAB}T1${TAB}outstanding${TAB}${TAB}" "$(rest)"

# T5 to T9 are named by no records file, as a theorem first recorded this
# round is to a call without --from.
new_case next-off-the-records
add_seed T1 "first" "#1"
seed
a_generated_list
survived T1
leave A T1 disprove theorem-disprover
must --mode spawn --round 1 --theorem T9 --stage disprove --agent theorem-disprover --model default --effort default
as_child B --mode enter --round 1 --theorem T8 --stage disprove
printf 'spawn T7 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
must --mode spawn --round 1 --theorem T6 --stage verify --agent counterexample-verifier --model default --effort default
as_child C --mode enter --round 1 --theorem T5 --stage verify
run --mode next --round 1 --deadline-minutes 15
assert_eq "next: a child off the records keeps its stage's arm" "disprove" "$(first_line)"
assert_contains "next: a disprover spawned for a theorem off the records is spawned" \
  "disprove${TAB}T9${TAB}spawned${TAB}-${TAB}" "$(rest)"
assert_contains "next: a disprover entered for a theorem off the records is in flight" \
  "disprove${TAB}T8${TAB}in-flight${TAB}B${TAB}" "$(rest)"
assert_contains "next: a disprover spawned off the records past its deadline is overdue" \
  "disprove${TAB}T7${TAB}overdue${TAB}-${TAB}2000-01-01T00:00:00Z" "$(rest)"
assert_contains "next: a verifier spawned off the records past the arm is spawned" \
  "verify${TAB}T6${TAB}spawned${TAB}-${TAB}" "$(rest)"
assert_contains "next: a verifier entered off the records past the arm is in flight" \
  "verify${TAB}T5${TAB}in-flight${TAB}C${TAB}" "$(rest)"
run --mode next --round 1
assert_contains "next: without --deadline-minutes a spawn off the records is spawned" \
  "disprove${TAB}T7${TAB}spawned${TAB}-${TAB}" "$(rest)"
must --mode stopped --round 1 --theorem T7 --stage disprove --agent-id -
run --mode next --round 1 --deadline-minutes 15
assert_lacks "next: a spawn off the records written off before its enter is not printed" "disprove${TAB}T7" "$(rest)"

new_case next-off-the-records-past-the-arm
add_seed T1 "first" "#1"
seed
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
report "$CASE/r" "no new theorems" "COUNT: mechanical 0, semantic 0"
leave G list generate theorem-generator
must --mode spawn --round 1 --theorem T9 --stage disprove --agent theorem-disprover --model default --effort default
as_child B --mode enter --round 1 --theorem T8 --stage disprove
run --mode next --round 1 --deadline-minutes 15
assert_eq "next: a child off the records past the arm leaves the arm where it is" "assess" "$(first_line)"
assert_contains "next: a disprover spawned off the records past the arm is spawned" \
  "disprove${TAB}T9${TAB}spawned${TAB}-${TAB}" "$(rest)"
assert_contains "next: a disprover entered off the records past the arm is in flight" \
  "disprove${TAB}T8${TAB}in-flight${TAB}B${TAB}" "$(rest)"

new_case next-assess-past-the-arm
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
must --mode spawn --round 1 --theorem list --stage assess --agent theorem-assessor --model default --effort default
run --mode next --round 1 --deadline-minutes 15
assert_eq "next: an assessor spawned before the list settles leaves the generate arm" "generate" "$(first_line)"
assert_contains "next: an assessor spawned past the arm is spawned" "assess${TAB}list${TAB}spawned${TAB}-${TAB}" "$(rest)"
as_child S --mode enter --round 1 --theorem list --stage assess
run --mode next --round 1 --deadline-minutes 15
assert_contains "next: an assessor entered past the arm is in flight" "assess${TAB}list${TAB}in-flight${TAB}S${TAB}" "$(rest)"

# --- wait: a leave, a deadline, and no child to wait on ------------------

new_case wait-no-child
run --mode wait --round 1 --stage disprove --deadline-minutes 15
assert_eq "wait: no round log exits 0" "0" "$RC"
assert_eq "wait: no round log is no child to wait on" "none" "$OUT"
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
as_child A --mode enter --round 1 --theorem T1 --stage generate
run --mode wait --round 1 --stage disprove --deadline-minutes 15
assert_eq "wait: no child in flight in the stage exits 0 at once" "0" "$RC"
assert_eq "wait: a child in flight in another stage is not waited on" "none" "$OUT"
run --mode wait --round 1 --stage disprove
assert_eq "wait: without --deadline-minutes it is refused" "2" "$RC"
assert_contains "wait: the refusal names --deadline-minutes" "--deadline-minutes" "$ERR"

new_case wait-deadline
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
as_child A --mode enter --round 1 --theorem T2 --stage disprove
printf 'enter T1 disprove 2000-01-01T00:00:00Z D -\n' >>"$PR_DIR/round1/log"
run --mode wait --round 1 --stage disprove --deadline-minutes 15
assert_eq "wait: the earliest child's deadline passing exits 0" "0" "$RC"
assert_eq "wait: the deadline line names the earliest child" "deadline${TAB}T1${TAB}D" "$OUT"

new_case wait-spawned
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
printf 'spawn T1 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
run --mode wait --round 1 --stage disprove --deadline-minutes 15
assert_eq "wait: a child spawned and not yet entered is waited on to its deadline" \
  "deadline${TAB}T1${TAB}-" "$OUT"

new_case wait-written-off-before-enter
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
printf 'spawn T1 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
must --mode stopped --round 1 --theorem T1 --stage disprove --agent-id -
run --mode wait --round 1 --stage disprove --deadline-minutes 15
assert_eq "wait: a child written off before its enter is not waited on" "none" "$OUT"
printf 'spawn T1 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
run --mode wait --round 1 --stage disprove --deadline-minutes 15
assert_eq "wait: a spawn after the write-off is waited on to its deadline" \
  "deadline${TAB}T1${TAB}-" "$OUT"

new_case wait-replacement-entered-and-stopped
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
printf 'spawn T1 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
must --mode stopped --round 1 --theorem T1 --stage disprove --agent-id -
printf 'spawn T1 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
as_child B --mode enter --round 1 --theorem T1 --stage disprove
must --mode stopped --round 1 --theorem T1 --stage disprove --agent-id B
run --mode wait --round 1 --stage disprove --deadline-minutes 15
assert_eq "wait: a replacement that entered and was stopped is not waited on" "none" "$OUT"

new_case wait-stopped-names-earlier-child
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
printf 'spawn T1 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
as_child A --mode enter --round 1 --theorem T1 --stage disprove
printf 'spawn T1 disprove 2000-01-01T00:00:00Z theorem-disprover default default\n' >>"$PR_DIR/round1/log"
must --mode stopped --round 1 --theorem T1 --stage disprove --agent-id A
run --mode wait --round 1 --stage disprove --deadline-minutes 15
assert_eq "wait: a stopped naming an entered child leaves its replacement waited on" \
  "deadline${TAB}T1${TAB}-" "$OUT"

new_case wait-leave
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
as_child A --mode enter --round 1 --theorem T1 --stage disprove
as_child B --mode enter --round 1 --theorem T2 --stage disprove
"$PERSIST" --pr "$PR" --mode wait --round 1 --stage disprove --deadline-minutes 15 \
  >"$CASE/wait-out" 2>"$CASE/wait-err" </dev/null &
WAIT_PID=$!
# Let it read the log's length before the leave lands.
sleep 1
if kill -0 "$WAIT_PID" 2>/dev/null; then
  pass "wait: two children in flight keep it waiting"
else
  fail "wait: two children in flight keep it waiting" "it exited before any leave"
fi
survived T1
as_child A --mode leave --round 1 --theorem T1 --stage disprove --agent theorem-disprover --from "$CASE/r"
for _ in $(seq 1 40); do
  kill -0 "$WAIT_PID" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$WAIT_PID" 2>/dev/null; then
  kill "$WAIT_PID"
  fail "wait: a leave ends the wait" "still running 10 seconds after the leave"
fi
wait "$WAIT_PID"
assert_eq "wait: a leave for a child in flight exits 0" "0" "$?"
assert_eq "wait: the leave line names the child that left" "leave${TAB}T1${TAB}A" "$(cat "$CASE/wait-out")"

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
# A theorem the assessor rejected this round is a new record retired as
# assessor-rejected: off a default round's live list, on a --full one's.
{
  record T4 "a new one" "#1"
  printf '\n'
  record T5 "rejected by the assessor" "#1"
  printf 'state: retired\nstate-detail: assessor-rejected\nsettled-at: aaa\n'
} >"$CASE/new-rejected"
run --mode next --round 1 --from "$CASE/new-rejected"
assert_eq "next: a theorem the assessor rejected this round is not live" \
  "disprove${TAB}T1${TAB}outstanding${TAB}${TAB}
disprove${TAB}T4${TAB}outstanding${TAB}${TAB}" "$(rest)"
run --mode next --round 1 --full --from "$CASE/new-rejected"
assert_contains "next: --full puts a theorem the assessor rejected this round back on the live list" \
  "disprove${TAB}T5${TAB}outstanding${TAB}${TAB}" "$(rest)"
survived T1
leave D1 T1 disprove theorem-disprover
survived T3
leave D3 T3 disprove theorem-disprover
survived T4
leave D4 T4 disprove theorem-disprover
survived T5
leave D5 T5 disprove theorem-disprover
run --mode dispose --round 1 --full --from "$CASE/new-rejected" --issues 1
assert_contains "dispose: --full disproves an assessor-rejected theorem and stamps its row" \
  "T5${TAB}verified-survived${TAB}-${TAB}-${TAB}retired${TAB}survived" "$OUT"
run --mode dispose --round 1 --from "$CASE/new-rejected" --issues 1
assert_lacks "dispose: a default round gives an assessor-rejected theorem no row" "T5${TAB}" "$OUT"
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
add_seed T11 "out of the disprover's reach" "#4"
add_seed T12 "unsettled with no reason" "#4"
add_seed T13 "unsettled with nothing checked" "#4"
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
unsettled T11 "REASON: it needs a live run" "CHECKED: read a.md"
leave D11 T11 disprove theorem-disprover
unsettled T12 "CHECKED: read a.md"
leave D12 T12 disprove theorem-disprover
unsettled T13 "REASON: it needs a live run" "CHECKED:"
leave D13 T13 disprove theorem-disprover
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
T11${TAB}unsettled-disprover-unsettled${TAB}-${TAB}-${TAB}unsettled${TAB}-
T12${TAB}unsettled-disprover-malformed${TAB}-${TAB}-${TAB}unsettled${TAB}-
T13${TAB}unsettled-disprover-malformed${TAB}-${TAB}-${TAB}unsettled${TAB}-
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

new_case dispose-subject-removed
add_seed T1 "old_fn returns zero" "#1"
add_seed T2 "the removal is reasonless" "#2"
add_seed T3 "the removal is unchecked" "#2"
seed
a_generated_list
record T4 "new_fn returns one" "#3" >"$CASE/new"
subject_removed T1 "REASON: the claim is about \`old_fn\`" "CHECKED: grep -rn old_fn at HEAD found nothing"
leave D1 T1 disprove theorem-disprover
subject_removed T2 "CHECKED: grep -rn old_fn at HEAD found nothing"
leave D2 T2 disprove theorem-disprover
subject_removed T3 "REASON: the claim is about \`old_fn\`" "CHECKED:"
leave D3 T3 disprove theorem-disprover
subject_removed T4 "REASON: the claim is about \`new_fn\`" "CHECKED: grep -rn new_fn at HEAD found nothing"
leave D4 T4 disprove theorem-disprover
run --mode dispose --round 1 --from "$CASE/new" --issues "1 2 3"
assert_eq "dispose: a carried SUBJECT REMOVED retires with no severity and blocks nothing, one missing REASON or CHECKED is malformed, and a minted one is unsettled" \
  "T1${TAB}retired-subject-removed${TAB}-${TAB}-${TAB}retired${TAB}subject removed
T2${TAB}unsettled-disprover-malformed${TAB}-${TAB}-${TAB}unsettled${TAB}-
T3${TAB}unsettled-disprover-malformed${TAB}-${TAB}-${TAB}unsettled${TAB}-
T4${TAB}unsettled-subject-removed-minted${TAB}-${TAB}-${TAB}unsettled${TAB}-
verdict${TAB}1${TAB}APPROVED
verdict${TAB}2${TAB}BLOCKED
verdict${TAB}3${TAB}BLOCKED
verdict${TAB}overall${TAB}BLOCKED" "$OUT"

new_case dispose-subject-removed-approves
add_seed T1 "old_fn returns zero" "#1"
add_seed T2 "survives" "#1"
seed
a_generated_list
subject_removed T1 "REASON: the claim is about \`old_fn\`" "CHECKED: grep -rn old_fn at HEAD found nothing"
leave D1 T1 disprove theorem-disprover
survived T2
leave D2 T2 disprove theorem-disprover
run --mode dispose --round 1 --issues 1
assert_eq "dispose: a round whose only theorem not surviving had its subject removed approves" \
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
<!-- sdlc:review-round 1 -->

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
assert_eq "summary: the stamp names the round it renders" "<!-- sdlc:review-round 2 -->" "${OUT%%$'\n'*}"

# same <name> <expected file> <actual file>: the two hold the same bytes.
same() {
  if cmp -s "$2" "$3"; then
    pass "$1"
  else
    fail "$1" "expected the bytes of $2" "actual: [$(cat "$3")]"
  fi
}

# refused_out <what> <needle>: the last run was refused, naming <needle>,
# printed nothing, and left the sentinel file at $CASE/out/kept and
# nothing else in $CASE/out.
refused_out() {
  assert_eq "summary --out: $1 exits 2 with no stdout" "2:" "$RC:$OUT"
  assert_contains "summary --out: $1 says why" "$2" "$ERR"
  assert_eq "summary --out: $1 leaves the file at the path unchanged" "sentinel" "$(cat "$CASE/out/kept")"
  assert_eq "summary --out: $1 leaves nothing else behind" "kept" "$(ls -A "$CASE/out")"
}

"$PERSIST" --pr "$PR" --mode summary --round 2 >"$CASE/printed" </dev/null ||
  fail "setup call failed: summary to a file"
mkdir -p "$CASE/out"
run --mode summary --round 2 --out "$CASE/out/new"
assert_eq "summary --out: exits 0 and prints nothing" "0:" "$RC:$OUT"
same "summary --out: writes the bytes the mode prints without it" "$CASE/printed" "$CASE/out/new"
assert_eq "summary --out: leaves no staging file" "new" "$(ls -A "$CASE/out")"
rm "$CASE/out/new"
printf 'sentinel\n' >"$CASE/out/kept"
run --mode summary --round 2 --out "$CASE/out/kept"
assert_eq "summary --out: an existing file exits 0 and prints nothing" "0:" "$RC:$OUT"
same "summary --out: replaces an existing file" "$CASE/printed" "$CASE/out/kept"
printf 'sentinel\n' >"$CASE/out/kept"

run --mode summary --round 2 --out "$CASE/out/absent/summary"
refused_out "a missing parent directory" "$CASE/out/absent/summary"
run --mode summary --round 2 --out "$CASE/out"
refused_out "a directory" "$CASE/out"
run --mode summary --round 2 --out ""
refused_out "an empty value" "--out"
for mode in anchor spawn enter leave return stopped print print-in-flight wait records review \
  print-records print-round-records print-review print-root agent print-agents rounds progress \
  delete next dispose seed-review; do
  run --mode "$mode" --out "$CASE/out/kept"
  refused_out "--mode $mode" "--out is not accepted in --mode $mode"
done
OUT=$("$PERSIST" --mode list o/r --out "$CASE/out/kept" 2>"$CASE/err" </dev/null)
RC=$?
ERR=$(cat "$CASE/err")
refused_out "--mode list" "--out is not accepted in --mode list"
OUT=$("$PERSIST" --mode repos --out "$CASE/out/kept" 2>"$CASE/err" </dev/null)
RC=$?
ERR=$(cat "$CASE/err")
refused_out "--mode repos" "--out is not accepted in --mode repos"

# An awk that prints part of the body and then fails, and a cp that fails,
# each ahead of the real one on PATH for one call.
mkdir -p "$CASE/bin-awk" "$CASE/bin-cp"
cat >"$CASE/bin-awk/awk" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *'Closing-line corrections'*)
    echo partial
    echo 'awk broke' >&2
    exit 1
    ;;
esac
exec "$(command -v awk)" "\$@"
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$CASE/bin-cp/cp"
chmod +x "$CASE/bin-awk/awk" "$CASE/bin-cp/cp"
PATH="$CASE/bin-awk:$PATH" run --mode summary --round 2 --out "$CASE/out/kept"
refused_out "a failed render" "awk broke"
PATH="$CASE/bin-cp:$PATH" run --mode summary --round 2 --out "$CASE/out/kept"
refused_out "a failed staging" "could not stage $CASE/out/kept"

sed '/^## Overall verdict/,/^Fix/d' "$CASE/review" >"$CASE/short-review"
must --mode review --round 2 --from "$CASE/short-review"
run --mode summary --round 2
assert_eq "summary: a review missing a copied section is refused" "2" "$RC"
assert_contains "summary: the refusal names the section" '"## Overall verdict"' "$ERR"
run --mode summary --round 2 --out "$CASE/out/kept"
refused_out "a refused render" '"## Overall verdict"'

# --- rounds ----------------------------------------------------------------

new_case rounds-none
run --mode rounds
assert_eq "rounds: a PR with no state prints nothing and exits 0" "0:" "$RC:$OUT"
assert_eq "rounds: creates nothing" "absent" "$([ -e "$PR_DIR" ] && echo made || echo absent)"

new_case rounds
for n in 0 2 3 5 10; do
  mkdir -p "$PR_DIR/round$n"
  printf 'anchor 2026-01-01T00:00:00Z abc code-and-instruction-markdown\n' >"$PR_DIR/round$n/log"
done
mkdir -p "$PR_DIR/round4" "$PR_DIR/round6.voided-20260101T000000Z"
printf 'T1\n' >"$PR_DIR/round4/records"
printf 'anchor 2026-01-01T00:00:00Z abc code-and-instruction-markdown\n' >"$PR_DIR/round6.voided-20260101T000000Z/log"
run --mode rounds
assert_eq "rounds: every round from 1 with a log, ascending, round 0 and voided rounds left out" "0:2
3
5
10" "$RC:$OUT"
run --mode rounds --round 2
assert_eq "rounds: --round is refused" "2" "$RC"

# --- progress --------------------------------------------------------------

new_case progress-none
run --mode progress
assert_eq "progress: a PR with no round log prints nothing and exits 0" "0:" "$RC:$OUT"
assert_eq "progress: creates nothing" "absent" "$([ -e "$PR_DIR" ] && echo made || echo absent)"

# Round 1 is mid-disprove: T1's child left, T2's wrote its result file and
# no leave, and T3's was spawned and has not entered. A higher round that
# was voided is not the round under way.
new_case progress-disprove
add_seed T1 "a claim" "#1"
add_seed T2 "a claim" "#1"
add_seed T3 "a claim" "#1"
seed
a_generated_list
for t in T1 T2 T3; do
  must --mode spawn --round 1 --theorem "$t" --stage disprove --agent theorem-disprover --model default --effort default
done
survived T1
leave D1 T1 disprove theorem-disprover
as_child D2 --mode enter --round 1 --theorem T2 --stage disprove
survived T2
cp "$CASE/r" "$PR_DIR/round1/T2-theorem-disprover"
mkdir -p "$PR_DIR/round3.voided-20260101T000000Z"
printf 'anchor 2026-01-01T00:00:00Z abc documentation\n' >"$PR_DIR/round3.voided-20260101T000000Z/log"
before=$(cat "$PR_DIR/round1/log")
run --mode progress
assert_eq "progress: a round mid-disprove counts the stage's settled theorems" \
  "0:1${TAB}code-and-instruction-markdown${TAB}disprove${TAB}2${TAB}3" "$RC:$OUT"
assert_eq "progress: writes nothing to the log" "$before" "$(cat "$PR_DIR/round1/log")"

new_case progress-reviewed
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
must --mode anchor --round 2 --head-sha bbb --round-type documentation
as_child G --mode enter --round 2 --theorem list --stage generate
printf '## Verdicts\n\nnone\n' >"$CASE/review"
must --mode review --round 2 --from "$CASE/review"
run --mode progress
assert_eq "progress: a round holding a review file is reviewed" \
  "0:2${TAB}documentation${TAB}reviewed${TAB}-${TAB}-" "$RC:$OUT"

new_case progress-no-child
must --mode anchor --round 1 --head-sha aaa --round-type code-and-instruction-markdown
run --mode progress
assert_eq "progress: a log with no child record has no stage" \
  "0:1${TAB}code-and-instruction-markdown${TAB}-${TAB}-${TAB}-" "$RC:$OUT"

new_case progress-no-anchor
as_child G --mode enter --round 1 --theorem list --stage generate
run --mode progress
assert_eq "progress: a log with no anchor has no round type" \
  "0:1${TAB}-${TAB}generate${TAB}0${TAB}1" "$RC:$OUT"

: >"$CASE/empty"
run --mode progress --round 1
assert_eq "progress: --round is refused with no line printed" "2:" "$RC:$OUT"
run --mode progress --from "$CASE/empty"
assert_eq "progress: --from is refused with no line printed" "2:" "$RC:$OUT"
run --mode progress --edits "$CASE/empty"
assert_eq "progress: --edits is refused with no line printed" "2:" "$RC:$OUT"
run --mode progress --carry --edits "$CASE/empty"
assert_eq "progress: --edits with --carry is refused with no line printed" "2:" "$RC:$OUT"

# --- enter: the transcript path under the config directory -------------------

# enter_transcript <agent-id>: a child's enter from a worktree of the
# case's repository, leaving in OUT the transcript path its record names.
enter_transcript() {
  as_child "$1" --mode enter --round 1 --theorem list --stage generate
  OUT=$(sed -n '$p' "$PR_DIR/round1/log" | cut -d' ' -f6-)
}

new_case enter-transcript
git init -q "$CASE"
export CLAUDE_CODE_SESSION_ID=sess
export CLAUDE_CONFIG_DIR="$CASE/config"
enter_transcript C1
assert_contains "enter: a set CLAUDE_CONFIG_DIR holds the transcript" "$CASE/config/projects/" "$OUT"
assert_contains "enter: the transcript is the child's under the session" "/sess/subagents/agent-C1.jsonl" "$OUT"
CLAUDE_CONFIG_DIR=
enter_transcript C2
assert_contains "enter: an empty CLAUDE_CONFIG_DIR falls back to HOME" "$HOME/.claude/projects/" "$OUT"
unset CLAUDE_CONFIG_DIR
enter_transcript C3
assert_contains "enter: an unset CLAUDE_CONFIG_DIR falls back to HOME" "$HOME/.claude/projects/" "$OUT"
unset CLAUDE_CODE_SESSION_ID

echo "$PASSED passed"
