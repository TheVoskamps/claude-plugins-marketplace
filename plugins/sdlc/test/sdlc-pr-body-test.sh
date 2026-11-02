#!/usr/bin/env bash
#
# sdlc-pr-body-test.sh -- drive plugins/sdlc/bin/sdlc-pr-body against
# bodies of its own: split on a body with no section, with a section and
# a tail, with an opening marker and no closing one, and with CRLF line
# endings; the base's trailing blank lines dropped and its inner ones
# kept; a stale tail file emptied; join's concatenation; a split and
# join re-run reproducing the body byte for byte; the usage errors; and
# a missing input.
#
# Needs bash and the POSIX utilities. Reaches no network.
#
# Usage: sdlc-pr-body-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BODY="$TEST_DIR/../bin/sdlc-pr-body"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-pr-body-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0
OPEN='<!-- sdlc:pr-finalizer-report -->'
CLOSE='<!-- /sdlc:pr-finalizer-report -->'

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

# check_file <path> <expected-bytes> <label>: passes when the file holds
# exactly the expected bytes, and otherwise prints both, escaped, and
# counts a failure in FAILURES.
check_file() {
  printf '%s' "$2" >"$SANDBOX/expected"
  if cmp -s "$1" "$SANDBOX/expected"; then
    echo "PASS  $3"
  else
    echo "FAIL  $3"
    echo "      expected: $(od -c "$SANDBOX/expected" | sed -n '1,4p')"
    echo "      actual:   $(od -c "$1" | sed -n '1,4p')"
    FAILURES=$((FAILURES + 1))
  fi
}

# new_case <name>: point CASE at a fresh directory for one case.
new_case() {
  CASE="$SANDBOX/$1"
  mkdir -p "$CASE"
}

# split_body <body-bytes>: write the body into CASE and split it into
# CASE/base.md and CASE/tail.md, setting RC to the script's exit status.
split_body() {
  printf '%s' "$1" >"$CASE/body.md"
  "$BODY" split "$CASE/body.md" "$CASE/base.md" "$CASE/tail.md" 2>"$CASE/err"
  RC=$?
}

new_case no-section
split_body $'Intro.\n\nCloses #1\n\n\n'
check "$RC" 0 "no section: exits 0"
check_file "$CASE/base.md" $'Intro.\n\nCloses #1\n' "no section: base is the body less its trailing blank lines"
check_file "$CASE/tail.md" '' "no section: tail is empty"

new_case section-and-tail
split_body "Intro."$'\n\n'"$OPEN"$'\n## Old\nold text\n'"$CLOSE"$'\nCloses #2\n'
check "$RC" 0 "section and tail: exits 0"
check_file "$CASE/base.md" $'Intro.\n' "section and tail: base stops above the opening marker"
check_file "$CASE/tail.md" $'Closes #2\n' "section and tail: tail is what follows the closing marker"

new_case no-closing
split_body "Intro."$'\n\n'"$OPEN"$'\n## Old\nCloses #3\n'
check_file "$CASE/base.md" $'Intro.\n' "opening marker alone: base stops above it"
check_file "$CASE/tail.md" '' "opening marker alone: tail is empty"

new_case crlf
split_body $'Intro.\r\n\r\n'"$OPEN"$'\r\nold\r\n'"$CLOSE"$'\r\nCloses #4\r\n'
check_file "$CASE/base.md" $'Intro.\r\n' "CRLF: markers match and the trailing blank line is dropped"
check_file "$CASE/tail.md" $'Closes #4\r\n' "CRLF: tail keeps its own bytes"

new_case inner-blanks
split_body $'a\n\n\r\nb\n\n'
check_file "$CASE/base.md" $'a\n\n\r\nb\n' "inner blank lines keep their bytes"

new_case stale-tail
printf 'stale\n' >"$CASE/tail.md"
split_body $'Intro.\n'
check_file "$CASE/tail.md" '' "a tail file left from before is emptied"

new_case no-final-newline
split_body "Intro."$'\n'"$OPEN"$'\nold\n'"$CLOSE"$'\nCloses #5'
check_file "$CASE/tail.md" $'Closes #5\n' "a last line with no newline gets one"

new_case join
printf 'base\n' >"$CASE/base.md"
printf '\nsection\n' >"$CASE/section.md"
printf 'tail\n' >"$CASE/tail.md"
"$BODY" join "$CASE/base.md" "$CASE/section.md" "$CASE/tail.md" "$CASE/out.md" 2>"$CASE/err"
check "$?" 0 "join: exits 0"
check_file "$CASE/out.md" $'base\n\nsection\ntail\n' "join: base, section and tail in that order"

new_case rerun
section=$'\n'"$OPEN"$'\n## Review\nnew\n'"$CLOSE"$'\n'
printf '%s' "$section" >"$CASE/section.md"
split_body $'Intro.\n\nCloses #6\n'
"$BODY" join "$CASE/base.md" "$CASE/section.md" "$CASE/tail.md" "$CASE/first.md"
printf 'Closes #7\n' >>"$CASE/first.md"
"$BODY" split "$CASE/first.md" "$CASE/base2.md" "$CASE/tail2.md"
"$BODY" join "$CASE/base2.md" "$CASE/section.md" "$CASE/tail2.md" "$CASE/second.md"
check "$(cmp "$CASE/first.md" "$CASE/second.md" && echo same)" "same" \
  "re-run: the body is reproduced byte for byte, a line appended below the section kept"

new_case usage
"$BODY" >/dev/null 2>"$CASE/err"
check "$?" 2 "no subcommand: exits 2"
"$BODY" trim a b c >/dev/null 2>"$CASE/err"
check "$?" 2 "unknown subcommand: exits 2"
"$BODY" split "$CASE/body.md" "$CASE/base.md" >/dev/null 2>"$CASE/err"
check "$?" 2 "split with too few arguments: exits 2"
"$BODY" join a b c >/dev/null 2>"$CASE/err"
check "$?" 2 "join with too few arguments: exits 2"
check "$(ls "$CASE")" "err" "usage errors: nothing written"

new_case missing
"$BODY" split "$CASE/absent.md" "$CASE/base.md" "$CASE/tail.md" 2>"$CASE/err"
check "$?" 1 "split of a missing body: exits 1"
check "$(ls "$CASE")" "err" "split of a missing body: nothing written"
"$BODY" join "$CASE/absent.md" "$CASE/absent.md" "$CASE/absent.md" "$CASE/out.md" 2>"$CASE/err"
check "$?" 1 "join of a missing input: exits 1"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all cases passed"
  exit 0
fi
echo "$FAILURES case(s) failed"
exit 1
