#!/usr/bin/env bash
#
# sdlc-extract-lines-test.sh -- drive plugins/sdlc/bin/sdlc-extract-lines
# against a source file of its own: a range, a single line, the whole
# file, a destination replaced, a last line with no newline, a range
# past the end of the file refused with nothing written, the usage
# errors, and a missing source.
#
# Needs bash and the POSIX utilities. Reaches no network.
#
# Usage: sdlc-extract-lines-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT="$TEST_DIR/../bin/sdlc-extract-lines"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-extract-lines-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0

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

SRC="$SANDBOX/src.sh"
printf 'one\n  two * ?\n\tthree\n\nfive\n' >"$SRC"
OUT="$SANDBOX/out"
mkdir -p "$OUT"

"$EXTRACT" 2 4 "$SRC" "$OUT/range.inc" 2>"$OUT/err"
check "$?" 0 "range: exits 0"
check_file "$OUT/range.inc" $'  two * ?\n\tthree\n\n' "range: lines 2 to 4, whitespace and blank line kept"

"$EXTRACT" 3 3 "$SRC" "$OUT/single.inc" 2>"$OUT/err"
check_file "$OUT/single.inc" $'\tthree\n' "single line"

"$EXTRACT" 1 5 "$SRC" "$OUT/whole.inc" 2>"$OUT/err"
check "$(cmp "$SRC" "$OUT/whole.inc" && echo same)" "same" "whole file: a byte-for-byte copy"

printf 'stale\nstale\nstale\n' >"$OUT/replaced.inc"
"$EXTRACT" 1 1 "$SRC" "$OUT/replaced.inc" 2>"$OUT/err"
check_file "$OUT/replaced.inc" $'one\n' "an existing destination is replaced"

printf 'a\nb' >"$SANDBOX/nonl.sh"
"$EXTRACT" 2 2 "$SANDBOX/nonl.sh" "$OUT/nonl.inc" 2>"$OUT/err"
check "$?" 0 "a last line with no newline: exits 0"
check_file "$OUT/nonl.inc" 'b' "a last line with no newline is copied without one"

"$EXTRACT" 4 6 "$SRC" "$OUT/short.inc" 2>"$OUT/err"
check "$?" 3 "range past the end: exits 3"
check "$([ -e "$OUT/short.inc" ] || echo absent)" "absent" "range past the end: nothing written"

# usage_case <arg>...: run the script on the arguments and check it
# exits 2.
usage_case() {
  "$EXTRACT" "$@" >/dev/null 2>"$OUT/err"
  check "$?" 2 "usage error: exits 2 on \`${*//$SANDBOX\//}\`"
}
usage_case
usage_case 1 2 "$SRC"
usage_case 1 2 "$SRC" "$OUT/x" "$OUT/y"
usage_case x 2 "$SRC" "$OUT/u.inc"
usage_case 0 2 "$SRC" "$OUT/u.inc"
usage_case 3 2 "$SRC" "$OUT/u.inc"
usage_case -1 2 "$SRC" "$OUT/u.inc"
check "$([ -e "$OUT/u.inc" ] || echo absent)" "absent" "usage errors: nothing written"

"$EXTRACT" 1 2 "$SANDBOX/absent.sh" "$OUT/missing.inc" 2>"$OUT/err"
check "$?" 1 "missing source: exits 1"
check "$([ -e "$OUT/missing.inc" ] || echo absent)" "absent" "missing source: nothing written"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all cases passed"
  exit 0
fi
echo "$FAILURES case(s) failed"
exit 1
