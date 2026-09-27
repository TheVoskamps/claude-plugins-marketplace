# shellcheck shell=bash
#
# github-prs-common.sh -- sourced by every script in plugins/github-prs/bin/.
# It holds the error catalogue every verb reports through and the `gh`
# call wrapper every verb calls through, so one message and one exit
# status mean the same thing whichever verb printed it. A verb reports
# a failure by calling a catalogue entry below and never spells a
# message of its own. Runs under the bash 3.2 macOS ships.
#
# Exit statuses, shared by every verb:
#   0  the verb did what it says
#   1  the verb's own negative outcome: a change that did not land on
#      the re-read, a PR that is not open, a merge state still UNKNOWN
#   2  a usage error; nothing was sent to GitHub
#   3  a `gh` or `git` call failed; the tool's own stderr is passed
#      through above the catalogue line
#   4  .issues/repo-config.md is missing or lacks a key the verb reads

GP_PROGRAM=${0##*/}

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

# gp_not_landed <pr> <what> <why> -- the exit-1 failure for a mutation
# whose re-read does not show it: "PR #<pr>: <what> did not land: <why>".
gp_not_landed() {
  gp_fail 1 "PR #$1: $2 did not land: $3"
}

# gp_gh <gh args...> -- run gh, passing its stdout through. On failure
# gh's stderr has already reached ours; add the catalogue line naming
# the call and exit 3. Call it as `out=$(gp_gh ...) || exit $?`, since
# an exit inside a command substitution leaves only its subshell.
gp_gh() {
  local rc=0
  gh "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    gp_err_gh "$1 $2" "$rc"
  fi
}

# gp_pr_number <arg> -- the PR number with any leading `#` stripped, or
# a usage error when what is left is not all digits.
gp_pr_number() {
  local n=${1#\#}
  case "$n" in
    '' | *[!0-9]*) gp_err_not_pr_number "$1" ;;
  esac
  printf '%s\n' "$n"
}

# gp_issue_number <arg> -- the same for an issue number, which may also
# arrive with a trailing comma from a comma-separated list.
gp_issue_number() {
  local n=${1#\#}
  n=${n%,}
  case "$n" in
    '' | *[!0-9]*) gp_err_not_issue_number "$1" ;;
  esac
  printf '%s\n' "$n"
}

# gp_repo_path <suffix> -- a REST path under the current repo, with
# gh's own {owner}/{repo} placeholders left for gh to resolve.
gp_repo_path() {
  printf 'repos/{owner}/{repo}/%s\n' "$1"
}

# --- The catalogue --------------------------------------------------------
# One entry per message, grouped by exit status. Each prints its line
# and exits.

# Exit 2: usage errors.
gp_err_no_pr() { gp_usage_error "No PR number was supplied."; }
gp_err_one_pr() { gp_usage_error "Pass exactly one PR number."; }
gp_err_pr_and_body_file() { gp_usage_error "Pass a PR number and \`--body-file <path>\`."; }
gp_err_pr_and_issues() { gp_usage_error "Pass a PR number and at least one issue number."; }
gp_err_not_pr_number() { gp_usage_error "\`$1\` is not a PR number."; }
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

# Exit 1: the verb's own negative outcomes.
# gp_err_not_open <pr> <state>
gp_err_not_open() {
  gp_fail 1 "PR #$1 is $2, not open. Merge readiness is only computed for an open PR."
}
# gp_err_no_pr_in_url <what gh printed> -- gh pr create succeeded but
# named no PR number, so there is nothing to re-read.
gp_err_no_pr_in_url() {
  gp_fail 1 "gh pr create reported \`$1\`, which names no PR number"
}
# gp_err_flip_not_landed <pr> <ready|draft> <isDraft read back>
gp_err_flip_not_landed() {
  gp_not_landed "$1" "the $2 flip" "the re-read still reports isDraft $3"
}
# gp_err_draft_pr_not_landed <pr> <read back> <wanted>, each spelled
# "<isDraft> <base> <head>".
gp_err_draft_pr_not_landed() {
  gp_not_landed "$1" "the draft PR" \
    "the re-read reports isDraft, base and head as \`$2\`, not \`$3\`"
}
# gp_err_body_not_landed <pr> <what was written into the body>
gp_err_body_not_landed() {
  gp_not_landed "$1" "$2" "the re-read body is not the body written"
}
# gp_err_body_file_not_landed <pr> <body file>
gp_err_body_file_not_landed() {
  gp_not_landed "$1" "the body edit" "the re-read body differs from $2"
}
# gp_err_comment_no_id <pr> <what gh printed>
gp_err_comment_no_id() {
  gp_not_landed "$1" "the comment" "gh reported \`$2\`, which names no comment id"
}
# gp_err_comment_not_landed <pr> <comment id> <body file>
gp_err_comment_not_landed() {
  gp_not_landed "$1" "the comment" "comment $2's body differs from $3"
}
# gp_err_review_missing <pr> <login>
gp_err_review_missing() {
  gp_not_landed "$1" "the review" "no new review by $2 is on the PR"
}
# gp_err_review_state <pr> <review id> <state read back> <state wanted>
gp_err_review_state() {
  gp_not_landed "$1" "the review" "review $2 has state $3, not $4"
}
# gp_err_review_body <pr> <review id>
gp_err_review_body() {
  gp_not_landed "$1" "the review" "review $2's body is not the body written"
}

# Exit 3: a gh or git call failed.
# gp_err_gh <gh subcommand> <gh's exit status>
gp_err_gh() { gp_fail 3 "gh $1 failed (exit $2)"; }
# gp_err_git <the git call, as the message names it>
gp_err_git() { gp_fail 3 "$1 failed"; }
gp_err_not_a_repo() { gp_fail 3 "not inside a git repository"; }
# gp_err_merge_no_conflict <base ref>
gp_err_merge_no_conflict() {
  gp_fail 3 "the trial merge of origin/$1 failed without leaving a conflicted file"
}

# Exit 4: repo-config.
gp_err_no_config() {
  gp_fail 4 "This repo has no \`.issues/repo-config.md\`. Run \`/repo-config\` to create one."
}
# gp_err_config_key <key>
gp_err_config_key() {
  gp_fail 4 "\`.issues/repo-config.md\` has no \`$1\` in its front matter."
}
