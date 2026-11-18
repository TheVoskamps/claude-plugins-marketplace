# shellcheck shell=bash
#
# sdlc-pr-common.sh -- sourced by the sdlc scripts that read a PR's
# reviews and comments, by sdlc-pr-post-theorem-records, which posts the
# review detail, by sdlc-agent-result-persist, which writes the
# review-round marker, and by sdlc-decision, which puts a decision to the
# human. It spells the markers sdlc writes, parses the
# canonical PR reference those scripts take, makes the one `gh` read
# they share, and holds the failure exits, so a marker, a reference and
# an exit status mean the same thing in every one of them. It also
# holds the state root's repository layout, which sdlc-agent-result-persist
# and sdlc-decision both write under.
# sdlc-agent-result-persist takes only the marker and the layout: its
# own ERR trap replaces this file's, and its exits are its own. Runs
# under the bash 3.2 macOS ships.
#
# Exit statuses, shared by the scripts that report through it:
#   0  the script did what it says
#   1  a command the script ran failed; the tool's own stderr is passed
#      through above the script's line
#   2  a usage error; nothing was read
#   3  the script's own negative outcome, which its contract names
# sdlc-pr-post-theorem-records shares 0 and 2, widens 1 to any
# unexpected failure, including ones no command reported, and names its
# own exits from 3 on, in its header.

SP_PROGRAM=${0##*/}

# The first line of a brief to issue-fixer.
SP_FIXER_BRIEF_MARKER='<!-- sdlc:fixer-brief -->'
# The first line of one chunk of the review detail pr-finalizer posts,
# <!-- sdlc:theorem-records <first>-<last> <i>/<N> -->, as a jq regex
# capturing the chain's rounds as `first` and `last`, the chunk's
# position as `i` and the chain's total as `n`. It also matches the old
# form, <!-- sdlc:theorem-records <i>/<N> -->, capturing `first` and
# `last` as null.
SP_RECORDS_MARKER_RE='^<!-- sdlc:theorem-records (?:(?<first>[0-9]+)-(?<last>[0-9]+) )?(?<i>[0-9]+)/(?<n>[0-9]+) -->$'

# sp_records_marker <first> <last> <i> <N> -- print the marker for chunk
# <i> of <N> of a chain holding rounds <first> to <last>, without a
# newline, for the script that writes it.
sp_records_marker() {
  printf '<!-- sdlc:theorem-records %s-%s %s/%s -->' "$1" "$2" "$3" "$4"
}

# A line of the body sdlc-agent-result-persist --mode summary renders for
# a pipeline review, <!-- sdlc:review-round <n> -->, naming the round the
# review posts, as a jq regex capturing the round as `n`. It need not be
# the body's first line: pr-review-submit puts a verdict line above it.
SP_REVIEW_ROUND_MARKER_RE='^<!-- sdlc:review-round (?<n>[0-9]+) -->$'

# sp_review_round_marker <n> -- print the same marker for round <n>,
# without a newline, for the script that writes it.
sp_review_round_marker() {
  printf '<!-- sdlc:review-round %s -->' "$1"
}

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

# The state root's repository layout. A repository's state directory is
# <host>/<owner>/<repo> under the state root, and carries repo.yml naming
# the repository it holds, so a reader identifies the directory from the
# file rather than from its path. Each function below that can fail
# prints its message, prefixed with the script's name, and returns 1,
# for the caller to exit with its own failure status.

# sp_state_error <message> -- print a layout function's failure message.
sp_state_error() {
  printf '%s: %s\n' "$SP_PROGRAM" "$1" >&2
}

# sp_is_old_layout <dir> -- whether a directory two levels below the
# state root is a repository's state from before the host was part of
# the path. Such a directory is <owner>/<repo> by position, carries no
# repo.yml, and holds its pr<n> directories directly. A <host>/<owner>
# directory of the current layout sits at the same depth and holds
# repositories, so it is never old, with or without a repo.yml beneath it.
sp_is_old_layout() {
  local found
  [ -d "$1" ] || return 1
  [ -e "$1/repo.yml" ] && return 1
  for found in "$1"/*/repo.yml; do
    [ -e "$found" ] && return 1
  done
  for found in "$1"/pr*; do
    case "${found##*/}" in
      pr | pr*[!0-9]*) continue ;;
    esac
    [ -d "$found" ] && return 0
  done
  return 1
}

# sp_write_repo_yml <repo-dir> <host> <owner> <repo> -- write repo.yml
# into a repository's state directory that lacks one.
sp_write_repo_yml() {
  [ -e "$1/repo.yml" ] && return 0
  if printf 'schema-version: 1\nhost: %s\nowner: %s\nrepo: %s\n' "$2" "$3" "$4" >"$1/repo.yml.partial-$$" &&
    mv -- "$1/repo.yml.partial-$$" "$1/repo.yml"; then
    return 0
  fi
  sp_state_error "could not write $1/repo.yml"
  return 1
}

# sp_migrate_old_layout <state-root> <host> <owner> <repo> -- move state
# written before the host was part of the path, at <owner>/<repo> under
# the state root, to the repository's directory, and write its repo.yml.
# Each script that writes under the state root runs it before it creates
# the repository's directory, so no script splits a repository's state
# across both paths.
sp_migrate_old_layout() {
  local old="$1/$3/$4" new="$1/$2/$3/$4"
  sp_is_old_layout "$old" || return 0
  if [ -e "$new" ]; then
    sp_state_error "state for $2/$3/$4 is at both $old and $new; move one aside before running again"
    return 1
  fi
  if ! mkdir -p -- "${new%/*}"; then
    sp_state_error "could not create ${new%/*}"
    return 1
  fi
  if ! mv -- "$old" "$new"; then
    # A failed move leaves no empty <host> or <host>/<owner> directory
    # behind; rmdir removes neither when it holds anything.
    rmdir -- "${new%/*}" 2>/dev/null && rmdir -- "$1/$2" 2>/dev/null || :
    sp_state_error "could not move state for $2/$3/$4 from $old to $new"
    return 1
  fi
  rmdir -- "$1/$3" 2>/dev/null || :
  sp_write_repo_yml "$new" "$2" "$3" "$4"
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

# sp_jq_prelude -- print the text a jq filter over PR comments or reviews
# starts with. It defines `first_line`, a comment body's first line
# without the trailing carriage return a body posted from GitHub's web
# form carries, and `body_lines`, a body's lines each without it, and
# binds the markers above as $brief, $records and $review_round. Over a
# review it defines `review_round`, the highest round the
# review's stamp lines name, or null when it carries none, and
# `pipeline_review`, whether the review is one a review round posted: a
# stamped one, or, from before the stamp existed, one whose body has both
# a `## Verdicts` line and a `## Review method` line. Call it as
# `jq "$(sp_jq_prelude)"'<filter>'`.
sp_jq_prelude() {
  printf '%s' 'def first_line: (split("\n") | .[0] // "") | rtrimstr("\r"); '
  printf '%s' 'def body_lines: (.body // "") | split("\n") | map(rtrimstr("\r")); '
  sp_jq_string "$SP_FIXER_BRIEF_MARKER"
  printf '%s' " as \$brief | "
  sp_jq_string "$SP_RECORDS_MARKER_RE"
  printf '%s' " as \$records | "
  sp_jq_string "$SP_REVIEW_ROUND_MARKER_RE"
  printf '%s' " as \$review_round | "
  printf '%s' "def review_round: [body_lines[] | capture(\$review_round).n | tonumber] | max; "
  printf '%s' 'def pipeline_review: review_round != null'
  printf '%s' ' or (body_lines | index(["## Verdicts"]) != null and index(["## Review method"]) != null); '
}

# sp_jq_string <text> -- print <text> as a jq string literal.
sp_jq_string() {
  local s=${1//\\/\\\\}
  printf '"%s"' "${s//\"/\\\"}"
}
