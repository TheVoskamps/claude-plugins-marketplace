# shellcheck shell=bash
#
# github-prs-common.sh -- sourced by every script in plugins/github-prs/bin/.
# It holds the error catalogue every verb reports through, the `gh`
# call wrapper every verb calls through, and the parser of the PR
# reference every PR verb takes, so one message and one exit status
# mean the same thing whichever verb printed it, and one reference
# names the same PR whichever verb received it. A verb reports
# a failure by calling a catalogue entry below and never spells a
# message of its own. Runs under the bash 3.2 macOS ships.
#
# Exit statuses, shared by every verb:
#   0    the verb did what it was asked, or the condition it reports holds
#   1    a generic failure: any command or bash error; stderr says what
#   2    a usage error; nothing was done
#   3    the verb's own negative outcome: a change that did not land on
#        the re-read, a PR that is not open, a merge state still UNKNOWN
#   4    .issues/repo-config.md is missing or lacks a key the verb reads
#   126  bash: a command the verb ran was not executable
#   127  bash: a command the verb ran was not found
#   128+N  killed by signal N
# 1 is the generic failure because bash itself exits 1 on a failure no
# trap can intercept, such as an unbound variable under `set -u`; every
# other non-zero status a verb reports sits from 2 up, below 126.
#
# Exit 1 covers a failure the verb does not handle as well as one it
# does: the ERR trap below, which `set -E` passes to every function,
# command substitution and pipeline element, turns any failed command
# into gp_err_command's catalogue line and exit 1, so no verb exits with
# a wrapped tool's own status -- a command that was not found or not
# executable included, so 126 and 127 reach a caller only from where
# the trap cannot see. Under bash 3.2 the trap cannot see a failure in
# these, so no verb uses them:
#   - a command substitution anywhere but as the whole right-hand side
#     of a plain `name=$(...)` assignment -- not in an argument, a test,
#     a `for` or `case` word, a here-document, or `local name=$(...)`;
#   - a `( ... )` subshell, or a `<( ... )` process substitution;
#   - a function called as a condition (`if f`, `f ||`, `! f`), unless
#     every command in it handles its own failure;
#   - `|| exit $?` after an external command, which hands the verb that
#     command's own status as a condition the trap never sees fail.
# Inside a command substitution the trap runs in the substitution's own
# shell, and prints there. A substitution whose failure the verb handles
# -- a fallback, or an `if` -- therefore ends in `|| exit` inside it, so
# its command fails as a condition and the trap stays quiet; one that
# calls a function ends in `|| exit $?` outside it, so the status the
# function's catalogue entry chose is the verb's.

GP_PROGRAM=${0##*/}

set -E
trap 'gp_err_command "$BASH_COMMAND" "$?"' ERR

# gp_fail <status> <message> -- print <message>, prefixed with the
# verb's name, and exit with <status>.
gp_fail() {
  printf '%s: %s\n' "$GP_PROGRAM" "$2" >&2
  exit "$1"
}

# gp_usage_error <message> -- the exit-2 failure. When the verb defines
# a `usage` function, its synopsis follows the message on stderr.
gp_usage_error() {
  printf '%s: %s\n' "$GP_PROGRAM" "$1" >&2
  if command -v usage >/dev/null 2>&1; then
    usage >&2
  fi
  exit 2
}

# gp_not_landed <what> <why> -- the exit-3 failure for a mutation whose
# re-read does not show it: "PR <pr>: <what> did not land: <why>". <pr>,
# here and in every catalogue entry below that names the PR, is the PR
# as GP_PR_NAME spells it.
gp_not_landed() {
  gp_fail 3 "PR $GP_PR_NAME: $1 did not land: $2"
}

# gp_gh <gh args...> -- run gh, passing its stdout through. On failure
# gh's stderr has already reached ours; add the catalogue line naming
# the call and exit 1. Call it as `out=$(gp_gh ...) || exit $?`, since
# an exit inside a command substitution leaves only its subshell.
#
# A `gh api` call goes to gh's default host whatever host the checkout's
# remote is on, so an `api` call here carries --hostname "$GP_HOST",
# which a verb sets with gp_resolve_host before its first one. `gh pr`
# takes the host from the remote, or from the --repo gp_pr adds.
gp_gh() {
  local rc=0 call="$1 $2"
  if [ "$1" = api ]; then
    shift
    gh api --hostname "$GP_HOST" "$@" || rc=$?
  else
    gh "$@" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    gp_err_gh "$call" "$rc"
  fi
}

# gp_current_repo -- set GP_CUR_HOST, GP_CUR_OWNER and GP_CUR_REPO to
# the current repository, from the URL `gh repo view` reports for it.
# Exits 1 when gh cannot say. Calls gh at most once per run.
GP_CUR_HOST=
gp_current_repo() {
  local url
  [ -z "$GP_CUR_HOST" ] || return 0
  url=$(gp_gh repo view --json url --jq .url) || exit $?
  url=${url#https://}
  url=${url%/}
  GP_CUR_HOST=${url%%/*}
  url=${url#*/}
  GP_CUR_OWNER=${url%/*}
  GP_CUR_REPO=${url##*/}
}

# gp_resolve_host -- set GP_HOST to the host of the PR's repository:
# already set when gp_parse_pr resolved a reference naming a
# repository, the current repository's otherwise.
GP_HOST=
gp_resolve_host() {
  [ -z "$GP_HOST" ] || return 0
  gp_current_repo
  GP_HOST=$GP_CUR_HOST
}

# gp_valid_name <name> -- succeed when <name> is a repository name
# GitHub allows: 1 to 100 ASCII letters, digits, ".", "-" and "_", any
# of them first.
gp_valid_name() {
  case "$1" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 100 ]
}

# gp_valid_owner <owner> -- succeed when <owner> is an owner GitHub
# allows: 1 to 39 ASCII letters, digits and "-", not starting with "-"
# and with no "--".
gp_valid_owner() {
  case "$1" in
    '' | -* | *--* | *[!A-Za-z0-9-]*) return 1 ;;
  esac
  [ "${#1}" -le 39 ]
}

# gp_valid_host <host> -- succeed when <host> is a DNS hostname: at
# most 253 characters of "."-separated labels, each 1 to 63 ASCII
# letters, digits and "-", neither starting nor ending with "-".
gp_valid_host() {
  local rest=$1. label
  [ "${#1}" -le 253 ] || return 1
  while [ -n "$rest" ]; do
    label=${rest%%.*}
    case "$label" in
      '' | -* | *- | *[!A-Za-z0-9-]*) return 1 ;;
    esac
    [ "${#label}" -le 63 ] || return 1
    rest=${rest#*.}
  done
}

# gp_valid_path <path> -- succeed when each part of repo, owner/repo or
# host/owner/repo is valid for its place, by gp_valid_host,
# gp_valid_owner and gp_valid_name. iss_parse_operand in the issues
# plugin validates by the same rules.
gp_valid_path() {
  case "$1" in
    */*/*/*) return 1 ;;
    */*/*) gp_valid_host "${1%%/*}" && gp_valid_path "${1#*/}" ;;
    */*) gp_valid_owner "${1%/*}" && gp_valid_name "${1#*/}" ;;
    *) gp_valid_name "$1" ;;
  esac
}

# gp_parse_pr <ref> -- the one parser of the PR-reference grammar that
# skills/lib/pr-reference.md states. Sets
#   GP_PR        the PR number
#   GP_PR_NAME   the PR as a message names it: #N, or host/owner/repo#N
#                when the reference named a repository
#   GP_HOST, GP_OWNER, GP_REPO and GP_REPO_ARG (host/owner/repo) when
#                the reference named a repository; all empty otherwise
# A reference that names a repository without its host, or without its
# owner and host, takes what it omits from the current repository. A
# malformed reference is a usage error before any gh call.
GP_OWNER=
GP_REPO=
GP_REPO_ARG=
gp_parse_pr() {
  local ref=$1 repo n
  case "$ref" in
    https://*/pull/*)
      repo=${ref#https://}
      repo=${repo%/}
      n=${repo##*/pull/}
      repo=${repo%/pull/*}
      case "$repo" in
        */*/*) ;;
        *) gp_err_not_pr_ref "$ref" ;;
      esac
      ;;
    *://*) gp_err_not_pr_ref "$ref" ;;
    *'#'*)
      repo=${ref%'#'*}
      n=${ref##*'#'}
      ;;
    *)
      repo=
      n=$ref
      ;;
  esac
  case "$n" in
    '' | *[!0-9]*) gp_err_not_pr_ref "$ref" ;;
  esac
  case "$repo" in
    */*/*/* | *//* | /* | */) gp_err_not_pr_ref "$ref" ;;
  esac
  [ -z "$repo" ] || gp_valid_path "$repo" || gp_err_not_pr_ref "$ref"
  GP_PR=$n
  if [ -z "$repo" ]; then
    GP_PR_NAME="#$n"
    return 0
  fi
  case "$repo" in
    */*/*)
      GP_HOST=${repo%%/*}
      repo=${repo#*/}
      ;;
    */*)
      gp_current_repo
      GP_HOST=$GP_CUR_HOST
      ;;
    *)
      gp_current_repo
      GP_HOST=$GP_CUR_HOST
      repo="$GP_CUR_OWNER/$repo"
      ;;
  esac
  GP_OWNER=${repo%/*}
  GP_REPO=${repo#*/}
  GP_REPO_ARG="$GP_HOST/$GP_OWNER/$GP_REPO"
  GP_PR_NAME="$GP_REPO_ARG#$n"
}

# gp_lc <string> -- <string> lowercased. GitHub matches host, owner and
# repository names without regard to case, so a comparison or a name
# built from them lowercases them first.
gp_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# gp_other_repo -- print `yes` when gp_parse_pr's reference named a
# repository other than the current one, compared through gp_lc, and
# nothing otherwise. Call it as `x=$(gp_other_repo) || exit $?`: it
# prints rather than returning a status because a function called as a
# condition runs outside the ERR trap.
gp_other_repo() {
  local named current
  [ -n "$GP_REPO_ARG" ] || return 0
  gp_current_repo
  named=$(gp_lc "$GP_REPO_ARG") || exit $?
  current=$(gp_lc "$GP_CUR_HOST/$GP_CUR_OWNER/$GP_CUR_REPO") || exit $?
  if [ "$named" != "$current" ]; then
    echo yes
  fi
}

# gp_pr <subcommand> <args...> -- `gh pr <subcommand> <PR> <args...>`
# through gp_gh, with --repo naming the PR's repository when the
# reference named one.
gp_pr() {
  local sub=$1
  shift
  if [ -n "$GP_REPO_ARG" ]; then
    gp_gh pr "$sub" "$GP_PR" "$@" --repo "$GP_REPO_ARG"
  else
    gp_gh pr "$sub" "$GP_PR" "$@"
  fi
}

# gp_issue_number <arg> -- the issue number with any leading `#` and
# any trailing comma from a comma-separated list stripped, or a usage
# error when what is left is not all digits.
gp_issue_number() {
  local n=${1#\#}
  n=${n%,}
  case "$n" in
    '' | *[!0-9]*) gp_err_not_issue_number "$1" ;;
  esac
  printf '%s\n' "$n"
}

# gp_joined <list> -- the words of <list>, separated by any whitespace,
# as one comma-separated list.
gp_joined() {
  printf '%s\n' "$1" |
    awk '{ for (i = 1; i <= NF; i++) printf "%s%s", (n++ ? ", " : ""), $i }'
}

# gp_closing_issues <body> -- the one closing-line recognizer: print the
# issues <body> closes in the PR's repository, one per line, ascending,
# without duplicates. An issue counts only when a closing keyword
# (close, closes, closed, fix, fixes, fixed, resolve, resolves,
# resolved, any case), as a whole word and optionally followed by a
# colon, is followed by whitespace and then immediately by a reference
# to it: #N, repo#N, owner/repo#N, host/owner/repo#N, or
# https://host/owner/repo/issues/N, naming the PR's repository, and
# ending where a word would. Each reference needs its own keyword; any
# other form counts as not closed. N prints without leading zeros, and
# #0 closes nothing. The PR's repository is the one gp_parse_pr
# resolved, or the current one, looked up only when a reference names a
# repository. That lookup runs in a pipeline subshell, so a failed one
# returns 1 rather than exiting the caller, and only under the pipefail
# every verb sets, without which sort's 0 masks it: call it as
# `out=$(gp_closing_issues ...) || exit $?`.
gp_closing_issues() {
  local rest want='' ref n kw='close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved'
  local re="(^|[^a-z0-9_])($kw):?[[:space:]]+(https://([^[:space:]/]+/[^[:space:]/]+/[^[:space:]/]+)/issues/([0-9]+)|(([a-z0-9._-]+/){0,2}[a-z0-9._-]+)?#([0-9]+))([^a-z0-9_]|$)"
  rest=$(gp_lc "$1") || exit $?
  # A match is context-free once it carries the character after the
  # reference, so its first occurrence is where it matched; one that
  # ends at the end of the text has nothing after it to scan.
  while [[ $rest =~ $re ]]; do
    if [ -n "${BASH_REMATCH[9]}" ]; then
      rest=${BASH_REMATCH[9]}${rest#*"${BASH_REMATCH[0]}"}
    else
      rest=
    fi
    if [ -n "${BASH_REMATCH[5]}" ]; then
      ref=${BASH_REMATCH[4]}
      n=${BASH_REMATCH[5]}
    else
      ref=${BASH_REMATCH[6]}
      n=${BASH_REMATCH[8]}
    fi
    if [ -n "$ref" ]; then
      if [ -z "$want" ]; then
        if [ -n "$GP_REPO_ARG" ]; then
          want=$(gp_lc "$GP_HOST/$GP_OWNER/$GP_REPO") || exit $?
        else
          gp_current_repo
          want=$(gp_lc "$GP_CUR_HOST/$GP_CUR_OWNER/$GP_CUR_REPO") || exit $?
        fi
      fi
      case "$ref" in
        */*/*) ;;
        */*) ref=${want%%/*}/$ref ;;
        *) ref=${want%/*}/$ref ;;
      esac
      [ "$ref" = "$want" ] || continue
    fi
    n=${n#"${n%%[!0]*}"}
    [ -z "$n" ] || printf '%s\n' "$n"
  done | sort -nu
}

# gp_repo_path <suffix> -- a REST path under the PR's repository: the
# owner and repository the reference named, or else gh's own
# {owner}/{repo} placeholders, left for gh to resolve to the current
# repository from the checkout. The host is gp_gh's --hostname.
gp_repo_path() {
  if [ -n "$GP_REPO_ARG" ]; then
    printf 'repos/%s/%s/%s\n' "$GP_OWNER" "$GP_REPO" "$1"
  else
    printf 'repos/{owner}/{repo}/%s\n' "$1"
  fi
}

# --- The catalogue --------------------------------------------------------
# One entry per message, grouped by exit status. Each prints its line
# and exits.

# Exit 2: usage errors.
gp_err_no_pr() { gp_usage_error "No PR was supplied."; }
gp_err_one_pr() { gp_usage_error "Pass exactly one PR."; }
gp_err_pr_and_body_file() { gp_usage_error "Pass a PR and \`--body-file <path>\`."; }
gp_err_pr_and_issues() { gp_usage_error "Pass a PR and at least one issue number."; }
gp_err_not_pr_ref() {
  gp_usage_error "\`$1\` is not a PR. Pass N, #N, repo#N, owner/repo#N, host/owner/repo#N, or https://host/owner/repo/pull/N."
}
gp_err_not_issue_number() { gp_usage_error "\`$1\` is not an issue number."; }
gp_err_unknown_arg() { gp_usage_error "\`$1\` is not an argument $GP_PROGRAM takes."; }
# gp_err_needs_value <flag> <what the value is, with its article>
gp_err_needs_value() { gp_usage_error "\`$1\` needs $2."; }
# gp_err_missing <what was not supplied>
gp_err_missing() { gp_usage_error "No $1 was supplied."; }
gp_err_unreadable() { gp_usage_error "\`$1\` is not a readable file."; }
gp_err_bad_state() { gp_usage_error "\`$1\` is not a state. Pass open, closed, merged, or all."; }
gp_err_jq_needs_json() {
  gp_usage_error "\`--jq\` filters the \`--json\` fields, so it needs \`--json\` too."
}
gp_err_ref_alone() {
  gp_usage_error "\`--ref\` prints the PR's reference alone, so it takes no \`--json\`."
}
gp_err_no_verdict() {
  gp_usage_error "No \`--verdict\` was supplied. Pass exactly one of \`approve\`, \`request_changes\`, or \`comment\`."
}
# gp_err_verdict_twice <first value> <second value>
gp_err_verdict_twice() {
  gp_usage_error "\`--verdict\` was supplied more than once, as \`$1\` and \`$2\`. Pass exactly one of \`approve\`, \`request_changes\`, or \`comment\`."
}
gp_err_bad_verdict() {
  gp_usage_error "\`$1\` is not a verdict. Pass \`approve\`, \`request_changes\`, or \`comment\`."
}
gp_err_both_bodies() {
  gp_usage_error "Both an inline \`<body>\` and \`--body-file <path>\` were supplied. Pass exactly one."
}
gp_err_no_body() {
  gp_usage_error "No review body was supplied. Pass either an inline \`<body>\` or \`--body-file <path>\`."
}
gp_err_many_bodies() { gp_usage_error "More than one review body was supplied. Pass exactly one."; }

# Exit 3: the verb's own negative outcomes.
# gp_err_not_open <state>
gp_err_not_open() {
  gp_fail 3 "PR $GP_PR_NAME is $1, not open. Merge readiness is only computed for an open PR."
}
# gp_err_still_unknown <reads made>
gp_err_still_unknown() {
  gp_fail 3 "PR $GP_PR_NAME: mergeable is still UNKNOWN after $1 reads. GitHub has not finished computing the merge state."
}
# gp_err_no_pr_in_url <what gh printed> -- gh pr create succeeded but
# named no PR number, so there is nothing to re-read.
gp_err_no_pr_in_url() {
  gp_fail 3 "gh pr create reported \`$1\`, which names no PR number"
}
# gp_err_flip_not_landed <ready|draft> <isDraft read back>
gp_err_flip_not_landed() {
  gp_not_landed "the $1 flip" "the re-read still reports isDraft $2"
}
# gp_err_draft_pr_not_landed <read back> <wanted>, each spelled
# "<isDraft> <base> <head>".
gp_err_draft_pr_not_landed() {
  gp_not_landed "the draft PR" \
    "the re-read reports isDraft, base and head as \`$1\`, not \`$2\`"
}
# gp_err_body_not_landed <what was written into the body>
gp_err_body_not_landed() {
  gp_not_landed "$1" "the re-read body is not the body written"
}
# gp_err_body_file_not_landed <body file>
gp_err_body_file_not_landed() {
  gp_not_landed "the body edit" "the re-read body differs from $1"
}
# gp_err_comment_no_id <what gh printed>
gp_err_comment_no_id() {
  gp_not_landed "the comment" "gh reported \`$1\`, which names no comment id"
}
# gp_err_comment_not_landed <comment id> <body file>
gp_err_comment_not_landed() {
  gp_not_landed "the comment" "comment $1's body differs from $2"
}
gp_err_review_missing() {
  gp_not_landed "the review" "no new review is on the PR"
}
# gp_err_review_state <review id> <state read back> <state wanted>
gp_err_review_state() {
  gp_not_landed "the review" "review $1 has state $2, not $3"
}
# gp_err_review_body <review id>
gp_err_review_body() {
  gp_not_landed "the review" "review $1's body is not the body written"
}

# Exit 1: a command the verb ran failed.
# gp_err_command <command> <its exit status> -- the ERR trap's entry,
# for a failure the verb did not handle.
gp_err_command() { gp_fail 1 "\`$1\` failed (exit $2)"; }
# gp_err_gh <gh subcommand> <gh's exit status>
gp_err_gh() { gp_fail 1 "gh $1 failed (exit $2)"; }
# gp_err_git <the git call, as the message names it>
gp_err_git() { gp_fail 1 "$1 failed"; }
gp_err_not_a_repo() { gp_fail 1 "not inside a git repository"; }
# gp_err_merge_no_conflict <the base, as the report names it>
gp_err_merge_no_conflict() {
  gp_fail 1 "the trial merge of $1 failed without leaving a conflicted file"
}

# Exit 4: repo-config.
gp_err_no_config() {
  gp_fail 4 "This repo has no \`.issues/repo-config.md\`. Run \`/repo-config\` to create one."
}
# gp_err_config_key <key>
gp_err_config_key() {
  gp_fail 4 "\`.issues/repo-config.md\` has no \`$1\` in its front matter."
}
