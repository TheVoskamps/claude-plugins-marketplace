#!/usr/bin/env bash
#
# issues-reference-test.sh -- parse issue references with iss_parse_operand
# from bin/lib/issues-common.sh, under the bash 3.2 macOS ships, and check the
# host, owner, repo and number each resolves to, or the error it is refused
# with. The current repository is github.com/acme/widgets, held as
# already resolved, so no case calls gh.
#
# The accepted forms are those the github-prs PR-reference parser accepts --
# N, #N, repo#N, owner/repo#N, host/owner/repo#N and a URL -- except that the
# URL carries an issues segment; a pull segment is refused. So a reference
# copied between the two plugins' verbs parses to the same host, owner,
# repository and number. Each form a verb prints is round-tripped under each
# kind of issue-link-prefix -- `#`, empty, and a name -- because the prefix
# decides which printed form parses back to the issue it was printed for.
#
# Usage: issues-reference-test.sh    (exit 0 when every case passes)

set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin/lib" && pwd)/issues-common.sh"
FAILURES=0

# parse <link-prefix> <owner> <operand> [<host> <owner> <repo>]: run
# iss_parse_operand, with the repository if one is given, under /bin/bash
# with the current repository acme/widgets on github.com -- or no current
# repository when <owner> is empty -- and the given issue-link-prefix. Sets RC
# and OUT, which is "host owner repo number" on success and the error
# otherwise.
parse() {
  OUT=$(/bin/bash -c '
    . "$1"
    gh() { echo "unexpected gh call" >&2; exit 99; }
    ISS_LINK_PREFIX=$2
    ISS_CURRENT_TRIED=yes
    if [ -n "$3" ]; then ISS_HOST=github.com; ISS_OWNER=$3; ISS_REPO=widgets; fi
    shift 3
    iss_parse_operand "$@"
    printf "%s %s %s %s" "$OP_HOST" "$OP_OWNER" "$OP_REPO" "$OP_NUMBER"
  ' _ "$LIB" "$@" 2>&1)
  RC=$?
}

# accepts <operand> <expected "host owner repo number"> [<link-prefix>]: an
# exit 0 with <expected>, under <link-prefix> as the issue-link-prefix, or
# '#' when <link-prefix> is not given.
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

# rejects <status> <operand> <substring> [<owner>]: an exit with <status> and
# an error containing <substring>, with <owner> as parse takes it.
rejects() {
  parse '#' "${4-acme}" "$2"
  case "$RC $OUT" in
    "$1 "*"$3"*) echo "PASS  refuses $2" ;;
    *)
      echo "FAIL  refuses $2"
      echo "      expected: $1 ...$3..."
      echo "      actual:   $RC $OUT"
      FAILURES=$((FAILURES + 1))
      ;;
  esac
}

# refuses <operand> <substring> [<owner>]: rejects with the usage error's exit
# status, 2.
refuses() {
  rejects 2 "$@"
}

# The forms.
accepts 7 "github.com acme widgets 7"
accepts '#7' "github.com acme widgets 7"
accepts GH-7 "github.com acme widgets 7" GH-
accepts other#7 "github.com acme other 7"
accepts octo/lib#7 "github.com octo lib 7"
accepts ghe.example.com/corp/tools#7 "ghe.example.com corp tools 7"
accepts https://ghe.example.com/corp/tools/issues/7 "ghe.example.com corp tools 7"
accepts https://ghe.example.com/corp/tools/issues/7/ "ghe.example.com corp tools 7"
accepts https://ghe.example.com/corp/tools#7 "ghe.example.com corp tools 7"
accepts ghe.example.com/corp/tools/#7 "ghe.example.com corp tools 7"
accepts My-Org/my_repo.js#7 "github.com My-Org my_repo.js 7"
accepts -b#7 "github.com acme -b 7"
accepts octo/-b#7 "github.com octo -b 7"
accepts .b_#7 "github.com acme .b_ 7"
accepts a-b-c/lib#7 "github.com a-b-c lib 7"
accepts ooooooooooooooooooooooooooooooooooooooo/lib#7 "github.com ooooooooooooooooooooooooooooooooooooooo lib 7"
accepts octo/rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr#7 "github.com octo rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr 7"
accepts hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh.example.com/corp/tools#7 "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh.example.com corp tools 7"
accepts https://ghe-1.example.com/corp/-b/issues/7 "ghe-1.example.com corp -b 7"

# A given repository is the one N and #N name; a form naming its own
# repository ignores it.
for case in "7|ghe.example.com corp tools 7" "#7|ghe.example.com corp tools 7" \
  "octo/lib#7|github.com octo lib 7"; do
  op=${case%%|*}
  want=${case#*|}
  parse '#' acme "$op" ghe.example.com corp tools
  if [ "$RC" = 0 ] && [ "$OUT" = "$want" ]; then
    echo "PASS  accepts $op in ghe.example.com/corp/tools"
  else
    echo "FAIL  accepts $op in ghe.example.com/corp/tools"
    echo "      expected: 0 $want"
    echo "      actual:   $RC $OUT"
    FAILURES=$((FAILURES + 1))
  fi
done

# ref <link-prefix> <host> <owner> <repo> <number>: print iss_ref's reference
# for the issue, with the current repository acme/widgets on github.com and
# <link-prefix> as this checkout's issue-link-prefix.
ref() {
  /bin/bash -c '
    . "$1"; ISS_HOST=github.com; ISS_OWNER=acme; ISS_REPO=widgets; ISS_HERE_LINK_PREFIX=$2
    iss_ref "$3" "$4" "$5" "$6"' _ "$LIB" "$@"
}

# Each form iss_ref prints parses back to the issue it names.
for ref in '#7' other#7 octo/lib#7 ghe.example.com/corp/tools#7; do
  parse '#' acme "$ref"
  read -r host owner repo number <<EOF
$OUT
EOF
  back=$(ref '#' "$host" "$owner" "$repo" "$number")
  if [ "$RC" = 0 ] && [ "$back" = "$ref" ]; then
    echo "PASS  round trip $ref"
  else
    echo "FAIL  round trip $ref"
    echo "      parsed: $RC $OUT; printed back: $back"
    FAILURES=$((FAILURES + 1))
  fi
done

# Under every kind of issue-link-prefix, each reference iss_ref prints parses
# back, under that prefix, to the issue it was printed for -- a repository
# named as the prefix included.
for prefix in '#' '' GH- other Other widgets lib 7 -b; do
  for issue in "github.com acme widgets" "github.com acme other" "github.com acme Other" "github.com acme lib" \
    "github.com acme 7" "github.com acme -b" "github.com octo other" "ghe.example.com acme other"; do
    read -r host owner repo <<EOF
$issue
EOF
    printed=$(ref "$prefix" "$host" "$owner" "$repo" 7)
    parse "$prefix" acme "$printed"
    if [ "$RC" = 0 ] && [ "$OUT" = "$issue 7" ]; then
      echo "PASS  round trip $issue 7 as $printed under prefix '$prefix'"
    else
      echo "FAIL  round trip $issue 7 as $printed under prefix '$prefix'"
      echo "      parsed back: $RC $OUT"
      FAILURES=$((FAILURES + 1))
    fi
  done
done

# printed <link-prefix> <host> <owner> <repo> <expected>: iss_ref prints
# <expected> for issue 7 in the repository under <link-prefix>.
printed() {
  local got
  got=$(ref "$1" "$2" "$3" "$4" 7)
  if [ "$got" = "$5" ]; then
    echo "PASS  prints $5 under prefix '$1'"
  else
    echo "FAIL  prints $5 under prefix '$1'"
    echo "      actual: $got"
    FAILURES=$((FAILURES + 1))
  fi
}

# A repository spelled as the prefix takes its owner; any other spelling, and
# any other prefix, keeps the shortest form.
printed other github.com acme other acme/other#7
printed other github.com acme Other Other#7
printed Other github.com acme other other#7
printed other github.com acme widgets '#7'
printed other github.com octo other octo/other#7
printed '#' github.com acme other other#7
printed '' github.com acme other other#7

# A pull request's URL, refused with the exit status a pull request's number
# gets once the lookup finds it.
rejects 1 https://github.com/octo/lib/pull/7 "\`https://github.com/octo/lib/pull/7\` is a pull request; the issue verbs take issues only"
rejects 1 https://github.com/octo/lib/pull/7/ "is a pull request"

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
refuses https://github.com/-octo/lib/issues/7 "$not_ref"
refuses https://ghe-.example.com/octo/lib/issues/7 "$not_ref"
not_repo="is not a repository"
refuses a//b#7 "$not_repo"
refuses -a/b#7 "$not_repo"
refuses a--b/c#7 "$not_repo"
refuses a_b/c#7 "$not_repo"
refuses a.b/c#7 "$not_repo"
refuses oooooooooooooooooooooooooooooooooooooooo/lib#7 "$not_repo"
refuses octo/rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr#7 "$not_repo"
refuses 'octo/a+b#7' "$not_repo"
refuses -ghe.example.com/corp/tools#7 "$not_repo"
refuses ghe-.example.com/corp/tools#7 "$not_repo"
refuses ghe..example.com/corp/tools#7 "$not_repo"
refuses ghe.example.com./corp/tools#7 "$not_repo"
refuses ghe_1.example.com/corp/tools#7 "$not_repo"
refuses hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh.example.com/corp/tools#7 "$not_repo"
refuses https://-ghe.example.com/corp/tools#7 "$not_repo"
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
