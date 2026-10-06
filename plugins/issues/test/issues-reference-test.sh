#!/usr/bin/env bash
#
# issues-reference-test.sh -- parse issue references with iss_parse_operand
# from bin/lib/issues-common.sh, under the bash 3.2 macOS ships, and check the
# host, owner, repo and number each resolves to, or the usage error it is
# refused with. The current repository is github.com/acme/widgets, held as
# already resolved, so no case calls gh.
#
# The accepted forms include every form the github-prs PR-reference parser
# accepts -- N, #N, repo#N, owner/repo#N, host/owner/repo#N and a URL -- with
# the URL's pull segment read as issues.
#
# Usage: issues-reference-test.sh    (exit 0 when every case passes)

set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin/lib" && pwd)/issues-common.sh"
FAILURES=0

# parse <link-prefix> <owner> <operand>: run iss_parse_operand under /bin/bash
# with the current repository acme/widgets on github.com -- or no current
# repository when <owner> is empty -- and the given issue-link-prefix. Sets RC
# and OUT, which is "host owner repo number local" on success and the error
# otherwise.
parse() {
  OUT=$(/bin/bash -c '
    . "$1"
    gh() { echo "unexpected gh call" >&2; exit 99; }
    ISS_LINK_PREFIX=$2
    ISS_CURRENT_TRIED=yes
    if [ -n "$3" ]; then ISS_HOST=github.com; ISS_OWNER=$3; ISS_REPO=widgets; fi
    iss_parse_operand "$4"
    printf "%s %s %s %s %s" "$OP_HOST" "$OP_OWNER" "$OP_REPO" "$OP_NUMBER" "$OP_LOCAL"
  ' _ "$LIB" "$1" "$2" "$3" 2>&1)
  RC=$?
}

# accepts <operand> <expected "host owner repo number local"> [<link-prefix>]
accepts() {
  parse "${3:-#}" acme "$1"
  if [ "$RC" = 0 ] && [ "$OUT" = "$2" ]; then
    echo "PASS  accepts $1"
  else
    echo "FAIL  accepts $1"
    echo "      expected: 0 $2"
    echo "      actual:   $RC $OUT"
    FAILURES=$((FAILURES + 1))
  fi
}

# refuses <operand> <substring> [<owner>]: a usage error, exit 2, naming it.
refuses() {
  parse '#' "${3-acme}" "$1"
  case "$RC $OUT" in
    "2 "*"$2"*) echo "PASS  refuses $1" ;;
    *)
      echo "FAIL  refuses $1"
      echo "      expected: 2 ...$2..."
      echo "      actual:   $RC $OUT"
      FAILURES=$((FAILURES + 1))
      ;;
  esac
}

# The forms.
accepts 7 "github.com acme widgets 7 yes"
accepts '#7' "github.com acme widgets 7 yes"
accepts GH-7 "github.com acme widgets 7 yes" GH-
accepts other#7 "github.com acme other 7 no"
accepts octo/lib#7 "github.com octo lib 7 no"
accepts ghe.example.com/corp/tools#7 "ghe.example.com corp tools 7 no"
accepts https://ghe.example.com/corp/tools/issues/7 "ghe.example.com corp tools 7 no"
accepts https://ghe.example.com/corp/tools/issues/7/ "ghe.example.com corp tools 7 no"
accepts https://ghe.example.com/corp/tools#7 "ghe.example.com corp tools 7 no"
accepts ghe.example.com/corp/tools/#7 "ghe.example.com corp tools 7 no"
accepts My-Org/my_repo.js#7 "github.com My-Org my_repo.js 7 no"

# Each form iss_ref prints parses back to the issue it names.
for ref in '#7' other#7 octo/lib#7 ghe.example.com/corp/tools#7; do
  parse '#' acme "$ref"
  read -r host owner repo number _ <<EOF
$OUT
EOF
  back=$(/bin/bash -c '
    . "$1"; ISS_HOST=github.com; ISS_OWNER=acme; ISS_REPO=widgets; iss_ref "$2" "$3" "$4" "$5"' \
    _ "$LIB" "$host" "$owner" "$repo" "$number")
  if [ "$RC" = 0 ] && [ "$back" = "$ref" ]; then
    echo "PASS  round trip $ref"
  else
    echo "FAIL  round trip $ref"
    echo "      parsed: $RC $OUT; printed back: $back"
    FAILURES=$((FAILURES + 1))
  fi
done

# A pull request's URL.
refuses https://github.com/octo/lib/pull/7 "is a pull request; the issue verbs take issues only"
refuses https://github.com/octo/lib/pull/7/ "is a pull request"

# Malformed operands.
not_ref="is not an issue reference"
refuses '' "$not_ref"
refuses x "$not_ref"
refuses 7x "$not_ref"
refuses -7 "$not_ref"
refuses '#' "$not_ref"
refuses '#x' "$not_ref"
refuses GH-7 "$not_ref"
refuses other# "$not_ref"
refuses other#x "$not_ref"
refuses other#-7 "$not_ref"
refuses https://github.com/octo/lib/issues/x "$not_ref"
refuses https://github.com/octo/lib/commits/7 "$not_ref"
refuses https://github.com/octo/issues/7 "$not_ref"
refuses https://github.com/a/b/c/issues/7 "$not_ref"
refuses http://github.com/octo/lib/issues/7 "$not_ref"
refuses https://github.com//lib/issues/7 "$not_ref"
not_repo="is not a repository"
refuses a//b#7 "$not_repo"
refuses /a/b#7 "$not_repo"
refuses a/b/c/d#7 "$not_repo"
refuses 'a b#7' "$not_repo"
refuses 'a#b#7' "$not_repo"
refuses https://github.com/a/b/c#7 "$not_repo"
refuses other#7 "names a repository under the current repository's owner, and there is no current repository" ''

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all cases passed"
  exit 0
fi
echo "$FAILURES failure(s)"
exit 1
