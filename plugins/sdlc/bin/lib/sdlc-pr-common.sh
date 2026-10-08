# shellcheck shell=bash
#
# sdlc-pr-common.sh -- sourced by the sdlc scripts that read a PR's
# reviews and comments. It spells the two comment markers sdlc writes,
# parses the canonical PR reference those scripts take, makes the one
# `gh` read they share, and holds the failure exits, so a marker, a
# reference and an exit status mean the same thing in every one of them.
# Runs under the bash 3.2 macOS ships.
#
# Exit statuses, shared by the scripts that report through it:
#   0  the script did what it says
#   1  a command the script ran failed; the tool's own stderr is passed
#      through above the script's line
#   2  a usage error; nothing was read
#   3  the script's own negative outcome, which its contract names

SP_PROGRAM=${0##*/}

# The first line of a brief to issue-fixer.
SP_FIXER_BRIEF_MARKER='<!-- sdlc:fixer-brief -->'
# The first line of one chunk of the review detail pr-finalizer posts,
# <!-- sdlc:theorem-records <i>/<N> -->, as a jq regex capturing the
# chunk's position as `i` and the total as `n`.
SP_RECORDS_MARKER_RE='^<!-- sdlc:theorem-records (?<i>[0-9]+)/(?<n>[0-9]+) -->$'

# sp_fail <status> <message> -- print <message>, prefixed with the
# script's name, and exit with <status>.
sp_fail() {
  printf '%s: %s\n' "$SP_PROGRAM" "$2" >&2
  exit "$1"
}

# sp_usage_error <message> -- the exit-2 failure. When the script
# defines a `usage` function, its synopsis follows the message.
sp_usage_error() {
  printf '%s: %s\n' "$SP_PROGRAM" "$1" >&2
  if command -v usage >/dev/null 2>&1; then
    usage >&2
  fi
  exit 2
}

# A command that fails where the script does not handle it exits 1
# naming the command, never with the tool's own status. `set -E` carries
# the trap into functions and command substitutions; a substitution whose
# failure the script handles ends in `|| exit` inside it, so the trap
# stays quiet in the substitution's own shell.
set -E
trap 'sp_fail 1 "\`$BASH_COMMAND\` failed (exit $?)"' ERR

# sp_parse_pr <ref> -- parse the canonical reference
# <host>/<owner>/<repo>#<n> that `/github-prs:pr-view <PR> --ref` prints,
# setting SP_REF to it whole, SP_REPO to <host>/<owner>/<repo> and SP_PR
# to <n>. Any other form is a usage error: a reference without its host
# names a different repository on every host.
sp_parse_pr() {
  local repo n rest segment
  repo=${1%'#'*}
  n=${1##*'#'}
  case "$1" in
    *'#'*) ;;
    *) sp_err_not_pr_ref "$1" ;;
  esac
  case "$n" in
    '' | *[!0-9]*) sp_err_not_pr_ref "$1" ;;
  esac
  case "$repo" in
    */*/*/* | *//* | /* | */) sp_err_not_pr_ref "$1" ;;
    ?*/?*/?*) ;;
    *) sp_err_not_pr_ref "$1" ;;
  esac
  rest=$repo
  while [ -n "$rest" ]; do
    segment=${rest%%/*}
    case "$segment" in
      *[!A-Za-z0-9._-]* | . | ..) sp_err_not_pr_ref "$1" ;;
    esac
    case "$rest" in
      */*) rest=${rest#*/} ;;
      *) rest= ;;
    esac
  done
  SP_REF=$1
  SP_REPO=$repo
  SP_PR=$n
}

# sp_err_not_pr_ref <ref> -- the usage error for a reference sp_parse_pr
# refuses.
sp_err_not_pr_ref() {
  sp_usage_error "\`$1\` is not a PR reference. Pass <host>/<owner>/<repo>#<n>, as \`pr-view <PR> --ref\` prints it."
}

# sp_pr_view <fields> -- the PR's JSON for those `gh pr view --json`
# fields, which for reviews and comments gh pages to the end. Call it as
# `json=$(sp_pr_view ...) || exit $?`, since an exit inside a command
# substitution leaves only its own shell.
sp_pr_view() {
  local rc=0
  gh pr view "$SP_PR" --repo "$SP_REPO" --json "$1" || rc=$?
  [ "$rc" -eq 0 ] || sp_fail 1 "gh pr view of $SP_REF failed (exit $rc)"
}

# sp_jq_prelude -- print the text a jq filter over PR comments starts
# with: it defines `first_line`, a comment body's first line without the
# trailing carriage return a body posted from GitHub's web form carries,
# and binds the two markers above as $brief and $records. Call it as
# `jq "$(sp_jq_prelude)"'<filter>'`.
sp_jq_prelude() {
  printf '%s' 'def first_line: (split("\n") | .[0] // "") | rtrimstr("\r"); '
  sp_jq_string "$SP_FIXER_BRIEF_MARKER"
  printf '%s' " as \$brief | "
  sp_jq_string "$SP_RECORDS_MARKER_RE"
  printf '%s' " as \$records | "
}

# sp_jq_string <text> -- print <text> as a jq string literal.
sp_jq_string() {
  local s=${1//\\/\\\\}
  printf '"%s"' "${s//\"/\\\"}"
}
