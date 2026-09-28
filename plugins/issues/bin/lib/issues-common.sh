# shellcheck shell=bash
# Shared code for the issue-verb scripts in plugins/issues/bin/: the
# .issues/repo-config.md read, operand parsing, node-ID and field/option ID
# resolution, the GraphQL documents, the set-slot write paths, and the
# canonical error catalogue. Every script sources this file and nothing else,
# so each of these is written exactly once.
#
# Runs under bash 3.2 and depends on nothing beyond gh, jq and the base
# userland (awk, grep, sed, tr, mktemp): no associative arrays, no ${var,,},
# no mapfile.

ISS_PROGRAM=${0##*/}

# The minimum repo-config schema-version these scripts read. A newer file is
# read as this version; its additions are ignored.
readonly ISS_REPO_CONFIG_SCHEMA=6
# The minimum user-config schema-version the default-assignee read accepts.
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

iss_err_jira() {
  iss_die "\`issues: Jira\` is configured, and this script serves only the GitHub backend. Follow the Jira backend path in the skill's SKILL.md instead."
}

iss_err_not_found() {
  iss_die "issue \`#$3\` not found in \`$1/$2\`"
}

iss_err_no_block() {
  iss_die "no \`github-project:\` block in \`repo-config.md\`; run \`/repo-config\` to add it"
}

iss_err_no_issue_types() {
  iss_die "issue-types map missing from \`github-project:\` in \`repo-config.md\`; run \`/repo-config\` to add it"
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

iss_err_user_config_absent() {
  iss_die "\`$1\` predates user-config schema versioning. Run \`$2\` to migrate."
}

iss_err_user_config_stale() {
  iss_die "\`$1\` is at schema-version \`$3\`; this reader requires \`$ISS_USER_CONFIG_SCHEMA\`. Run \`$2\` to migrate."
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
#   ISS_ISSUES, ISS_LINK_PREFIX       front-matter values
#   ISS_GP                            the github-project: block flattened to
#                                     one "<path><TAB><value>" line per node,
#                                     path components joined by ISS_SEP
#   ISS_HAS_GP                        1 when the block is present, else 0
# It aborts with the canonical repo-config messages, and with the fixed Jira
# message when the tracker is Jira — before any gh call.
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

# Flatten the github-project: block of a repo-config body. The block starts at
# a column-0 "github-project:" line and runs to the next column-0 non-blank
# line. Mappings nest by indentation; a flow list "[a, b]" or a block list of
# "- a" lines becomes an identity map (a -> a) so every option list reads the
# same way.
iss_flatten_gp() {
  awk -v SEP="$ISS_SEP" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unquote(s) {
      s = trim(s)
      if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) return substr(s, 2, length(s) - 2)
      sub(/[ \t]+#.*$/, "", s)
      return trim(s)
    }
    function path(   p, i) {
      p = "github-project"
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
    /^github-project:[ \t]*$/ { inblk = 1; sp = 0; print "github-project\t"; next }
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
$1
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
  local text=$1 prefix=${2:-} fm version field body
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
  case "$ISS_ISSUES" in
    GitHub) ;;
    Jira) iss_err_jira ;;
    *) iss_die "${prefix}unsupported \`issues:\` value \`$ISS_ISSUES\` in \`.issues/repo-config.md\`" ;;
  esac
  body=$(iss_body "$text")
  ISS_GP=$(iss_flatten_gp "$body")
  if [ -n "$ISS_GP" ]; then ISS_HAS_GP=1; else ISS_HAS_GP=0; fi
}

# Read the current repo's .issues/repo-config.md.
iss_load_config() {
  ISS_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || iss_die "not inside a git working tree"
  [ -f "$ISS_REPO_ROOT/.issues/repo-config.md" ] || iss_err_file_missing
  iss_parse_config_text "$(cat "$ISS_REPO_ROOT/.issues/repo-config.md")"
}

# Resolve the current repo as owner and name. Sets ISS_OWNER, ISS_REPO.
iss_current_repo() {
  local nwo
  nwo=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name') ||
    iss_die "could not resolve the current GitHub repository with \`gh repo view\`"
  ISS_OWNER=${nwo%%/*}
  ISS_REPO=${nwo#*/}
}

# The common opening of every verb: tools, config, tracker, repo.
iss_init() {
  iss_require_tools
  iss_load_config
  iss_current_repo
}

# ---------------------------------------------------------------------------
# Flattened-config accessors. Arguments are path components below
# github-project, e.g. iss_cfg_get fields status kind.
# ---------------------------------------------------------------------------

iss_cfg_path() {
  local p=github-project c
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

# iss_parse_operand <operand> [local-only]: sets OP_OWNER, OP_REPO,
# OP_NUMBER from N, #N or owner/repo#N; N may also carry the repo-config's
# issue-link-prefix. With local-only, the owner/repo#N form is a usage error.
iss_parse_operand() {
  local op=$1 nwo num
  case "$op" in
    */*'#'*)
      [ "${2:-}" = local-only ] && iss_usage_die "\`$op\`: this verb takes an issue number in the current repo"
      nwo=${op%%#*}
      num=${op#*#}
      OP_OWNER=${nwo%%/*}
      OP_REPO=${nwo#*/}
      case "$OP_REPO" in */*|'') iss_usage_die "\`$op\` is not an issue reference (expected N, #N or owner/repo#N)" ;; esac
      [ -n "$OP_OWNER" ] || iss_usage_die "\`$op\` is not an issue reference (expected N, #N or owner/repo#N)"
      ;;
    *)
      num=${op#"$ISS_LINK_PREFIX"}
      num=${num#'#'}
      OP_OWNER=$ISS_OWNER
      OP_REPO=$ISS_REPO
      ;;
  esac
  iss_is_digits "$num" || iss_usage_die "\`$op\` is not an issue reference (expected N, #N or owner/repo#N)"
  OP_NUMBER=$num
}

# Print an issue reference as #N in the current repo, owner/repo#N elsewhere.
iss_ref() {
  if [ "$(iss_lc "$1/$2")" = "$(iss_lc "$ISS_OWNER/$ISS_REPO")" ]; then
    printf '#%s' "$3"
  else
    printf '%s/%s#%s' "$1" "$2" "$3"
  fi
}

# Same, from a nameWithOwner string.
iss_ref_nwo() {
  iss_ref "${1%%/*}" "${1#*/}" "$2"
}

# ---------------------------------------------------------------------------
# GraphQL.
# ---------------------------------------------------------------------------

# iss_gql <gh api graphql args...>: runs the call and sets ISS_GQL_OUT and
# ISS_GQL_ERR. Returns gh's exit status.
iss_gql() {
  local errf rc
  errf=$(mktemp "${TMPDIR:-/tmp}/issues-gql.XXXXXX")
  ISS_GQL_OUT=$(gh api graphql "$@" 2>"$errf")
  rc=$?
  ISS_GQL_ERR=$(cat "$errf")
  rm -f "$errf"
  return $rc
}

iss_gql_fail() {
  iss_die "GitHub GraphQL call failed: ${ISS_GQL_ERR:-$ISS_GQL_OUT}"
}

# iss_lookup <owner> <repo> <number> <selection>: fetch one issue with the
# given field selection. Sets ISS_ISSUE to the issue object's JSON. Aborts
# with the catalogue's not-found wording when the issue does not exist.
iss_lookup() {
  local doc
  doc="query(\$owner: String!, \$repo: String!, \$number: Int!) {
  repository(owner: \$owner, name: \$repo) {
    issue(number: \$number) { $4 }
  }
}"
  if ! iss_gql -f query="$doc" -f owner="$1" -f repo="$2" -F number="$3"; then
    if [ "$(printf '%s' "$ISS_GQL_OUT" | jq -r '.data.repository.issue == null' 2>/dev/null)" = true ]; then
      iss_err_not_found "$1" "$2" "$3"
    fi
    iss_gql_fail
  fi
  ISS_ISSUE=$(printf '%s' "$ISS_GQL_OUT" | jq -c '.data.repository.issue')
  [ "$ISS_ISSUE" != null ] || iss_err_not_found "$1" "$2" "$3"
}

# Same as iss_lookup, but returns 1 instead of aborting on not-found.
iss_try_lookup() {
  local doc
  doc="query(\$owner: String!, \$repo: String!, \$number: Int!) {
  repository(owner: \$owner, name: \$repo) {
    issue(number: \$number) { $4 }
  }
}"
  if ! iss_gql -f query="$doc" -f owner="$1" -f repo="$2" -F number="$3"; then
    if [ "$(printf '%s' "$ISS_GQL_OUT" | jq -r '.data.repository.issue == null' 2>/dev/null)" = true ]; then
      return 1
    fi
    iss_gql_fail
  fi
  ISS_ISSUE=$(printf '%s' "$ISS_GQL_OUT" | jq -c '.data.repository.issue')
  [ "$ISS_ISSUE" != null ]
}

iss_jq() {
  printf '%s' "$ISS_ISSUE" | jq -r "$@"
}

readonly ISS_SEL_PROJECT_ITEMS='projectItems(first: 20) {
  nodes {
    id
    project { id }
    fieldValues(first: 50) {
      nodes {
        __typename
        ... on ProjectV2ItemFieldNumberValue { field { ... on ProjectV2FieldCommon { id } } number }
        ... on ProjectV2ItemFieldSingleSelectValue { field { ... on ProjectV2FieldCommon { id } } name optionId }
      }
    }
  }
}'

readonly ISS_SEL_ISSUE_FIELDS='issueFieldValues(first: 20) {
  nodes {
    __typename
    ... on IssueFieldSingleSelectValue { name optionId field { ... on IssueFieldSingleSelect { id } } }
  }
}'

readonly ISS_SEL_LABELS='labels(first: 100) { nodes { name } }'

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
  local slot=$1 value=$2 min max canonical
  SLOT_KIND=$(iss_slot_kind "$slot")
  case "$SLOT_KIND" in
    number)
      min=$(iss_cfg_get fields "$slot" min 2>/dev/null) || min=
      max=$(iss_cfg_get fields "$slot" max 2>/dev/null) || max=
      if ! iss_is_int "$value" ||
         { [ -n "$min" ] && [ "$value" -lt "$min" ]; } ||
         { [ -n "$max" ] && [ "$value" -gt "$max" ]; }; then
        iss_err_out_of_range "${value:-<empty>}" "$slot" "${min:--inf}" "${max:-inf}"
      fi
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

# iss_slot_write <slot> <owner> <repo> <number> <precheck>: write SLOT_VALUE
# (from iss_slot_resolve) to the slot, then re-read it and abort when the
# re-read does not show it. Sets SLOT_RESULT to "set" or, when <precheck> is
# "precheck", the kind is not number, and the value was already there,
# "noop"; a number slot is always written. Leaves the issue, with its url, in
# ISS_ISSUE.
iss_slot_write() {
  local slot=$1 owner=$2 repo=$3 number=$4 precheck=$5
  local kind=$SLOT_KIND sel current item issue_id fid oid ns add remove opt ref
  ref=$(iss_ref "$owner" "$repo" "$number")
  case "$kind" in
    number|single-select) sel="id url $ISS_SEL_PROJECT_ITEMS" ;;
    issue-field) sel="id url viewerCanSetFields $ISS_SEL_ISSUE_FIELDS" ;;
    label) sel="id url $ISS_SEL_LABELS" ;;
  esac
  iss_lookup "$owner" "$repo" "$number" "$sel"
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
        iss_gql -f query="$ISS_DOC_ADD_PROJECT_ITEM" -f projectId="$(iss_cfg_get project-id)" -f contentId="$issue_id" ||
          iss_gql_fail
        item=$(printf '%s' "$ISS_GQL_OUT" | jq -r '.data.addProjectV2ItemById.item.id')
      fi
      if [ "$kind" = number ]; then
        iss_gql -f query="$ISS_DOC_SET_NUMBER" -f projectId="$(iss_cfg_get project-id)" \
          -f itemId="$item" -f fieldId="$fid" -F value="$SLOT_VALUE"
      else
        oid=$(iss_cfg_get fields "$slot" options "$SLOT_VALUE")
        iss_gql -f query="$ISS_DOC_SET_SINGLE_SELECT" -f projectId="$(iss_cfg_get project-id)" \
          -f itemId="$item" -f fieldId="$fid" -f optionId="$oid"
      fi || {
        iss_is_stale_id_error && iss_err_stale_project_field "$fid" "$(iss_cfg_get project-id)"
        iss_gql_fail
      }
      ;;
    issue-field)
      fid=$(iss_cfg_get fields "$slot" field-id)
      oid=$(iss_cfg_get fields "$slot" options "$SLOT_VALUE")
      iss_gql -f query="$ISS_DOC_SET_ISSUE_FIELD" -f issueId="$issue_id" -f fieldId="$fid" -f optionId="$oid" || {
        iss_is_stale_id_error &&
          iss_err_stale_issue_field "$(iss_cfg_get fields "$slot" field-name)" "$fid" "$owner/$repo"
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
      if [ -n "$add" ] && [ -n "$remove" ]; then
        gh issue edit "$number" --repo "$owner/$repo" --add-label "$add" --remove-label "$remove" >/dev/null
      elif [ -n "$add" ]; then
        gh issue edit "$number" --repo "$owner/$repo" --add-label "$add" >/dev/null
      elif [ -n "$remove" ]; then
        gh issue edit "$number" --repo "$owner/$repo" --remove-label "$remove" >/dev/null
      fi || iss_die "\`gh issue edit\` failed on issue \`$ref\`"
      ;;
  esac

  iss_lookup "$owner" "$repo" "$number" "$sel"
  current=$(iss_slot_read "$slot" "$kind")
  if [ "$kind" = number ]; then
    awk -v a="$current" -v b="$SLOT_VALUE" 'BEGIN { exit (a != "" && a + 0 == b + 0) ? 0 : 1 }' ||
      iss_err_write_not_landed "$slot" "$ref" "$SLOT_VALUE" "${current:-(none)}"
  elif [ "$(iss_lc "$current")" != "$(iss_lc "$SLOT_VALUE")" ]; then
    iss_err_write_not_landed "$slot" "$ref" "$SLOT_VALUE" "${current:-(none)}"
  fi
}

# The "<slot>: nothing to do" warning for a set-slot verb whose slot is
# unconfigured. Exits zero.
iss_slot_unconfigured_exit() {
  printf "\`/issue-set-%s\` has nothing to do: this repo has no \`%s\` slot configured. (Run \`/repo-config\` to add one.)\n" "$1" "$1"
  exit 0
}

# The body of /issue-set-priority and /issue-set-size.
iss_set_slot_verb() {
  local slot=$1 ref label
  shift
  [ "$#" -eq 2 ] || iss_usage_die "usage: issue-set-$slot <N> <value>"
  iss_init
  [ "$ISS_HAS_GP" = 1 ] || iss_err_no_block
  [ "$(iss_slot_kind "$slot")" != skip ] || iss_slot_unconfigured_exit "$slot"
  iss_parse_operand "$1" local-only
  iss_slot_resolve "$slot" "$2"
  iss_slot_write "$slot" "$OP_OWNER" "$OP_REPO" "$OP_NUMBER" precheck
  ref=$(iss_ref "$OP_OWNER" "$OP_REPO" "$OP_NUMBER")
  label=
  [ "$SLOT_KIND" = label ] && label=" (via label \`$(iss_cfg_get fields "$slot" namespace)$SLOT_VALUE\`)"
  if [ "$SLOT_RESULT" = noop ]; then
    printf '%s %s already set to %s%s.\n' "$ref" "$slot" "$SLOT_VALUE" "$label"
  else
    printf '%s %s set to %s%s.\n' "$ref" "$slot" "$SLOT_VALUE" "$label"
  fi
}

# iss_type_write <owner> <repo> <number> <issue-id> <type-id> <type-name>: set
# the issue type, then re-read it and abort when the re-read does not show it.
iss_type_write() {
  iss_gql -f query="$ISS_DOC_SET_TYPE" -f issueId="$4" -f issueTypeId="$5" || iss_gql_fail
  iss_lookup "$1" "$2" "$3" "issueType { id name }"
  [ "$(iss_jq '.issueType.id // empty')" = "$5" ] ||
    iss_err_write_not_landed type "$(iss_ref "$1" "$2" "$3")" "$6" "$(iss_jq '.issueType.name // "(none)"')"
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
  local action=$1 side=$4 bo br bn xo xr xn blocked_id blocker_id side_sel list want present doc sref
  iss_parse_operand "$2"; bo=$OP_OWNER; br=$OP_REPO; bn=$OP_NUMBER
  iss_parse_operand "$3"; xo=$OP_OWNER; xr=$OP_REPO; xn=$OP_NUMBER
  EDGE_BLOCKED=$(iss_ref "$bo" "$br" "$bn")
  EDGE_BLOCKER=$(iss_ref "$xo" "$xr" "$xn")
  if [ "$side" = blocked ]; then
    list=blockedBy
    iss_lookup "$xo" "$xr" "$xn" id; blocker_id=$(iss_jq .id)
    side_sel="id url blockedBy(first: 100) { nodes { id } }"
    iss_lookup "$bo" "$br" "$bn" "$side_sel"; blocked_id=$(iss_jq .id)
    want=$blocker_id
  else
    list=blocking
    iss_lookup "$bo" "$br" "$bn" id; blocked_id=$(iss_jq .id)
    side_sel="id url blocking(first: 100) { nodes { id } }"
    iss_lookup "$xo" "$xr" "$xn" "$side_sel"; blocker_id=$(iss_jq .id)
    want=$blocked_id
  fi
  present=$(iss_jq --arg w "$want" --arg l "$list" "any(.[\$l].nodes[]; .id == \$w)")
  if { [ "$action" = add ] && [ "$present" = true ]; } || { [ "$action" = remove ] && [ "$present" != true ]; }; then
    return 1
  fi
  if [ "$action" = add ]; then doc=$ISS_DOC_ADD_BLOCKED_BY; else doc=$ISS_DOC_REMOVE_BLOCKED_BY; fi
  iss_gql -f query="$doc" -f issueId="$blocked_id" -f blockingIssueId="$blocker_id" || iss_gql_fail
  if [ "$side" = blocked ]; then
    iss_lookup "$bo" "$br" "$bn" "$side_sel"; sref=$EDGE_BLOCKED
  else
    iss_lookup "$xo" "$xr" "$xn" "$side_sel"; sref=$EDGE_BLOCKER
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
  local po pr pn co cr cn parent_id parent_url child_id cur_id cur_num cur_nwo cref pref
  iss_parse_operand "$1" local-only; po=$OP_OWNER; pr=$OP_REPO; pn=$OP_NUMBER
  iss_parse_operand "$2" local-only; co=$OP_OWNER; cr=$OP_REPO; cn=$OP_NUMBER
  pref=$(iss_ref "$po" "$pr" "$pn")
  cref=$(iss_ref "$co" "$cr" "$cn")
  iss_lookup "$po" "$pr" "$pn" "id url"
  parent_id=$(iss_jq .id); parent_url=$(iss_jq .url)
  iss_lookup "$co" "$cr" "$cn" "$ISS_SEL_PARENT"
  child_id=$(iss_jq .id)
  cur_id=$(iss_jq '.parent.id // empty')
  if [ "$cur_id" = "$parent_id" ]; then
    printf 'Issue %s is already a sub-issue of %s; no change.\n' "$cref" "$pref"
    return 0
  fi
  if [ -n "$cur_id" ]; then
    cur_num=$(iss_jq .parent.number)
    cur_nwo=$(iss_jq .parent.repository.nameWithOwner)
    iss_die "issue \`$cref\` already has parent \`$(iss_ref_nwo "$cur_nwo" "$cur_num")\`; remove it first with \`/issue-unset-parent $cn\` before setting a new parent"
  fi
  iss_gql -f query="$ISS_DOC_ADD_SUB_ISSUE" -f parentId="$parent_id" -f childId="$child_id" || iss_gql_fail
  iss_lookup "$co" "$cr" "$cn" "$ISS_SEL_PARENT"
  cur_id=$(iss_jq '.parent.id // empty')
  [ "$cur_id" = "$parent_id" ] || iss_err_write_not_landed "the parent" "$cref" "$pref" "${cur_id:-(none)}"
  printf 'Linked issue %s as a sub-issue of %s.\n%s\n' "$cref" "$pref" "$parent_url"
}

# iss_remove_sub_issue <owner> <repo> <child-number> <child-id> <parent-id>
# <child-ref> <parent-ref>: remove the edge, then re-read the child and abort
# when it still has that parent.
iss_remove_sub_issue() {
  local cur_id
  iss_gql -f query="$ISS_DOC_REMOVE_SUB_ISSUE" -f parentId="$5" -f childId="$4" || iss_gql_fail
  iss_lookup "$1" "$2" "$3" "$ISS_SEL_PARENT"
  cur_id=$(iss_jq '.parent.id // empty')
  [ "$cur_id" != "$5" ] || iss_err_write_not_landed "the parent" "$6" "(none)" "$7"
}

# ---------------------------------------------------------------------------
# User-config: the default-assignee read.
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

# iss_default_assignee [global-only]: default-assignee from the repo-level
# user-config, then the user-global one, then the authenticated gh user.
# With global-only, the repo-level file is not consulted. Callers run it in a
# command substitution and exit on a non-zero status, which is an abort
# already reported on stderr.
iss_default_assignee() {
  local v rc
  if [ "${1:-}" != global-only ] && [ -n "${ISS_REPO_ROOT:-}" ]; then
    v=$(iss_user_config_get "$ISS_REPO_ROOT/.issues/user-config.md" /user-config default-assignee)
    rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || exit 1
    if [ "$rc" -eq 0 ] && [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  fi
  v=$(iss_user_config_get "${XDG_CONFIG_HOME:-$HOME/.config}/issues/user-config.md" /global-user-config default-assignee)
  rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || exit 1
  if [ "$rc" -eq 0 ] && [ -n "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  gh api user --jq .login || iss_die "could not resolve the authenticated GitHub user with \`gh api user\`"
}
