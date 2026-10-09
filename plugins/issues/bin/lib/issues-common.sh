# shellcheck shell=bash
# Shared code for the scripts in plugins/issues/bin/: the
# .issues/repo-config.md read and its checks, the repository grammar, the
# wrappers every API call goes through, operand parsing, node-ID and
# field/option ID resolution, the GraphQL documents, the set-slot write paths,
# and the canonical error catalogue. Every script sources this file and
# nothing else, so each of these is written exactly once.
#
# Runs under bash 3.2 and depends on nothing beyond gh, jq and the base
# userland (awk, grep, sed, tr, mktemp): no associative arrays, no ${var,,},
# no mapfile.

ISS_PROGRAM=${0##*/}

# The current repository, empty until iss_current_repo or iss_try_current_repo
# resolves it.
ISS_HOST=
ISS_OWNER=
ISS_REPO=

# The minimum repo-config schema-version these scripts read. A newer file is
# read as this version; its additions are ignored.
readonly ISS_REPO_CONFIG_SCHEMA=6
# The minimum user-config schema-version every user-config read accepts.
readonly ISS_USER_CONFIG_SCHEMA=1

# Path separator inside a flattened config key: option names carry dots,
# slashes and spaces, never a unit separator.
readonly ISS_SEP=$'\037'

ISS_NEWLINE='
'

# ---------------------------------------------------------------------------
# Error catalogue. Each function prints one canonical wording and exits.
# ---------------------------------------------------------------------------

iss_die() {
  printf '%s: %s\n' "$ISS_PROGRAM" "$1" >&2
  exit "${2:-1}"
}

iss_usage_die() {
  iss_die "$1" 2
}

iss_err_file_missing() {
  iss_die "This repo has no \`.issues/repo-config.md\`. Run \`/repo-config\` to create one."
}

iss_err_schema_absent() {
  iss_die "${1:-}This repo's \`.issues/repo-config.md\` predates schema versioning. Run \`/repo-config\` to migrate."
}

iss_err_schema_stale() {
  iss_die "${3:-}This repo's \`.issues/repo-config.md\` is at schema-version \`$1\`; this skill requires \`$2\`. Run \`/repo-config\` to migrate."
}

iss_err_frontmatter_incomplete() {
  iss_die "${3:-}This repo's \`.issues/repo-config.md\` is at schema-version \`$1\` but is missing the canonical field \`$2\`. Run \`/repo-config\` to regenerate it."
}

iss_err_invalid_default() {
  # $1 slot, $2 the configured default, $3 what the slot accepts, $4 message prefix
  iss_die "${4:-}This repo's \`.issues/repo-config.md\` sets \`$1\`'s \`default:\` to \`$2\`, which is not $3. Run \`/repo-config\` to fix it."
}

iss_err_invalid_range() {
  # $1 slot, $2 min, $3 max, $4 message prefix
  iss_die "${4:-}This repo's \`.issues/repo-config.md\` sets \`$1\`'s range to \`[$2, $3]\`, which is not an integer range with \`min:\` at most \`max:\`. Run \`/repo-config\` to fix it."
}

iss_err_jira() {
  iss_die "\`issues: Jira\` is configured, and this script serves only the GitHub backend. Follow the Jira backend path in the skill's SKILL.md instead."
}

iss_err_not_found() {
  # $1 host, $2 owner, $3 repo, $4 number
  iss_die "issue \`#$4\` not found in \`$(iss_repo_name "$1" "$2" "$3")\`"
}

iss_err_repo_not_found() {
  # $1 host, $2 owner, $3 repo
  iss_die "repository \`$2/$3\` not found on \`$1\`"
}

iss_err_no_block() {
  # $1 message prefix
  iss_die "${1:-}no \`github-project:\` block in \`repo-config.md\`; run \`/repo-config\` to add it"
}

iss_err_no_issue_types() {
  # $1 message prefix
  iss_die "${1:-}issue-types map missing from \`github-project:\` in \`repo-config.md\`; run \`/repo-config\` to add it"
}

iss_err_no_target_config() {
  # $1 host, $2 owner, $3 repo
  iss_die "\`$(iss_repo_name "$1" "$2" "$3")\` has no \`.issues/repo-config.md\`, and this verb reads its \`github-project:\` block"
}

iss_err_pull_request() {
  # $1 the pull request, as the operand spelled it or as iss_ref prints it.
  # One exit status whether iss_parse_operand finds the pull request in a URL
  # or iss_try_lookup finds it behind a number.
  iss_die "\`$1\` is a pull request; the issue verbs take issues only"
}

iss_err_type_not_known() {
  iss_die "issue type \`$1\` not in repo's \`github-project.issue-types\`. Known types: \`$2\`"
}

iss_err_not_in_options() {
  iss_die "value \`$1\` is not in \`$2\`'s options. Known options: \`$3\`."
}

iss_err_out_of_range() {
  iss_die "value \`$1\` for \`$2\` is out of range. Expected an integer in \`[$3, $4]\`."
}

iss_err_kind_mismatch() {
  # $1 slot, $2 value, $3 kind, $4 known options
  if [ "$3" = label ]; then
    iss_die "\`/issue-set-$1\` was called with \`$2\`, but this repo's \`$1\` is configured as \`kind: label\`. Use one of: \`$4\`. (Or run \`/repo-config\` to reconfigure.)"
  fi
  iss_die "\`/issue-set-$1\` was called with a number, but this repo's \`$1\` is configured as \`kind: $3\`. Use one of: \`$4\`. (Or run \`/repo-config\` to reconfigure.)"
}

iss_err_stale_project_field() {
  iss_die "project field \`$1\` no longer exists on project \`$2\`; the cached IDs in \`repo-config.md\` may be stale. Run \`/repo-config\` to refresh them."
}

iss_err_stale_issue_field() {
  iss_die "native issue field \`$1\` (\`$2\`) no longer exists on \`$3\`; the cached ID in \`repo-config.md\` may be stale. Run \`/repo-config\` to refresh it."
}

iss_err_cannot_set_issue_field() {
  iss_die "cannot set native issue field \`$1\` on issue \`#$2\`: \`viewerCanSetFields\` is false. You may lack write access, or the native-issue-fields preview may not be enabled for this repository."
}

iss_err_write_not_landed() {
  # $1 what was written, $2 issue reference, $3 expected, $4 what the re-read shows
  iss_die "the write did not land: $1 on issue \`$2\` should read \`$3\`, but a re-read shows \`$4\`"
}

iss_err_missing_scope() {
  # $1 host, $2 scope, $3 gh's error
  iss_die "the gh token for \`$1\` lacks the \`$2\` scope this lookup needs: $3"
}

iss_err_user_config_absent() {
  iss_die "\`$1\` predates user-config schema versioning. Run \`$2\` to migrate."
}

iss_err_user_config_stale() {
  iss_die "\`$1\` is at schema-version \`$3\`; this reader requires \`$ISS_USER_CONFIG_SCHEMA\`. Run \`$2\` to migrate."
}

iss_err_branch_prefix_mode() {
  iss_die "\`.issues/repo-config.md\` sets \`issue-branch-naming-prefix\` to \`$1\`, which is not one of \`none\`, \`initials\` or \`name\`. Run \`/issues:repo-config\` to fix it."
}

iss_err_branch_prefix_unset() {
  iss_die "user-config key \`$1\` is unset in both the repo-level and the user-global user-config. Set it with \`/issues:user-config\` (this repo) or \`/issues:global-user-config\` (this machine)."
}

iss_err_branch_prefix_invalid() {
  # $1 key, $2 the resolved value
  iss_die "user-config key \`$1\` resolves to \`$2\`, which contains \`/\` or whitespace; a branch prefix is a single path component. Set it with \`/issues:user-config\` (this repo) or \`/issues:global-user-config\` (this machine)."
}

# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------

iss_lc() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# A decimal integer, optionally negative.
iss_is_int() {
  case "$1" in
    ''|*[!0-9-]*|?*-*|-) return 1 ;;
  esac
  return 0
}

iss_is_digits() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# Join the lines on stdin with ", ".
iss_join_lines() {
  awk 'BEGIN { s = "" } { s = (NR == 1 ? $0 : s ", " $0) } END { printf "%s", s }'
}

iss_require_tools() {
  command -v gh >/dev/null 2>&1 || iss_die "\`gh\` is not on PATH"
  command -v jq >/dev/null 2>&1 || iss_die "\`jq\` is not on PATH"
}

# ---------------------------------------------------------------------------
# Repo-config read.
#
# iss_parse_config_text <text> [<message-prefix>] parses a repo-config's text
# and sets:
#   ISS_ISSUES, ISS_LINK_PREFIX,      front-matter values
#   ISS_BRANCH_PREFIX_MODE
#   ISS_GP                            the github-project: block flattened to
#                                     one "<path><TAB><value>" line per node,
#                                     path components joined by ISS_SEP
#   ISS_HAS_GP                        1 when the block is present, else 0
# It aborts with the canonical repo-config messages, with the fixed Jira
# message when the tracker is Jira — before any gh call — and on a slot the
# config gets wrong (iss_check_slots).
#
# iss_validate_config_text <text> runs the same checks without the Jira
# refusal, and runs iss_check_slots over a jira: block as well: it is what
# repo-config-write accepts before writing a file, and a Jira config is one it
# writes.
# ---------------------------------------------------------------------------

# iss_frontmatter <text>: print the lines between the opening "---" and the
# next one, skipping blank lines before the opener. Returns non-zero when the
# text opens with anything else or the block never closes.
iss_frontmatter() {
  awk '
    !started { if ($0 ~ /^[ \t]*$/) next; if ($0 == "---") { started = 1; next } exit 2 }
    $0 == "---" { closed = 1; exit 0 }
    { print }
    END { if (!closed) exit 2 }
  ' <<EOF
$1
EOF
}

# iss_body <text>: print everything after the front matter's closing "---".
iss_body() {
  awk '
    !started { if ($0 ~ /^[ \t]*$/) next; if ($0 == "---") { started = 1; next } }
    started == 1 { if ($0 == "---") { started = 2 }; next }
    started == 2 { print }
  ' <<EOF
$1
EOF
}

# iss_flatten_block <block> <body>: flatten a column-0 block of a repo-config
# body -- github-project: or jira: -- with every path rooted at <block>. The
# block starts at a column-0 "<block>:" line and runs to the next column-0
# non-blank line. Mappings nest by indentation; a flow list "[a, b]" or a
# block list of "- a" lines becomes an identity map (a -> a) so every option
# list reads the same way.
iss_flatten_block() {
  awk -v SEP="$ISS_SEP" -v BLK="$1" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unquote(s) {
      s = trim(s)
      if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) return substr(s, 2, length(s) - 2)
      sub(/[ \t]+#.*$/, "", s)
      return trim(s)
    }
    function path(   p, i) {
      p = BLK
      for (i = 1; i <= sp; i++) p = p SEP skey[i]
      return p
    }
    function emit(p, v) { print p "\t" v }
    function emit_list(p, body,   n, parts, i, item) {
      body = substr(body, 2, length(body) - 2)
      n = split(body, parts, ",")
      for (i = 1; i <= n; i++) {
        item = unquote(parts[i])
        if (item != "") emit(p SEP item, item)
      }
    }
    BEGIN { inblk = 0; sp = 0 }
    $0 ~ "^" BLK ":[ \t]*$" { inblk = 1; sp = 0; print BLK "\t"; next }
    !inblk { next }
    /^[ \t]*$/ { next }
    /^[^ \t]/ { inblk = 0; next }
    /^[ \t]*#/ { next }
    {
      match($0, /^ */); ind = RLENGTH; line = substr($0, ind + 1)
      while (sp > 0 && sind[sp] >= ind) sp--
      if (line ~ /^- /) {
        item = unquote(substr(line, 3))
        emit(path() SEP item, item)
        next
      }
      if (substr(line, 1, 1) == "\"") {
        rest = substr(line, 2); q = index(rest, "\"")
        key = substr(rest, 1, q - 1); rest = substr(rest, q + 1)
        c = index(rest, ":"); rest = substr(rest, c + 1)
      } else {
        c = index(line, ":")
        if (c == 0) next
        key = trim(substr(line, 1, c - 1)); rest = substr(line, c + 1)
      }
      val = trim(rest)
      sp++; skey[sp] = key; sind[sp] = ind
      if (val ~ /^\[.*\]$/) { emit(path(), ""); emit_list(path(), val); next }
      emit(path(), unquote(val))
    }
  ' <<EOF
$2
EOF
}

# iss_fm_get <front-matter> <key>: print a top-level key's value, unquoted,
# with a trailing "# comment" stripped from an unquoted value. Returns 1 when
# the key is absent.
iss_fm_get() {
  awk -v k="$2" '
    {
      c = index($0, ":"); if (c == 0) next
      key = substr($0, 1, c - 1); if (key != k) next
      v = substr($0, c + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      else sub(/[ \t]+#.*$/, "", v)
      print v; found = 1; exit
    }
    END { exit found ? 0 : 1 }
  ' <<EOF
$1
EOF
}

iss_parse_config_text() {
  iss_config_frontmatter "$1" "${2:-}"
  [ "$ISS_ISSUES" != Jira ] || iss_err_jira
  iss_config_github_project "$1" "${2:-}"
}

iss_validate_config_text() {
  iss_config_frontmatter "$1" "${2:-}"
  iss_config_github_project "$1" "${2:-}"
  iss_config_jira "$1" "${2:-}"
}

# iss_config_frontmatter <text> [<message-prefix>]: the schema-version and
# canonical-field checks; sets ISS_ISSUES, ISS_LINK_PREFIX and
# ISS_BRANCH_PREFIX_MODE.
iss_config_frontmatter() {
  local text=$1 prefix=${2:-} fm version field
  if ! fm=$(iss_frontmatter "$text"); then
    iss_err_schema_absent "$prefix"
  fi
  version=$(iss_fm_get "$fm" schema-version) || iss_err_schema_absent "$prefix"
  iss_is_digits "$version" || iss_err_schema_absent "$prefix"
  if [ "$version" -lt "$ISS_REPO_CONFIG_SCHEMA" ]; then
    iss_err_schema_stale "$version" "$ISS_REPO_CONFIG_SCHEMA" "$prefix"
  fi
  for field in source-control issues issue-link-prefix default-issue-source-branch \
               default-pr-target-branch issue-branch-naming-prefix; do
    iss_fm_get "$fm" "$field" >/dev/null || iss_err_frontmatter_incomplete "$version" "$field" "$prefix"
  done
  ISS_ISSUES=$(iss_fm_get "$fm" issues)
  ISS_LINK_PREFIX=$(iss_fm_get "$fm" issue-link-prefix)
  ISS_BRANCH_PREFIX_MODE=$(iss_fm_get "$fm" issue-branch-naming-prefix)
  case "$ISS_ISSUES" in
    GitHub|Jira) ;;
    *) iss_die "${prefix}unsupported \`issues:\` value \`$ISS_ISSUES\` in \`.issues/repo-config.md\`" ;;
  esac
}

# iss_config_github_project <text> [<message-prefix>]: flatten the
# github-project: block into ISS_GP and ISS_HAS_GP, and check its slots.
iss_config_github_project() {
  ISS_GP=$(iss_flatten_block github-project "$(iss_body "$1")")
  if [ -n "$ISS_GP" ]; then ISS_HAS_GP=1; else ISS_HAS_GP=0; fi
  [ "$ISS_HAS_GP" = 0 ] || iss_check_slots "${2:-}"
}

# iss_config_jira <text> [<message-prefix>]: check the jira: block's slots.
# The accessors read ISS_GP below ISS_CFG_ROOT, so both are shadowed here and
# the github-project: block's flattening survives the call.
iss_config_jira() {
  local ISS_GP ISS_CFG_ROOT=jira
  ISS_GP=$(iss_flatten_block jira "$(iss_body "$1")")
  [ -z "$ISS_GP" ] || iss_check_slots "${2:-}"
}

# iss_check_slots [<message-prefix>]: abort when a kind: number slot's range
# makes no sense, or when a slot's default: is a value the slot itself would
# refuse -- not an integer in min/max for kind: number, not among the options
# for a kind that carries them -- so no script recommends or applies it. A
# slot of kind skip, or of a kind not listed here, is left to the verbs that
# read it.
iss_check_slots() {
  local prefix=${1:-} slot kind value
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    value=$(iss_cfg_get fields "$slot" default 2>/dev/null) || value=
    kind=$(iss_slot_kind "$slot")
    case "$kind" in
      number)
        if ! iss_number_check "$slot" "$value" "$prefix" && [ -n "$value" ]; then
          iss_err_invalid_default "$slot" "$value" "an integer in \`[$ISS_NUM_MIN, $ISS_NUM_MAX]\`" "$prefix"
        fi
        ;;
      single-select|label|issue-field|status|custom-field)
        [ -z "$value" ] || iss_resolve_name all "$value" fields "$slot" options >/dev/null ||
          iss_err_invalid_default "$slot" "$value" "one of its options: \`$(iss_slot_options "$slot")\`" "$prefix"
        ;;
    esac
  done <<EOF
$(iss_cfg_children fields)
EOF
}

# iss_number_check <slot> <value> [<message-prefix>]: whether <value> is an
# integer within the kind: number slot's min:/max:, either of which may be
# absent. Aborts, naming the slot, when the bounds themselves make no sense:
# a bound that is not an integer, which test(1) would reject with an error
# that reads as "in range", or min: above max:. Sets ISS_NUM_MIN and
# ISS_NUM_MAX to the bounds as a message prints them, "-inf" and "inf" for an
# absent one.
iss_number_check() {
  local slot=$1 value=$2 min max
  min=$(iss_cfg_get fields "$slot" min 2>/dev/null) || min=
  max=$(iss_cfg_get fields "$slot" max 2>/dev/null) || max=
  ISS_NUM_MIN=${min:--inf}
  ISS_NUM_MAX=${max:-inf}
  if { [ -n "$min" ] && ! iss_is_int "$min"; } ||
     { [ -n "$max" ] && ! iss_is_int "$max"; } ||
     { [ -n "$min" ] && [ -n "$max" ] && [ "$min" -gt "$max" ]; }; then
    iss_err_invalid_range "$slot" "$ISS_NUM_MIN" "$ISS_NUM_MAX" "${3:-}"
  fi
  iss_is_int "$value" || return 1
  [ -z "$min" ] || [ "$value" -ge "$min" ] || return 1
  [ -z "$max" ] || [ "$value" -le "$max" ]
}

# iss_load_config [frontmatter-only]: read the current repo's
# .issues/repo-config.md. With frontmatter-only, only iss_config_frontmatter's
# checks run, so a Jira config is read rather than refused.
iss_load_config() {
  ISS_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || iss_die "not inside a git working tree"
  [ -f "$ISS_REPO_ROOT/.issues/repo-config.md" ] || iss_err_file_missing
  if [ "${1:-}" = frontmatter-only ]; then
    iss_config_frontmatter "$(cat "$ISS_REPO_ROOT/.issues/repo-config.md")"
  else
    iss_parse_config_text "$(cat "$ISS_REPO_ROOT/.issues/repo-config.md")"
  fi
}

# iss_load_target_config <host> <owner> <repo>: read a target repo's
# .issues/repo-config.md from its default branch and parse it as
# iss_parse_config_text does, each message prefixed with the target. Reads
# nothing from the current repo's repo-config. Returns 1 when the target has
# no repo-config, with ISS_HAS_GP=0 so every slot reads as unconfigured.
iss_load_target_config() {
  local errf content text err name
  iss_require_tools
  name=$(iss_repo_name "$1" "$2" "$3")
  errf=$(mktemp "${TMPDIR:-/tmp}/$ISS_PROGRAM.XXXXXX")
  if content=$(iss_rest "$1" "repos/$2/$3/contents/.issues/repo-config.md" --jq .content 2>"$errf"); then
    rm -f "$errf"
    text=$(printf '%s' "$content" | tr -d '\n' | base64 --decode) ||
      iss_die "could not decode \`$name\`'s \`.issues/repo-config.md\`"
    iss_parse_config_text "$text" "target repo \`$name\`: "
  elif grep -q 'HTTP 404' "$errf"; then
    rm -f "$errf"
    ISS_HAS_GP=0
    ISS_GP=
    ISS_LINK_PREFIX='#'
    return 1
  else
    err=$(cat "$errf"); rm -f "$errf"
    iss_die "could not read \`$name\`'s \`.issues/repo-config.md\`: $err"
  fi
}

# ---------------------------------------------------------------------------
# Repositories. A repository is a host, an owner and a name, and every gh
# call that names a repository names its host too: gh resolves a host-less
# name on its own default host, whatever host the checkout's remote is on. An
# empty host stands for that default host; it is what a repository named
# owner/repo gets where there is no current repository.
# ---------------------------------------------------------------------------

# iss_split_url <url>: split https://host/owner/repo, a trailing / ignored,
# into URL_HOST, URL_OWNER and URL_REPO. Returns 1 on any other shape.
iss_split_url() {
  local rest=${1%/}
  case "$rest" in https://*) rest=${rest#https://} ;; *) return 1 ;; esac
  case "$rest" in */*/*/*|*//*|/*|*/) return 1 ;; ?*/?*/?*) ;; *) return 1 ;; esac
  URL_HOST=${rest%%/*}
  rest=${rest#*/}
  URL_OWNER=${rest%/*}
  URL_REPO=${rest#*/}
}

# iss_view_current_repo: the one `gh repo view` call, which takes the host
# from the checkout's remote. Sets URL_HOST, URL_OWNER and URL_REPO; returns 1
# when gh cannot resolve the repository, gh's stderr passed through.
iss_view_current_repo() {
  local url
  url=$(gh repo view --json url --jq .url) && iss_split_url "$url"
}

# iss_current_repo: resolve the current repository. Sets ISS_HOST, ISS_OWNER
# and ISS_REPO, and aborts when it cannot.
iss_current_repo() {
  iss_view_current_repo ||
    iss_die "could not resolve the current GitHub repository with \`gh repo view\`"
  ISS_CURRENT_TRIED=yes
  ISS_HOST=$URL_HOST
  ISS_OWNER=$URL_OWNER
  ISS_REPO=$URL_REPO
}

# iss_try_current_repo: the same, for a verb that also runs where there is no
# current repository. Outside a git checkout, or where gh cannot resolve the
# checkout's repository, it leaves ISS_HOST, ISS_OWNER and ISS_REPO empty and
# returns 1; outside a checkout it makes no gh call. Once either function
# has run, this one makes no gh call and returns the answer already held.
iss_try_current_repo() {
  if [ -n "${ISS_CURRENT_TRIED:-}" ]; then
    [ -n "$ISS_OWNER" ]
    return
  fi
  ISS_CURRENT_TRIED=yes
  ISS_HOST=
  ISS_OWNER=
  ISS_REPO=
  git rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  iss_view_current_repo 2>/dev/null || return 1
  ISS_HOST=$URL_HOST
  ISS_OWNER=$URL_OWNER
  ISS_REPO=$URL_REPO
}

# iss_valid_name <name>: whether <name> is a repository name GitHub allows: 1
# to 100 ASCII letters, digits, ".", "-" and "_", any of them first.
iss_valid_name() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 100 ]
}

# iss_valid_owner <owner>: whether <owner> is an owner GitHub allows: 1 to 39
# ASCII letters, digits and "-", not starting with "-" and with no "--".
iss_valid_owner() {
  case "$1" in ''|-*|*--*|*[!A-Za-z0-9-]*) return 1 ;; esac
  [ "${#1}" -le 39 ]
}

# iss_valid_host <host>: whether <host> is a DNS hostname: at most 253
# characters of "."-separated labels, each 1 to 63 ASCII letters, digits and
# "-", neither starting nor ending with "-".
iss_valid_host() {
  local rest=$1. label
  [ "${#1}" -le 253 ] || return 1
  while [ -n "$rest" ]; do
    label=${rest%%.*}
    case "$label" in ''|-*|*-|*[!A-Za-z0-9-]*) return 1 ;; esac
    [ "${#label}" -le 63 ] || return 1
    rest=${rest#*.}
  done
}

# iss_valid_path <path>: whether each part of repo, owner/repo or
# host/owner/repo is valid for its place, by iss_valid_host, iss_valid_owner
# and iss_valid_name. gp_parse_pr in the github-prs plugin validates by the
# same rules.
iss_valid_path() {
  case "$1" in
    */*/*/*) return 1 ;;
    */*/*) iss_valid_host "${1%%/*}" && iss_valid_path "${1#*/}" ;;
    */*) iss_valid_owner "${1%/*}" && iss_valid_name "${1#*/}" ;;
    *) iss_valid_name "$1" ;;
  esac
}

# iss_parse_repo <reference>: the one parser of the repository grammar. Sets
# RP_HOST, RP_OWNER and RP_REPO from
#   repo                     that repo under the current repository's owner,
#                            on its host
#   owner/repo               that repository, on the current repository's host
#   host/owner/repo          that repository, on that host
#   https://host/owner/repo  the same as host/owner/repo; a trailing / is
#                            ignored
# Each part is checked by iss_valid_path. A malformed reference is a
# usage error before any gh call; a form without a host resolves the current
# repository with iss_try_current_repo. With no current repository, repo is a
# usage error and owner/repo gets the empty host.
iss_parse_repo() {
  local ref=$1 rest bad
  bad="\`$ref\` is not a repository (expected repo, owner/repo, host/owner/repo or https://host/owner/repo)"
  case "$ref" in
    *://*)
      { iss_split_url "$ref" && iss_valid_path "$URL_HOST/$URL_OWNER/$URL_REPO"; } || iss_usage_die "$bad"
      RP_HOST=$URL_HOST
      RP_OWNER=$URL_OWNER
      RP_REPO=$URL_REPO
      return 0
      ;;
  esac
  rest=${ref%/}
  case "$rest" in ''|*//*|/*|*/*/*/*) iss_usage_die "$bad" ;; esac
  iss_valid_path "$rest" || iss_usage_die "$bad"
  case "$rest" in */*/*) ;; *) iss_try_current_repo || : ;; esac
  case "$rest" in
    */*/*)
      RP_HOST=${rest%%/*}
      rest=${rest#*/}
      RP_OWNER=${rest%/*}
      RP_REPO=${rest#*/}
      ;;
    */*)
      RP_HOST=$ISS_HOST
      RP_OWNER=${rest%/*}
      RP_REPO=${rest#*/}
      ;;
    *)
      [ -n "$ISS_OWNER" ] ||
        iss_usage_die "\`$ref\` names a repository under the current repository's owner, and there is no current repository"
      RP_HOST=$ISS_HOST
      RP_OWNER=$ISS_OWNER
      RP_REPO=$rest
      ;;
  esac
}

# iss_same_host <host>: whether <host> is the current repository's host.
iss_same_host() {
  [ "$(iss_lc "$1")" = "$(iss_lc "$ISS_HOST")" ]
}

# iss_same_repo <host> <owner> <repo> <host> <owner> <repo>: whether the two
# name one repository; GitHub matches each part without regard to case.
iss_same_repo() {
  [ "$(iss_lc "$1/$2/$3")" = "$(iss_lc "$4/$5/$6")" ]
}

# iss_repo_arg <host> <owner> <repo>: the value of a `gh issue` call's
# --repo, host/owner/repo, or owner/repo for gh's default host.
iss_repo_arg() {
  if [ -n "$1" ]; then printf '%s/%s/%s' "$1" "$2" "$3"; else printf '%s/%s' "$2" "$3"; fi
}

# iss_repo_name <host> <owner> <repo>: a repository as a message names it,
# owner/repo, with its host in front when that is not the current one.
iss_repo_name() {
  if iss_same_host "$1"; then printf '%s/%s' "$2" "$3"; else printf '%s/%s/%s' "$1" "$2" "$3"; fi
}

# iss_init <operand>...: the common opening of every verb that acts on
# existing issues -- tools, the working tree, and the current repository. Only
# the repo-config of an operand's own repository governs the verb on it, so the
# current repository's is read here, before any gh call, only when an operand
# names no repository of its own (iss_names_repo). An operand that does name
# one is gated by iss_check_repo or iss_operand_config once it is parsed.
iss_init() {
  local op
  iss_require_tools
  ISS_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || iss_die "not inside a git working tree"
  iss_peek_link_prefix
  for op in "$@"; do
    iss_names_repo "$op" && continue
    iss_load_config
    break
  done
  iss_current_repo
}

# iss_peek_link_prefix: set ISS_LINK_PREFIX from the current repo-config's
# front matter without iss_load_config's checks, so that iss_names_repo can
# tell a prefixed N apart before any repo-config is gated on. It is '#' when
# the file or the key is absent.
iss_peek_link_prefix() {
  local fm
  ISS_LINK_PREFIX='#'
  [ -f "$ISS_REPO_ROOT/.issues/repo-config.md" ] || return 0
  fm=$(iss_frontmatter "$(cat "$ISS_REPO_ROOT/.issues/repo-config.md")") || return 0
  ISS_LINK_PREFIX=$(iss_fm_get "$fm" issue-link-prefix) || ISS_LINK_PREFIX='#'
}

# iss_names_repo <operand>: whether the operand names a repository of its own
# -- a URL, or a repository part before a # -- rather than being N or #N, with
# or without ISS_LINK_PREFIX. A malformed operand with neither names none.
iss_names_repo() {
  local num=${1#"$ISS_LINK_PREFIX"}
  num=${num#'#'}
  iss_is_digits "$num" && return 1
  case "$1" in https://*|?*'#'*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# Flattened-config accessors. Arguments are path components below
# ISS_CFG_ROOT -- github-project unless iss_config_jira sets it -- e.g.
# iss_cfg_get fields status kind.
# ---------------------------------------------------------------------------

iss_cfg_path() {
  local p=${ISS_CFG_ROOT:-github-project} c
  for c in "$@"; do p="$p$ISS_SEP$c"; done
  printf '%s' "$p"
}

# Print the value at a path; returns 1 when the path is absent.
iss_cfg_get() {
  local p
  p=$(iss_cfg_path "$@")
  awk -F'\t' -v p="$p" '$1 == p { print substr($0, length($1) + 2); found = 1; exit } END { exit found ? 0 : 1 }' <<EOF
$ISS_GP
EOF
}

# Print the direct child keys of a path, one per line, in file order.
iss_cfg_children() {
  local p
  p=$(iss_cfg_path "$@")
  awk -F'\t' -v p="$p" -v SEP="$ISS_SEP" '
    index($1, p SEP) == 1 {
      rest = substr($1, length(p) + 2)
      if (index(rest, SEP) == 0) print rest
    }
  ' <<EOF
$ISS_GP
EOF
}

# The kind of a slot, or "skip" when the slot is absent from fields:.
iss_slot_kind() {
  iss_cfg_get fields "$1" kind 2>/dev/null || printf 'skip'
}

# iss_resolve_name <all|skip-default> <name> <path...>: resolve a name
# against the keys under a path, case-insensitively. Prints the canonical
# key; returns non-zero when nothing matches. With skip-default, the key
# "default" never matches.
iss_resolve_name() {
  local mode=$1 want key
  shift
  want=$(iss_lc "$1")
  shift
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [ "$mode" = skip-default ] && [ "$key" = default ] && continue
    if [ "$(iss_lc "$key")" = "$want" ]; then
      printf '%s' "$key"
      return 0
    fi
  done <<EOF
$(iss_cfg_children "$@")
EOF
  return 1
}

# ---------------------------------------------------------------------------
# Operands.
# ---------------------------------------------------------------------------

# iss_parse_operand <operand> [<host> <owner> <repo>]: the one parser of the
# issue-reference grammar. Sets OP_HOST, OP_OWNER, OP_REPO and OP_NUMBER from
#   N, #N                          issue N in the given repository, or in the
#                                  current one when none is given; N may
#                                  carry the repo-config's issue-link-prefix
#   <repository>#N                 issue N in the repository, its part before
#                                  the last # in any form iss_parse_repo takes
#   https://host/owner/repo/issues/N
#                                  the same as host/owner/repo#N; a trailing /
#                                  is ignored
# so every reference iss_ref prints is accepted back. A pull request's URL is
# refused with iss_err_pull_request, and any other malformed operand is a usage
# error, both before any gh call.
iss_parse_operand() {
  local op=$1 num rest kind bad
  bad="\`$op\` is not an issue reference (expected N, #N, repo#N, owner/repo#N, host/owner/repo#N or https://host/owner/repo/issues/N)"
  num=${op#"$ISS_LINK_PREFIX"}
  num=${num#'#'}
  if iss_is_digits "$num"; then
    OP_HOST=${2-$ISS_HOST}
    OP_OWNER=${3-$ISS_OWNER}
    OP_REPO=${4-$ISS_REPO}
    OP_NUMBER=$num
    return 0
  fi
  case "$op" in
    *'#'*)
      num=${op##*'#'}
      rest=${op%'#'*}
      { [ -n "$rest" ] && iss_is_digits "$num"; } || iss_usage_die "$bad"
      iss_parse_repo "$rest"
      ;;
    https://*)
      rest=${op%/}
      num=${rest##*/}
      rest=${rest%/*}
      kind=${rest##*/}
      rest=${rest%/*}
      { iss_is_digits "$num" && iss_split_url "$rest" && iss_valid_path "$URL_HOST/$URL_OWNER/$URL_REPO"; } ||
        iss_usage_die "$bad"
      case "$kind" in
        issues) ;;
        pull) iss_err_pull_request "$op" ;;
        *) iss_usage_die "$bad" ;;
      esac
      RP_HOST=$URL_HOST
      RP_OWNER=$URL_OWNER
      RP_REPO=$URL_REPO
      ;;
    *) iss_usage_die "$bad" ;;
  esac
  OP_HOST=$RP_HOST
  OP_OWNER=$RP_OWNER
  OP_REPO=$RP_REPO
  OP_NUMBER=$num
}

# iss_operand <operand>: iss_parse_operand, then iss_check_repo on the
# operand's repository.
iss_operand() {
  iss_parse_operand "$1"
  iss_check_repo "$OP_HOST" "$OP_OWNER" "$OP_REPO"
}

# iss_check_repo <host> <owner> <repo> [<host> <owner> <repo>]: gate the verb
# on the first repository's repo-config. The second repository, when given, is
# one whose repo-config the verb has read already, and passes. Without it, the
# current repository's is read with iss_load_config. Any other repository's
# is read with iss_load_target_config, aborting wherever that does: on a
# repo-config it cannot read or that fails validation, and with the fixed Jira
# message under issues: Jira. That read runs in a subshell, so the repo-config
# the verb itself reads is left as it was. A repository it finds no repo-config
# in passes; iss_load_config instead aborts on a missing one.
iss_check_repo() {
  if [ "$#" -eq 6 ]; then
    iss_same_repo "$@" && return 0
  elif iss_same_repo "$1" "$2" "$3" "$ISS_HOST" "$ISS_OWNER" "$ISS_REPO"; then
    iss_load_config
    return 0
  fi
  (iss_load_target_config "$1" "$2" "$3" || :) || exit 1
}

# iss_operand_config <host> <owner> <repo>: make the repo-config of the
# operand's repository the one the accessors read — the local file for the
# current repository, the repository's own, through iss_load_target_config,
# for any other — and set ISS_CFG_PREFIX to the message prefix naming that
# other repository, empty for the current one. Returns 1 when the other
# repository has no repo-config.
iss_operand_config() {
  if iss_same_repo "$1" "$2" "$3" "$ISS_HOST" "$ISS_OWNER" "$ISS_REPO"; then
    ISS_CFG_PREFIX=
    iss_load_config
  else
    ISS_CFG_PREFIX="target repo \`$(iss_repo_name "$1" "$2" "$3")\`: "
    iss_load_target_config "$1" "$2" "$3"
  fi
}

# iss_operand_board_config: iss_operand_config for OP_HOST, OP_OWNER and
# OP_REPO, for a verb that writes a project-board slot or the issue type, so
# it aborts naming the repository when that has no repo-config or no
# github-project: block.
iss_operand_board_config() {
  iss_operand_config "$OP_HOST" "$OP_OWNER" "$OP_REPO" || iss_err_no_target_config "$OP_HOST" "$OP_OWNER" "$OP_REPO"
  [ "$ISS_HAS_GP" = 1 ] || iss_err_no_block "$ISS_CFG_PREFIX"
}

# iss_ref <host> <owner> <repo> <number>: an issue reference in the shortest
# form the repository grammar resolves back to the same issue: #N in the
# current repository, repo#N under its owner on its host, owner/repo#N on its
# host, host/owner/repo#N on another.
iss_ref() {
  if ! iss_same_host "$1"; then
    printf '%s/%s/%s#%s' "$1" "$2" "$3" "$4"
  elif [ "$(iss_lc "$2")" != "$(iss_lc "$ISS_OWNER")" ]; then
    printf '%s/%s#%s' "$2" "$3" "$4"
  elif [ "$(iss_lc "$3")" != "$(iss_lc "$ISS_REPO")" ]; then
    printf '%s#%s' "$3" "$4"
  else
    printf '#%s' "$4"
  fi
}

# iss_ref_nwo <host> <nameWithOwner> <number>: the same, from the
# nameWithOwner a GraphQL read on <host> returns.
iss_ref_nwo() {
  iss_ref "$1" "${2%%/*}" "${2#*/}" "$3"
}

# ---------------------------------------------------------------------------
# The gh api wrappers, the only place this plugin calls `gh api`. Each takes
# the host of the repository the call acts on first and passes it as
# --hostname; an empty host leaves the call on gh's default host.
# ---------------------------------------------------------------------------

# iss_rest <host> <gh api args...>: a REST call, stdout and stderr passed
# through. Returns gh's exit status.
iss_rest() {
  local host=$1
  shift
  if [ -n "$host" ]; then
    gh api --hostname "$host" "$@"
  else
    gh api "$@"
  fi
}

# iss_gql <host> <gh api graphql args...>: a GraphQL call; sets ISS_GQL_OUT
# and ISS_GQL_ERR. Returns gh's exit status.
iss_gql() {
  local host=$1 errf rc
  shift
  errf=$(mktemp "${TMPDIR:-/tmp}/issues-gql.XXXXXX")
  if [ -n "$host" ]; then
    ISS_GQL_OUT=$(gh api --hostname "$host" graphql "$@" 2>"$errf")
  else
    ISS_GQL_OUT=$(gh api graphql "$@" 2>"$errf")
  fi
  rc=$?
  ISS_GQL_ERR=$(cat "$errf")
  rm -f "$errf"
  return $rc
}

iss_gql_fail() {
  iss_die "GitHub GraphQL call failed: ${ISS_GQL_ERR:-$ISS_GQL_OUT}"
}

# iss_lookup <host> <owner> <repo> <number> <selection>: fetch one issue with
# the given field selection, whose connections are spelled by iss_conn, and
# page each of them to its end. Sets ISS_ISSUE to the issue object's JSON.
# Aborts with the catalogue's not-found wording when the number names nothing,
# and with its pull-request wording when it names a pull request.
iss_lookup() {
  iss_try_lookup "$@" || iss_err_not_found "$1" "$2" "$3" "$4"
}

# Same as iss_lookup, but returns 1 instead of aborting on not-found. The read
# goes through issueOrPullRequest, since issue(number:) reads a pull request's
# number as not-found too.
iss_try_lookup() {
  local doc
  doc="query(\$owner: String!, \$repo: String!, \$number: Int!) {
  repository(owner: \$owner, name: \$repo) {
    issueOrPullRequest(number: \$number) { __typename ... on Issue { $5 } }
  }
}"
  if ! iss_gql "$1" -f query="$doc" -f owner="$2" -f repo="$3" -F number="$4"; then
    if [ "$(printf '%s' "$ISS_GQL_OUT" | jq -r '.data.repository.issueOrPullRequest == null' 2>/dev/null)" = true ]; then
      return 1
    fi
    iss_gql_fail
  fi
  ISS_ISSUE=$(printf '%s' "$ISS_GQL_OUT" | jq -c '.data.repository.issueOrPullRequest')
  [ "$ISS_ISSUE" != null ] || return 1
  [ "$(iss_jq .__typename)" = Issue ] || iss_err_pull_request "$(iss_ref "$1" "$2" "$3" "$4")"
  ISS_ISSUE=$(printf '%s' "$ISS_ISSUE" | jq -c 'del(.__typename)')
  iss_page_rest "$1" "$2" "$3" "$4"
}

# iss_page_rest <host> <owner> <repo> <number>: page every connection in
# ISS_ISSUE, and every project item's fieldValues, to its end, appending each
# later page's nodes, so no read sees a truncated list.
iss_page_rest() {
  local ref conn doc cursor page i item
  ref=$(iss_ref "$1" "$2" "$3" "$4")
  for conn in $(iss_jq 'to_entries[] | select((.value | type) == "object" and .value.pageInfo.hasNextPage? == true) | .key'); do
    doc="query(\$owner: String!, \$repo: String!, \$number: Int!, \$after: String!) {
  repository(owner: \$owner, name: \$repo) {
    issue(number: \$number) { $(iss_conn "$conn" after) }
  }
}"
    while [ "$(iss_jq --arg c "$conn" ".[\$c].pageInfo.hasNextPage")" = true ]; do
      cursor=$(iss_jq --arg c "$conn" ".[\$c].pageInfo.endCursor")
      iss_gql "$1" -f query="$doc" -f owner="$2" -f repo="$3" -F number="$4" -f after="$cursor" || iss_gql_fail
      page=$(printf '%s' "$ISS_GQL_OUT" | jq -c --arg c "$conn" '.data.repository.issue[$c] // empty')
      [ -n "$page" ] || iss_die "the next page of \`$conn\` on issue \`$ref\` came back empty"
      ISS_ISSUE=$(printf '%s' "$ISS_ISSUE" |
        jq -c --arg c "$conn" --argjson p "$page" '.[$c].nodes += $p.nodes | .[$c].pageInfo = $p.pageInfo')
    done
  done
  doc="query(\$item: ID!, \$after: String!) {
  node(id: \$item) { ... on ProjectV2Item { $(iss_conn fieldValues after) } }
}"
  for i in $(iss_jq '.projectItems.nodes // [] | to_entries[] | select(.value.fieldValues.pageInfo.hasNextPage == true) | .key'); do
    item=$(iss_jq --argjson i "$i" ".projectItems.nodes[\$i].id")
    while [ "$(iss_jq --argjson i "$i" ".projectItems.nodes[\$i].fieldValues.pageInfo.hasNextPage")" = true ]; do
      cursor=$(iss_jq --argjson i "$i" ".projectItems.nodes[\$i].fieldValues.pageInfo.endCursor")
      iss_gql "$1" -f query="$doc" -f item="$item" -f after="$cursor" || iss_gql_fail
      page=$(printf '%s' "$ISS_GQL_OUT" | jq -c '.data.node.fieldValues // empty')
      [ -n "$page" ] || iss_die "the next page of a project item's field values on issue \`$ref\` came back empty"
      ISS_ISSUE=$(printf '%s' "$ISS_ISSUE" | jq -c --argjson i "$i" --argjson p "$page" \
        '.projectItems.nodes[$i].fieldValues.nodes += $p.nodes | .projectItems.nodes[$i].fieldValues.pageInfo = $p.pageInfo')
    done
  done
}

# iss_jq <jq args...>: run `jq -r` over whatever ISS_ISSUE currently holds.
iss_jq() {
  printf '%s' "$ISS_ISSUE" | jq -r "$@"
}

# The page size of every connection read; 100 is GitHub's maximum.
readonly ISS_PAGE_SIZE=100

readonly ISS_FIELD_VALUE_NODES='__typename
    ... on ProjectV2ItemFieldNumberValue { field { ... on ProjectV2FieldCommon { id } } number }
    ... on ProjectV2ItemFieldSingleSelectValue { field { ... on ProjectV2FieldCommon { id } } name optionId }'

# iss_conn_nodes <connection>: the node selection read from each connection.
iss_conn_nodes() {
  case "$1" in
    labels) printf 'name' ;;
    assignees) printf 'login' ;;
    subIssues|blockedBy|blocking) printf 'id number title repository { nameWithOwner }' ;;
    projectItems) printf 'id project { id } %s' "$(iss_conn fieldValues)" ;;
    fieldValues) printf '%s' "$ISS_FIELD_VALUE_NODES" ;;
    issueFieldValues)
      printf '%s' '__typename
    ... on IssueFieldSingleSelectValue { name optionId field { ... on IssueFieldSingleSelect { id } } }'
      ;;
    *) iss_die "no node selection is defined for the connection \`$1\`" ;;
  esac
}

# iss_conn <connection> [after]: the connection's selection, carrying the
# pageInfo iss_page_rest follows. With "after", it reads the page after $after.
iss_conn() {
  local args="first: $ISS_PAGE_SIZE"
  [ "${2:-}" = after ] && args="$args, after: \$after"
  printf '%s(%s) {\n  pageInfo { hasNextPage endCursor }\n  nodes {\n    %s\n  }\n}' "$1" "$args" "$(iss_conn_nodes "$1")"
}

ISS_SEL_PROJECT_ITEMS=$(iss_conn projectItems)
ISS_SEL_ISSUE_FIELDS=$(iss_conn issueFieldValues)
ISS_SEL_LABELS=$(iss_conn labels)
readonly ISS_SEL_PROJECT_ITEMS ISS_SEL_ISSUE_FIELDS ISS_SEL_LABELS

readonly ISS_DOC_ADD_PROJECT_ITEM="mutation(\$projectId: ID!, \$contentId: ID!) {
  addProjectV2ItemById(input: { projectId: \$projectId, contentId: \$contentId }) { item { id } }
}"

readonly ISS_DOC_SET_NUMBER="mutation(\$projectId: ID!, \$itemId: ID!, \$fieldId: ID!, \$value: Float!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: \$projectId, itemId: \$itemId, fieldId: \$fieldId, value: { number: \$value }
  }) { projectV2Item { id } }
}"

readonly ISS_DOC_SET_SINGLE_SELECT="mutation(\$projectId: ID!, \$itemId: ID!, \$fieldId: ID!, \$optionId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: \$projectId, itemId: \$itemId, fieldId: \$fieldId, value: { singleSelectOptionId: \$optionId }
  }) { projectV2Item { id } }
}"

readonly ISS_DOC_SET_ISSUE_FIELD="mutation(\$issueId: ID!, \$fieldId: ID!, \$optionId: ID!) {
  setIssueFieldValue(input: {
    issueId: \$issueId, issueFields: [{ fieldId: \$fieldId, singleSelectOptionId: \$optionId }]
  }) { issue { id } }
}"

readonly ISS_DOC_SET_TYPE="mutation(\$issueId: ID!, \$issueTypeId: ID!) {
  updateIssueIssueType(input: { issueId: \$issueId, issueTypeId: \$issueTypeId }) { issue { id } }
}"

readonly ISS_DOC_ADD_SUB_ISSUE="mutation(\$parentId: ID!, \$childId: ID!) {
  addSubIssue(input: { issueId: \$parentId, subIssueId: \$childId }) { issue { id } }
}"

readonly ISS_DOC_REMOVE_SUB_ISSUE="mutation(\$parentId: ID!, \$childId: ID!) {
  removeSubIssue(input: { issueId: \$parentId, subIssueId: \$childId }) { issue { id } }
}"

readonly ISS_DOC_ADD_BLOCKED_BY="mutation(\$issueId: ID!, \$blockingIssueId: ID!) {
  addBlockedBy(input: { issueId: \$issueId, blockingIssueId: \$blockingIssueId }) { issue { id } }
}"

readonly ISS_DOC_REMOVE_BLOCKED_BY="mutation(\$issueId: ID!, \$blockingIssueId: ID!) {
  removeBlockedBy(input: { issueId: \$issueId, blockingIssueId: \$blockingIssueId }) { issue { id } }
}"

# The issues-discover lookups, each printing its document: an owner's boards,
# one board, one board's fields, and a repository's native issue fields and
# issue types. Each paged connection reads the page after $after.
iss_doc_discover_projects() {
  printf '%s' "query(\$owner: String!, \$after: String) {
  repositoryOwner(login: \$owner) {
    ... on ProjectV2Owner {
      projectsV2(first: $ISS_PAGE_SIZE, after: \$after) { pageInfo { hasNextPage endCursor } nodes { number title id } }
    }
  }
}"
}

iss_doc_discover_project() {
  printf '%s' "query(\$owner: String!, \$number: Int!) {
  repositoryOwner(login: \$owner) {
    ... on ProjectV2Owner { projectV2(number: \$number) { number title id } }
  }
}"
}

iss_doc_discover_fields() {
  printf '%s' "query(\$owner: String!, \$number: Int!, \$after: String) {
  repositoryOwner(login: \$owner) {
    ... on ProjectV2Owner {
      projectV2(number: \$number) {
        fields(first: $ISS_PAGE_SIZE, after: \$after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            ... on ProjectV2Field             { id name dataType }
            ... on ProjectV2SingleSelectField { id name dataType options { id name } }
            ... on ProjectV2IterationField    { id name dataType }
          }
        }
      }
    }
  }
}"
}

iss_doc_discover_issue_fields() {
  printf '%s' "query(\$owner: String!, \$repo: String!, \$after: String) {
  repository(owner: \$owner, name: \$repo) {
    issueFields(first: $ISS_PAGE_SIZE, after: \$after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        __typename
        ... on IssueFieldCommon { name dataType }
        ... on IssueFieldSingleSelect { id options { id name } }
      }
    }
  }
}"
}

iss_doc_discover_issue_types() {
  printf '%s' "query(\$owner: String!, \$repo: String!, \$after: String) {
  repository(owner: \$owner, name: \$repo) {
    issueTypes(first: $ISS_PAGE_SIZE, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id name isEnabled } }
  }
}"
}

# ---------------------------------------------------------------------------
# Set-slot. One routine serves /issue-set-priority, /issue-set-size,
# /issue-set-status and /issue-create's slot flags.
# ---------------------------------------------------------------------------

# iss_slot_options <slot>: the slot's option names, comma-separated, in file
# order.
iss_slot_options() {
  iss_cfg_children fields "$1" options | iss_join_lines
}

# iss_slot_resolve <slot> <value>: validate a value against the slot's kind
# and set SLOT_KIND and SLOT_VALUE (the canonical option name, or the integer
# for kind: number). Aborts with the catalogue wording on a bad value. The
# caller has already handled kind: skip and an absent slot.
iss_slot_resolve() {
  local slot=$1 value=$2 canonical
  SLOT_KIND=$(iss_slot_kind "$slot")
  case "$SLOT_KIND" in
    number)
      iss_number_check "$slot" "$value" ||
        iss_err_out_of_range "${value:-<empty>}" "$slot" "$ISS_NUM_MIN" "$ISS_NUM_MAX"
      SLOT_VALUE=$value
      ;;
    single-select|label|issue-field)
      if canonical=$(iss_resolve_name all "$value" fields "$slot" options); then
        SLOT_VALUE=$canonical
      elif iss_is_int "$value"; then
        iss_err_kind_mismatch "$slot" "$value" "$SLOT_KIND" "$(iss_slot_options "$slot")"
      else
        iss_err_not_in_options "$value" "$slot" "$(iss_slot_options "$slot")"
      fi
      ;;
    *)
      iss_die "\`$slot\` has unknown \`kind: $SLOT_KIND\` in \`repo-config.md\`; run \`/repo-config\` to regenerate it"
      ;;
  esac
}

# The project item on the configured board, from ISS_ISSUE; empty when the
# issue is not on it.
iss_project_item() {
  iss_jq --arg p "$(iss_cfg_get project-id)" "[.projectItems.nodes[] | select(.project.id == \$p)][0].id // empty"
}

# Whether the last failed iss_gql call's message reads as a node ID that no
# longer resolves, the symptom of an ID cached in repo-config going stale.
iss_is_stale_id_error() {
  case "$(iss_lc "$ISS_GQL_ERR $ISS_GQL_OUT")" in
    *"could not resolve to a node"*|*"not found"*|*"does not exist"*) return 0 ;;
  esac
  return 1
}

# iss_slot_read <slot> <kind>: the slot's current value from ISS_ISSUE, which
# must carry the selection the kind reads. Prints the canonical value, or
# nothing when unset.
iss_slot_read() {
  local slot=$1 kind=$2 fid ns
  case "$kind" in
    number)
      fid=$(iss_cfg_get fields "$slot" id)
      iss_jq --arg p "$(iss_cfg_get project-id)" --arg f "$fid" \
        "[.projectItems.nodes[] | select(.project.id == \$p) | .fieldValues.nodes[] | select(.field.id? == \$f) | .number][0]
         | if . == null then empty elif . == floor then floor else . end"
      ;;
    single-select)
      fid=$(iss_cfg_get fields "$slot" id)
      iss_jq --arg p "$(iss_cfg_get project-id)" --arg f "$fid" \
        "[.projectItems.nodes[] | select(.project.id == \$p) | .fieldValues.nodes[] | select(.field.id? == \$f) | .name][0] // empty"
      ;;
    issue-field)
      fid=$(iss_cfg_get fields "$slot" field-id)
      iss_jq --arg f "$fid" "[.issueFieldValues.nodes[] | select(.field.id? == \$f) | .name][0] // empty"
      ;;
    label)
      ns=$(iss_cfg_get fields "$slot" namespace)
      iss_slot_labels_present "$slot" "$ns" | iss_join_lines
      ;;
  esac
}

# The slot's own option labels currently on the issue in ISS_ISSUE, one
# canonical option name per line.
iss_slot_labels_present() {
  local slot=$1 ns=$2 opt labels
  labels=$(iss_jq '.labels.nodes[].name' | tr '[:upper:]' '[:lower:]')
  while IFS= read -r opt; do
    [ -n "$opt" ] || continue
    if printf '%s\n' "$labels" | grep -Fxq -- "$(iss_lc "$ns$opt")"; then
      printf '%s\n' "$opt"
    fi
  done <<EOF
$(iss_cfg_children fields "$slot" options)
EOF
}

# iss_slot_write <slot> <host> <owner> <repo> <number> <precheck>: write
# SLOT_VALUE (from iss_slot_resolve) to the slot, then re-read it and abort
# when the re-read does not show it. Sets SLOT_RESULT to "set" or, when
# <precheck> is "precheck", the kind is not number, and the value was already
# there, "noop"; a number slot is always written. Leaves the issue, with its
# url, in ISS_ISSUE.
iss_slot_write() {
  local slot=$1 host=$2 owner=$3 repo=$4 number=$5 precheck=$6
  local kind=$SLOT_KIND sel current item issue_id fid oid ns add remove opt ref repo_arg
  ref=$(iss_ref "$host" "$owner" "$repo" "$number")
  case "$kind" in
    number|single-select) sel="id url $ISS_SEL_PROJECT_ITEMS" ;;
    issue-field) sel="id url viewerCanSetFields $ISS_SEL_ISSUE_FIELDS" ;;
    label) sel="id url $ISS_SEL_LABELS" ;;
  esac
  iss_lookup "$host" "$owner" "$repo" "$number" "$sel"
  issue_id=$(iss_jq .id)
  SLOT_RESULT='set'

  if [ "$kind" = issue-field ] && [ "$(iss_jq .viewerCanSetFields)" != true ]; then
    iss_err_cannot_set_issue_field "$(iss_cfg_get fields "$slot" field-name)" "$number"
  fi

  if [ "$precheck" = precheck ] && [ "$kind" != number ]; then
    current=$(iss_slot_read "$slot" "$kind")
    if [ "$(iss_lc "$current")" = "$(iss_lc "$SLOT_VALUE")" ]; then
      SLOT_RESULT=noop
      return 0
    fi
  fi

  case "$kind" in
    number|single-select)
      fid=$(iss_cfg_get fields "$slot" id)
      item=$(iss_project_item)
      if [ -z "$item" ]; then
        iss_gql "$host" -f query="$ISS_DOC_ADD_PROJECT_ITEM" -f projectId="$(iss_cfg_get project-id)" \
          -f contentId="$issue_id" || iss_gql_fail
        item=$(printf '%s' "$ISS_GQL_OUT" | jq -r '.data.addProjectV2ItemById.item.id')
      fi
      if [ "$kind" = number ]; then
        iss_gql "$host" -f query="$ISS_DOC_SET_NUMBER" -f projectId="$(iss_cfg_get project-id)" \
          -f itemId="$item" -f fieldId="$fid" -F value="$SLOT_VALUE"
      else
        oid=$(iss_cfg_get fields "$slot" options "$SLOT_VALUE")
        iss_gql "$host" -f query="$ISS_DOC_SET_SINGLE_SELECT" -f projectId="$(iss_cfg_get project-id)" \
          -f itemId="$item" -f fieldId="$fid" -f optionId="$oid"
      fi || {
        iss_is_stale_id_error && iss_err_stale_project_field "$fid" "$(iss_cfg_get project-id)"
        iss_gql_fail
      }
      ;;
    issue-field)
      fid=$(iss_cfg_get fields "$slot" field-id)
      oid=$(iss_cfg_get fields "$slot" options "$SLOT_VALUE")
      iss_gql "$host" -f query="$ISS_DOC_SET_ISSUE_FIELD" -f issueId="$issue_id" -f fieldId="$fid" \
        -f optionId="$oid" || {
        iss_is_stale_id_error &&
          iss_err_stale_issue_field "$(iss_cfg_get fields "$slot" field-name)" "$fid" \
            "$(iss_repo_name "$host" "$owner" "$repo")"
        iss_gql_fail
      }
      ;;
    label)
      ns=$(iss_cfg_get fields "$slot" namespace)
      add=
      remove=
      current=$(iss_slot_labels_present "$slot" "$ns")
      while IFS= read -r opt; do
        [ -n "$opt" ] || continue
        [ "$opt" = "$SLOT_VALUE" ] || remove="$remove$ns$opt$ISS_NEWLINE"
      done <<EOF
$current
EOF
      printf '%s\n' "$current" | grep -Fxq -- "$SLOT_VALUE" || add="$ns$SLOT_VALUE"
      remove=$(printf '%s' "$remove" | LC_ALL=C sort | awk 'NF' | paste -sd, -)
      repo_arg=$(iss_repo_arg "$host" "$owner" "$repo")
      if [ -n "$add" ] && [ -n "$remove" ]; then
        gh issue edit "$number" --repo "$repo_arg" --add-label "$add" --remove-label "$remove" >/dev/null
      elif [ -n "$add" ]; then
        gh issue edit "$number" --repo "$repo_arg" --add-label "$add" >/dev/null
      elif [ -n "$remove" ]; then
        gh issue edit "$number" --repo "$repo_arg" --remove-label "$remove" >/dev/null
      fi || iss_die "\`gh issue edit\` failed on issue \`$ref\`"
      ;;
  esac

  iss_lookup "$host" "$owner" "$repo" "$number" "$sel"
  current=$(iss_slot_read "$slot" "$kind")
  if [ "$kind" = number ]; then
    awk -v a="$current" -v b="$SLOT_VALUE" 'BEGIN { exit (a != "" && a + 0 == b + 0) ? 0 : 1 }' ||
      iss_err_write_not_landed "$slot" "$ref" "$SLOT_VALUE" "${current:-(none)}"
  elif [ "$(iss_lc "$current")" != "$(iss_lc "$SLOT_VALUE")" ]; then
    iss_err_write_not_landed "$slot" "$ref" "$SLOT_VALUE" "${current:-(none)}"
  fi
}

# iss_slot_unconfigured_exit <slot> <host> <owner> <repo>: the "nothing to do"
# warning for a set-slot verb whose slot the operand's repository leaves
# unconfigured, naming that repository when it is not the current one. Exits
# zero.
iss_slot_unconfigured_exit() {
  local name
  if iss_same_repo "$2" "$3" "$4" "$ISS_HOST" "$ISS_OWNER" "$ISS_REPO"; then
    printf "\`/issue-set-%s\` has nothing to do: this repo has no \`%s\` slot configured. (Run \`/repo-config\` to add one.)\n" "$1" "$1"
  else
    name=$(iss_repo_name "$2" "$3" "$4")
    printf "\`/issue-set-%s\` has nothing to do: \`%s\` has no \`%s\` slot configured. (Run \`/repo-config\` in \`%s\` to add one.)\n" "$1" "$name" "$1" "$name"
  fi
  exit 0
}

# The body of /issue-set-priority and /issue-set-size.
iss_set_slot_verb() {
  local slot=$1 ref label
  shift
  [ "$#" -eq 2 ] || iss_usage_die "usage: issue-set-$slot <issue> <value>"
  iss_init "$1"
  iss_parse_operand "$1"
  iss_operand_board_config
  [ "$(iss_slot_kind "$slot")" != skip ] || iss_slot_unconfigured_exit "$slot" "$OP_HOST" "$OP_OWNER" "$OP_REPO"
  iss_slot_resolve "$slot" "$2"
  iss_slot_write "$slot" "$OP_HOST" "$OP_OWNER" "$OP_REPO" "$OP_NUMBER" precheck
  ref=$(iss_ref "$OP_HOST" "$OP_OWNER" "$OP_REPO" "$OP_NUMBER")
  label=
  [ "$SLOT_KIND" = label ] && label=" (via label \`$(iss_cfg_get fields "$slot" namespace)$SLOT_VALUE\`)"
  if [ "$SLOT_RESULT" = noop ]; then
    printf '%s %s already set to %s%s.\n' "$ref" "$slot" "$SLOT_VALUE" "$label"
  else
    printf '%s %s set to %s%s.\n' "$ref" "$slot" "$SLOT_VALUE" "$label"
  fi
}

# iss_type_write <host> <owner> <repo> <number> <issue-id> <type-id>
# <type-name>: set the issue type, then re-read it and abort when the re-read
# does not show it.
iss_type_write() {
  iss_gql "$1" -f query="$ISS_DOC_SET_TYPE" -f issueId="$5" -f issueTypeId="$6" || iss_gql_fail
  iss_lookup "$1" "$2" "$3" "$4" "issueType { id name }"
  [ "$(iss_jq '.issueType.id // empty')" = "$6" ] ||
    iss_err_write_not_landed type "$(iss_ref "$1" "$2" "$3" "$4")" "$7" "$(iss_jq '.issueType.name // "(none)"')"
}

# ---------------------------------------------------------------------------
# Relationships.
# ---------------------------------------------------------------------------

# iss_blocked_by_edge <add|remove> <blocked-operand> <blocker-operand>
#                     <blocked|blocker>
# Resolves both operands, reads the edge from the named side, and adds or
# removes it unless it already is in the requested state; then re-reads the
# side and aborts when the edge is not in the requested state. Sets
# EDGE_BLOCKED and EDGE_BLOCKER (display references) and leaves the named
# side, with its url, in ISS_ISSUE. Returns 1 when the edge already was in the
# requested state.
iss_blocked_by_edge() {
  local action=$1 side=$4 bh bo br bn xh xo xr xn blocked_id blocker_id side_sel list want present doc sref
  iss_operand "$2"; bh=$OP_HOST; bo=$OP_OWNER; br=$OP_REPO; bn=$OP_NUMBER
  iss_operand "$3"; xh=$OP_HOST; xo=$OP_OWNER; xr=$OP_REPO; xn=$OP_NUMBER
  EDGE_BLOCKED=$(iss_ref "$bh" "$bo" "$br" "$bn")
  EDGE_BLOCKER=$(iss_ref "$xh" "$xo" "$xr" "$xn")
  if [ "$side" = blocked ]; then
    list=blockedBy
    iss_lookup "$xh" "$xo" "$xr" "$xn" id; blocker_id=$(iss_jq .id)
    side_sel="id url $(iss_conn blockedBy)"
    iss_lookup "$bh" "$bo" "$br" "$bn" "$side_sel"; blocked_id=$(iss_jq .id)
    want=$blocker_id
  else
    list=blocking
    iss_lookup "$bh" "$bo" "$br" "$bn" id; blocked_id=$(iss_jq .id)
    side_sel="id url $(iss_conn blocking)"
    iss_lookup "$xh" "$xo" "$xr" "$xn" "$side_sel"; blocker_id=$(iss_jq .id)
    want=$blocked_id
  fi
  present=$(iss_jq --arg w "$want" --arg l "$list" "any(.[\$l].nodes[]; .id == \$w)")
  if { [ "$action" = add ] && [ "$present" = true ]; } || { [ "$action" = remove ] && [ "$present" != true ]; }; then
    return 1
  fi
  if [ "$action" = add ]; then doc=$ISS_DOC_ADD_BLOCKED_BY; else doc=$ISS_DOC_REMOVE_BLOCKED_BY; fi
  iss_gql "$bh" -f query="$doc" -f issueId="$blocked_id" -f blockingIssueId="$blocker_id" || iss_gql_fail
  if [ "$side" = blocked ]; then
    iss_lookup "$bh" "$bo" "$br" "$bn" "$side_sel"; sref=$EDGE_BLOCKED
  else
    iss_lookup "$xh" "$xo" "$xr" "$xn" "$side_sel"; sref=$EDGE_BLOCKER
  fi
  present=$(iss_jq --arg w "$want" --arg l "$list" "any(.[\$l].nodes[]; .id == \$w)")
  if [ "$action" = add ] && [ "$present" != true ]; then
    iss_err_write_not_landed "the blocked-by edge" "$sref" "blocked by $EDGE_BLOCKER" "no such edge"
  fi
  if [ "$action" = remove ] && [ "$present" = true ]; then
    iss_err_write_not_landed "the blocked-by edge" "$sref" "not blocked by $EDGE_BLOCKER" "the edge still present"
  fi
}

readonly ISS_SEL_PARENT='id url parent { id number url repository { nameWithOwner } }'

# iss_add_sub_issue <parent-operand> <child-operand>: the body of
# /issue-set-parent and /issue-set-child. Prints the verb's output.
iss_add_sub_issue() {
  local ph po pr pn ch co cr cn parent_id parent_url child_id cur_id cur_num cur_nwo cref pref
  iss_operand "$1"; ph=$OP_HOST; po=$OP_OWNER; pr=$OP_REPO; pn=$OP_NUMBER
  iss_operand "$2"; ch=$OP_HOST; co=$OP_OWNER; cr=$OP_REPO; cn=$OP_NUMBER
  pref=$(iss_ref "$ph" "$po" "$pr" "$pn")
  cref=$(iss_ref "$ch" "$co" "$cr" "$cn")
  iss_lookup "$ph" "$po" "$pr" "$pn" "id url"
  parent_id=$(iss_jq .id); parent_url=$(iss_jq .url)
  iss_lookup "$ch" "$co" "$cr" "$cn" "$ISS_SEL_PARENT"
  child_id=$(iss_jq .id)
  cur_id=$(iss_jq '.parent.id // empty')
  if [ "$cur_id" = "$parent_id" ]; then
    printf 'Issue %s is already a sub-issue of %s; no change.\n' "$cref" "$pref"
    return 0
  fi
  if [ -n "$cur_id" ]; then
    cur_num=$(iss_jq .parent.number)
    cur_nwo=$(iss_jq .parent.repository.nameWithOwner)
    iss_die "issue \`$cref\` already has parent \`$(iss_ref_nwo "$ch" "$cur_nwo" "$cur_num")\`; remove it first with \`/issue-unset-parent $cref\` before setting a new parent"
  fi
  iss_gql "$ch" -f query="$ISS_DOC_ADD_SUB_ISSUE" -f parentId="$parent_id" -f childId="$child_id" || iss_gql_fail
  iss_lookup "$ch" "$co" "$cr" "$cn" "$ISS_SEL_PARENT"
  cur_id=$(iss_jq '.parent.id // empty')
  [ "$cur_id" = "$parent_id" ] || iss_err_write_not_landed "the parent" "$cref" "$pref" "${cur_id:-(none)}"
  printf 'Linked issue %s as a sub-issue of %s.\n%s\n' "$cref" "$pref" "$parent_url"
}

# iss_remove_sub_issue <host> <owner> <repo> <child-number> <child-id>
# <parent-id> <child-ref> <parent-ref>: remove the edge, then re-read the
# child and abort when it still has that parent.
iss_remove_sub_issue() {
  local cur_id
  iss_gql "$1" -f query="$ISS_DOC_REMOVE_SUB_ISSUE" -f parentId="$6" -f childId="$5" || iss_gql_fail
  iss_lookup "$1" "$2" "$3" "$4" "$ISS_SEL_PARENT"
  cur_id=$(iss_jq '.parent.id // empty')
  [ "$cur_id" != "$6" ] || iss_err_write_not_landed "the parent" "$7" "(none)" "$8"
}

# ---------------------------------------------------------------------------
# User-config reads.
# ---------------------------------------------------------------------------

# iss_user_config_get <path> <writer-skill> <key>: print the key's value from
# a user-config file. Returns 3 when the file or the key is absent; aborts on
# a file that predates versioning or is stale. Callers run it in a command
# substitution, where that abort arrives as exit status 1.
iss_user_config_get() {
  local path=$1 skill=$2 key=$3 text fm version
  [ -f "$path" ] || return 3
  text=$(cat "$path")
  fm=$(iss_frontmatter "$text") || iss_err_user_config_absent "$path" "$skill"
  version=$(iss_fm_get "$fm" schema-version) || iss_err_user_config_absent "$path" "$skill"
  iss_is_digits "$version" || iss_err_user_config_absent "$path" "$skill"
  [ "$version" -ge "$ISS_USER_CONFIG_SCHEMA" ] || iss_err_user_config_stale "$path" "$skill" "$version"
  iss_fm_get "$fm" "$key" || return 3
}

# iss_user_config_value <key> [global-only]: print the key's value from the
# repo-level user-config, else from the user-global one; a file that sets the
# key to an empty value counts as not setting it. The repo-level file is read
# only when ISS_REPO_ROOT is set, and not at all with global-only. Returns 3
# when neither file sets the key. Callers run it in a command substitution
# and exit on any other non-zero status, which is an abort already reported
# on stderr.
iss_user_config_value() {
  local key=$1 v rc
  if [ "${2:-}" != global-only ] && [ -n "${ISS_REPO_ROOT:-}" ]; then
    v=$(iss_user_config_get "$ISS_REPO_ROOT/.issues/user-config.md" /user-config "$key")
    rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || exit 1
    if [ "$rc" -eq 0 ] && [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  fi
  v=$(iss_user_config_get "${XDG_CONFIG_HOME:-$HOME/.config}/issues/user-config.md" /global-user-config "$key")
  rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || exit 1
  if [ "$rc" -eq 0 ] && [ -n "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  return 3
}

# iss_default_assignee <host> [global-only]: default-assignee as
# iss_user_config_value resolves it, else the user gh is authenticated as on
# <host>. Callers run it in a command substitution and exit on a non-zero
# status, which is an abort already reported on stderr.
iss_default_assignee() {
  local v rc
  v=$(iss_user_config_value default-assignee "${2:-}")
  rc=$?
  case "$rc" in
    0) printf '%s' "$v"; return 0 ;;
    3) ;;
    *) exit 1 ;;
  esac
  iss_viewer_login "$1"
}

# iss_branch_prefix: print the "mode:" and "prefix:" lines for
# ISS_BRANCH_PREFIX_MODE, taking the prefix from the user-config key the mode
# names as iss_user_config_value resolves it. Aborts on a mode outside
# none/initials/name, and on a key that is unset or whose value contains "/"
# or whitespace.
iss_branch_prefix() {
  local mode=$ISS_BRANCH_PREFIX_MODE key value
  case "$mode" in
    none)
      printf 'mode: none\nprefix:\n'
      return 0
      ;;
    initials) key=branch-prefix-initials ;;
    name) key=branch-prefix-name ;;
    *) iss_err_branch_prefix_mode "$mode" ;;
  esac
  value=$(iss_user_config_value "$key")
  case "$?" in
    0) ;;
    3) iss_err_branch_prefix_unset "$key" ;;
    *) exit 1 ;;
  esac
  case "$value" in
    */*|*[[:space:]]*) iss_err_branch_prefix_invalid "$key" "$value" ;;
  esac
  printf 'mode: %s\nprefix: %s/\n' "$mode" "$value"
}

# iss_viewer_login <host>: print the login of the user gh is authenticated as
# on <host>. Callers run it in a command substitution and exit on a non-zero
# status, which is an abort already reported on stderr.
iss_viewer_login() {
  local login
  { login=$(iss_rest "$1" user --jq .login) && [ -n "$login" ]; } ||
    iss_die "could not resolve the authenticated GitHub user${1:+ on \`$1\`}"
  printf '%s' "$login"
}
