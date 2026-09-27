# shellcheck shell=bash
#
# github-prs-common.sh -- sourced by every script in plugins/github-prs/bin/.
# It holds the error catalogue every verb reports through and the `gh`
# call wrapper every verb calls through, so one message and one exit
# status mean the same thing whichever verb printed it. Runs under the
# bash 3.2 macOS ships.
#
# Exit statuses, shared by every verb:
#   0  the verb did what it says
#   1  the verb's own negative outcome: a change that did not land on
#      the re-read, a PR that is not open, a merge state still UNKNOWN
#   2  a usage error; nothing was sent to GitHub
#   3  a `gh` call failed; gh's own stderr is passed through above the
#      catalogue line
#   4  .issues/repo-config.md is missing or lacks a key the verb reads

GP_PROGRAM=${0##*/}

gp_fail() {
  printf '%s: %s\n' "$GP_PROGRAM" "$2" >&2
  exit "$1"
}

gp_usage_error() {
  printf '%s: %s\n' "$GP_PROGRAM" "$1" >&2
  if command -v usage >/dev/null 2>&1; then
    usage >&2
  fi
  exit 2
}

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
    gp_fail 3 "gh $1 $2 failed (exit $rc)"
  fi
}

# gp_pr_number <arg> -- the PR number with any leading `#` stripped, or
# a usage error when what is left is not all digits.
gp_pr_number() {
  local n=${1#\#}
  case "$n" in
    '' | *[!0-9]*) gp_usage_error "\`$1\` is not a PR number." ;;
  esac
  printf '%s\n' "$n"
}

# gp_issue_number <arg> -- the same for an issue number, which may also
# arrive with a trailing comma from a comma-separated list.
gp_issue_number() {
  local n=${1#\#}
  n=${n%,}
  case "$n" in
    '' | *[!0-9]*) gp_usage_error "\`$1\` is not an issue number." ;;
  esac
  printf '%s\n' "$n"
}

# gp_config_value <key> -- one front-matter value from the repo's
# .issues/repo-config.md, with surrounding quotes removed. Only the
# front matter is read: the block between the first two `---` lines.
gp_config_value() {
  local root file value
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=.
  file="$root/.issues/repo-config.md"
  if [ ! -f "$file" ]; then
    gp_fail 4 "This repo has no \`.issues/repo-config.md\`. Run \`/repo-config\` to create one."
  fi
  value=$(awk -v key="$1" '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside && index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$file")
  if [ -z "$value" ]; then
    gp_fail 4 "\`.issues/repo-config.md\` has no \`$1\` in its front matter."
  fi
  printf '%s\n' "$value"
}

# gp_repo_path <suffix> -- a REST path under the current repo, with
# gh's own {owner}/{repo} placeholders left for gh to resolve.
gp_repo_path() {
  printf 'repos/{owner}/{repo}/%s\n' "$1"
}
