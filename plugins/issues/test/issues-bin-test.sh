#!/usr/bin/env bash
#
# issues-bin-test.sh -- drive every script in plugins/issues/bin/, under the
# bash 3.2 macOS ships, against fake-gh.py: a `gh` on PATH backed by a small
# in-memory GitHub persisted in a JSON file. Each new_case starts from the same
# fixture state and its own sandbox git repo, so no case sees another case's
# writes and no case reaches the real GitHub; the runs inside one case share
# its state and build on each other.
#
# Usage: issues-bin-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$TEST_DIR/../bin"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/issues-bin-test.XXXXXX")"
FAILURES=0
CASES=0

VERBS="issue-close issue-comment issue-create issue-field-options issue-set-blocked-by issue-set-blocks
issue-set-child issue-set-parent issue-set-priority issue-set-size issue-set-status issue-set-type
issue-sub-list issue-unset-blocked-by issue-unset-blocks issue-unset-child issue-unset-parent
issue-update issue-view issue-view-tree"

mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/gh" <<EOF
#!/bin/sh
exec python3 "$TEST_DIR/fake-gh.py" "\$@"
EOF
chmod +x "$SANDBOX/bin/gh"

FRONT_MATTER='---
schema-version: 7
source-control: GitHub
issues: GitHub
issue-link-prefix: "#"
default-issue-source-branch: main
default-pr-target-branch: main
issue-branch-naming-prefix: none
---
'

CONFIG_MAIN="$FRONT_MATTER
github-project:
  project-id: PVT_1
  fields:
    status:
      kind: single-select
      id: PVTSSF_status
      default: Backlog
      options:
        Backlog:     OPT_backlog
        In progress: OPT_inprogress
        Done:        OPT_done
    priority:
      kind: issue-field
      data-type: single-select
      field-id: IFSS_priority
      field-name: Priority
      default: Medium
      options:
        High:   IFSSO_high
        Medium: IFSSO_medium
        Low:    IFSSO_low
    size:
      kind: label
      namespace: \"size:\"
      default: M
      options: [S, M, L]
  issue-types:
    default: Feature
    Bug:       IT_bug
    Feature:   IT_feature
    Tech Debt: IT_debt

# Repo Config

Never hand-edit this file — re-run \`/repo-config\`."

CONFIG_NUMBER="$FRONT_MATTER
github-project:
  project-id: PVT_1
  fields:
    priority:
      kind: number
      id: PVTF_prio
      default: 3
      min: 1
      max: 9
    size:
      kind: skip
  issue-types:
    default: Bug
    Bug:       IT_bug
"

CONFIG_NO_BLOCK="$FRONT_MATTER
# Repo Config
"

# The fixture: acme/widgets is the current repo, acme/other a second one.
BASE_STATE="$SANDBOX/base-state.json"
python3 - "$BASE_STATE" "$CONFIG_MAIN" "$(printf '%s\n' "$FRONT_MATTER" | sed 's/^issues: GitHub$/issues: Jira/')" <<'PY'
import json, sys
path, config, jira_config = sys.argv[1], sys.argv[2], sys.argv[3]
def issue(repo, n, title, **kw):
    d = {"id": "I_%s_%d" % (repo.replace("/", "_"), n), "number": n, "title": title, "body": "Body of %d.\n" % n,
         "state": "OPEN", "labels": [], "assignees": [], "blockedBy": [], "projectItems": [], "issueFields": {}}
    d.update(kw)
    return d
widgets = {str(n): issue("acme/widgets", n, "Widget issue %d" % n) for n in range(1, 11)}
widgets["2"]["labels"] = ["bug", "size:S"]
widgets["2"]["assignees"] = ["octocat"]
widgets["2"]["issueType"] = "IT_bug"
widgets["2"]["projectItems"] = [{"id": "PVTI_2", "project": "PVT_1",
                                  "fields": {"PVTSSF_status": {"name": "In progress", "optionId": "OPT_inprogress"}}}]
widgets["2"]["issueFields"] = {"IFSS_priority": {"name": "High", "optionId": "IFSSO_high"}}
widgets["2"]["parent"] = "I_acme_widgets_1"
widgets["2"]["blockedBy"] = ["I_acme_other_3"]
widgets["4"]["labels"] = ["size:S", "size:L"]
widgets["5"]["viewerCanSetFields"] = False
# A parent-to-child chain 1 -> 6 -> 7 -> 8 -> 9 -> 10 -> 11: walked from 1,
# issue 10 sits at depth 5, so its child 11 falls past the depth cap.
for child, parent in (("6", "1"), ("7", "6"), ("8", "7"), ("9", "8"), ("10", "9")):
    widgets[child]["parent"] = "I_acme_widgets_" + parent
# Every connection a script reads runs past one page of 100 somewhere: issue
# 3's sub-issues; issue 12's labels, assignees, blocked-by and blocking edges,
# its project items on other boards before the one on PVT_1, that item's field
# values before its status, and its native field values before its priority.
# Each value the tests read sits past page one.
big = {}
for n in range(100, 210):
    big[str(n)] = issue("acme/widgets", n, "Child %d" % n, parent="I_acme_widgets_3", blockedBy=["I_acme_widgets_12"])
widgets.update(big)
widgets["11"] = issue("acme/widgets", 11, "Leaf", parent="I_acme_widgets_10")
many_fields = {"PVTF_other%d" % n: {"number": n} for n in range(110)}
many_fields["PVTSSF_status"] = {"name": "In progress", "optionId": "OPT_inprogress"}
many_issue_fields = {"IFSS_other%d" % n: {"name": "x", "optionId": "IFSSO_x"} for n in range(105)}
many_issue_fields["IFSS_priority"] = {"name": "High", "optionId": "IFSSO_high"}
widgets["12"] = issue(
    "acme/widgets", 12, "Many of everything",
    labels=["lbl-%03d" % n for n in range(119)] + ["size:L"],
    assignees=["user-%03d" % n for n in range(1, 106)],
    blockedBy=["I_acme_widgets_%d" % n for n in range(100, 210)],
    projectItems=[{"id": "PVTI_12_%d" % n, "project": "PVT_other%d" % n, "fields": {}} for n in range(105)]
    + [{"id": "PVTI_12", "project": "PVT_1", "fields": many_fields}],
    issueFields=many_issue_fields)
state = {
    "current": "acme/widgets",
    "user": "octocat",
    "repos": {
        "acme/widgets": {"issues": widgets, "config": config,
                         "validLabels": ["bug", "docs", "size:S", "size:M", "size:L"],
                         "collaborators": ["octocat", "hubot"] + ["user-%03d" % n for n in range(1, 106)]},
        "acme/other": {"issues": {"3": issue("acme/other", 3, "Other repo issue")}, "config": None,
                       "validLabels": ["bug"], "collaborators": ["octocat"]},
        "acme/stale": {"issues": {}, "config": "---\nschema-version: 5\n---\n", "validLabels": [],
                       "collaborators": ["octocat"]},
        "acme/jira": {"issues": {}, "config": jira_config, "validLabels": [], "collaborators": ["octocat"]},
    },
    "projectFields": ["PVTSSF_status", "PVTF_prio"] + list(many_fields),
    "projectOptions": {"OPT_backlog": "Backlog", "OPT_inprogress": "In progress", "OPT_done": "Done"},
    "issueFieldIds": ["IFSS_priority"],
    "issueFieldOptions": {"IFSSO_high": "High", "IFSSO_medium": "Medium", "IFSSO_low": "Low"},
    "issueTypes": {"IT_bug": "Bug", "IT_feature": "Feature", "IT_debt": "Tech Debt"},
}
json.dump(state, open(path, "w"), indent=1)
PY

# new_case <config-text or "none">: a fresh repo, state and call log.
new_case() {
  CASES=$((CASES + 1))
  CASE_DIR="$SANDBOX/case-$CASES"
  mkdir -p "$CASE_DIR/repo"
  git -C "$CASE_DIR/repo" init -q
  if [ "$1" != none ]; then
    mkdir -p "$CASE_DIR/repo/.issues"
    printf '%s\n' "$1" >"$CASE_DIR/repo/.issues/repo-config.md"
  fi
  cp "$BASE_STATE" "$CASE_DIR/state.json"
  : >"$CASE_DIR/gh.log"
}

# run <verb> <args...>: run a script under /bin/bash in the case repo; sets
# RC and OUT (stdout and stderr together).
run() {
  local verb=$1
  shift
  OUT=$(cd "$CASE_DIR/repo" &&
    PATH="$SANDBOX/bin:$PATH" FAKE_GH_STATE="$CASE_DIR/state.json" FAKE_GH_LOG="$CASE_DIR/gh.log" \
    XDG_CONFIG_HOME="$CASE_DIR/xdg" GIT_CEILING_DIRECTORIES="$SANDBOX" \
    /bin/bash "$BIN/$verb" "$@" 2>&1)
  RC=$?
}

pass() { echo "PASS  $1"; }
failed() {
  echo "FAIL  $1"
  echo "      $2"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
  FAILURES=$((FAILURES + 1))
}

# expect <name> <rc> <substring>...: RC is <rc> and OUT holds each substring.
expect() {
  local name=$1 rc=$2 s
  shift 2
  if [ "$RC" != "$rc" ]; then failed "$name" "expected exit $rc, got $RC"; return; fi
  for s in "$@"; do
    case "$OUT" in
      *"$s"*) ;;
      *) failed "$name" "missing: $s"; return ;;
    esac
  done
  pass "$name"
}

# expect_absent <name> <substring>: OUT does not hold it.
expect_absent() {
  case "$OUT" in
    *"$2"*) failed "$1" "unexpected: $2" ;;
    *) pass "$1" ;;
  esac
}

# state <jq-program>: query the case's fake GitHub.
state() {
  jq -r "$1" "$CASE_DIR/state.json"
}

# check <actual> <expected> <name>: the two strings are equal.
check() {
  if [ "$1" = "$2" ]; then pass "$3"; else OUT="expected: $2${ISS_NL}actual:   $1"; failed "$3" "state mismatch"; fi
}
ISS_NL='
'

# args_for <verb>: sets ARGS to arguments that pass the verb's usage check,
# so a gate case reaches the repo-config read rather than stopping at usage.
args_for() {
  case "$1" in
    issue-field-options) ARGS=(status) ;;
    issue-create) ARGS=(--title x --body-file x) ;;
    issue-comment) ARGS=(2 --body-file x) ;;
    issue-update) ARGS=(2 --title x) ;;
    issue-set-blocked-by|issue-set-blocks|issue-unset-blocked-by|issue-unset-blocks|issue-set-child|issue-set-parent|issue-unset-child)
      ARGS=(2 3) ;;
    issue-set-priority|issue-set-size|issue-set-status|issue-set-type) ARGS=(2 x) ;;
    *) ARGS=(2) ;;
  esac
}

# ---------------------------------------------------------------------------
# Every script: the repo-config and tracker gates.
# ---------------------------------------------------------------------------

for verb in $VERBS; do
  new_case none
  args_for "$verb"
  run "$verb" "${ARGS[@]}"
  expect "$verb: missing repo-config" 1 "This repo has no \`.issues/repo-config.md\`. Run \`/repo-config\` to create one."

  new_case "---
schema-version: 5
source-control: GitHub
---"
  args_for "$verb"
  run "$verb" "${ARGS[@]}"
  expect "$verb: stale schema-version" 1 "is at schema-version \`5\`; this skill requires \`6\`"

  new_case "---
source-control: GitHub
---"
  args_for "$verb"
  run "$verb" "${ARGS[@]}"
  expect "$verb: absent schema-version" 1 "predates schema versioning"

  new_case "$(printf '%s\n' "$FRONT_MATTER" | sed 's/^issues: GitHub$/issues: Jira/')"
  args_for "$verb"
  run "$verb" "${ARGS[@]}"
  expect "$verb: Jira exits non-zero" 1 "\`issues: Jira\` is configured, and this script serves only the GitHub backend."
  check "$(wc -l <"$CASE_DIR/gh.log" | tr -d ' ')" 0 "$verb: Jira makes no gh call"
done

for verb in issue-close issue-set-status issue-set-type issue-sub-list issue-unset-parent issue-update issue-view issue-view-tree; do
  new_case "$CONFIG_MAIN"
  case "$verb" in
    issue-set-status) run "$verb" 999 Done ;;
    issue-set-type) run "$verb" 999 Bug ;;
    issue-update) run "$verb" 999 --title x ;;
    *) run "$verb" 999 ;;
  esac
  expect "$verb: issue not found" 1 "issue \`#999\` not found in \`acme/widgets\`"
done

new_case "$(printf '%s\n' "$FRONT_MATTER" | sed 's/^issue-link-prefix.*$//')"
run issue-view 2
expect "incomplete front-matter names the field" 1 "is missing the canonical field \`issue-link-prefix\`"

# ---------------------------------------------------------------------------
# Reads.
# ---------------------------------------------------------------------------

new_case "$CONFIG_MAIN"
run issue-view 2
expect "issue-view: full block" 0 \
  "#2 Widget issue 2    (OPEN)" "https://github.com/acme/widgets/issues/2" \
  "Labels:     bug, size:S" "Assignees:  octocat" "Type:       Bug" \
  "Status:     In progress" "Priority:   High" "Size:       S" \
  "Parent:     #1 Widget issue 1" "Blocked by:${ISS_NL}  - acme/other#3 Other repo issue" \
  "Sub-issues:${ISS_NL}  (none)" "Body:${ISS_NL}Body of 2."

run issue-view 4
expect "issue-view: two size labels read (multiple), off-board status" 0 \
  "Size:       (multiple)" "Status:     (not on project board)" "Priority:   (none)" "Parent:     (none)"

new_case "$CONFIG_NO_BLOCK"
run issue-view 2
expect_absent "issue-view: no github-project block omits slot rows" "Status:"

new_case "$CONFIG_MAIN"
run issue-sub-list 3
expect "issue-sub-list: pages past one page" 0 "Sub-issues of #3 \"Widget issue 3\":" "  - #100 Child 100" "  - #209 Child 209"
check "$(printf '%s\n' "$OUT" | grep -c '^  - ')" 110 "issue-sub-list: all 110 children listed"
run issue-sub-list 2
expect "issue-sub-list: none" 0 "  (none)"

run issue-view-tree 1
expect "issue-view-tree: walks and caps depth" 0 \
  "#1 Widget issue 1  https://github.com/acme/widgets/issues/1" \
  "  #2 Widget issue 2  " "    Blocked by:${ISS_NL}      - acme/other#3 Other repo issue" \
  "          #10 Widget issue 10  " "            ... (depth cap)"
expect_absent "issue-view-tree: nothing past the cap" "#11 Leaf"

new_case "$CONFIG_MAIN"
run issue-field-options
expect "issue-field-options: every slot" 0 \
  "status: single-select (default: Backlog)${ISS_NL}  Backlog${ISS_NL}  In progress${ISS_NL}  Done" \
  "priority: issue-field (default: Medium)${ISS_NL}  High${ISS_NL}  Medium${ISS_NL}  Low" \
  "size: label (default: M)${ISS_NL}  S${ISS_NL}  M${ISS_NL}  L"
run issue-field-options effort
expect "issue-field-options: unconfigured slot" 0 "effort: unconfigured"
check "$(wc -l <"$CASE_DIR/gh.log" | tr -d ' ')" 0 "issue-field-options: makes no gh call"

new_case "$(printf '%s\n' "$CONFIG_MAIN" | sed -e 's/default: Backlog/default: in PROGRESS/' -e '/default: Medium/d')"
run issue-field-options
expect "issue-field-options: a default in the options' own capitalization" 0 \
  "status: single-select (default: In progress)${ISS_NL}  Backlog" "priority: issue-field${ISS_NL}  High"
expect_absent "issue-field-options: no default reported for a slot without one" "priority: issue-field ("

new_case "$CONFIG_NUMBER"
run issue-field-options
expect "issue-field-options: number bounds and skip" 0 "priority: number (default: 3)${ISS_NL}  min: 1${ISS_NL}  max: 9" "size: unconfigured"
new_case "$CONFIG_NO_BLOCK"
run issue-field-options
expect "issue-field-options: no block" 0 "No fields configured."
run issue-field-options --repo acme/widgets
expect "issue-field-options --repo: the target's slots, not this repo's" 0 \
  "status: single-select (default: Backlog)${ISS_NL}  Backlog${ISS_NL}  In progress${ISS_NL}  Done" \
  "priority: issue-field (default: Medium)${ISS_NL}  High${ISS_NL}  Medium${ISS_NL}  Low" \
  "size: label (default: M)${ISS_NL}  S${ISS_NL}  M${ISS_NL}  L"
check "$(grep -c '"repos/acme/widgets/contents/.issues/repo-config.md"' "$CASE_DIR/gh.log")" 1 \
  "issue-field-options --repo: reads the target's repo-config"
run issue-field-options --repo acme/widgets size
expect "issue-field-options --repo: one slot, flag first" 0 "size: label (default: M)${ISS_NL}  S${ISS_NL}  M${ISS_NL}  L"
expect_absent "issue-field-options --repo: only the named slot" "status:"
run issue-field-options --repo acme/other
expect "issue-field-options --repo: target without repo-config" 0 "No fields configured."
run issue-field-options status --repo acme/other
expect "issue-field-options --repo: a slot in a target without repo-config" 0 "status: unconfigured"
run issue-field-options --repo acme/stale
expect "issue-field-options --repo: stale target schema aborts" 1 \
  "target repo \`acme/stale\`: This repo's \`.issues/repo-config.md\` is at schema-version \`5\`"
run issue-field-options --repo acme/jira
expect "issue-field-options --repo: Jira target exits non-zero" 1 \
  "\`issues: Jira\` is configured, and this script serves only the GitHub backend."
run issue-field-options --repo widgets
expect "issue-field-options --repo: not owner/repo" 2 "\`--repo\` takes owner/repo"
run issue-field-options status priority
expect "issue-field-options: two slots is a usage error" 2 "usage: issue-field-options"

new_case "$(printf '%s\n' "$FRONT_MATTER" | sed 's/^issues: GitHub$/issues: Jira/')"
run issue-field-options status --repo acme/widgets
expect "issue-field-options --repo: the invoking repo's tracker is not read" 0 \
  "status: single-select (default: Backlog)${ISS_NL}  Backlog${ISS_NL}  In progress${ISS_NL}  Done"
new_case none
run issue-field-options priority --repo acme/widgets
expect "issue-field-options --repo: no local repo-config needed" 0 "priority: issue-field (default: Medium)${ISS_NL}  High"

# ---------------------------------------------------------------------------
# A slot default: the slot would refuse is an invalid repo-config.
# ---------------------------------------------------------------------------

# bad_default <name> <config> <slot> <default> <accepts>: every script refuses
# the config with the one error, before any gh call.
bad_default() {
  local name=$1 config=$2 msg
  msg="sets \`$3\`'s \`default:\` to \`$4\`, which is not $5. Run \`/repo-config\` to fix it."
  new_case "$config"
  run issue-field-options
  expect "invalid default, $name: issue-field-options refuses it" 1 "$msg"
  run issue-create --title x --body-file x
  expect "invalid default, $name: issue-create refuses it" 1 "$msg"
  run issue-view 2
  expect "invalid default, $name: issue-view refuses it" 1 "$msg"
  check "$(wc -l <"$CASE_DIR/gh.log" | tr -d ' ')" 0 "invalid default, $name: no gh call"
}
bad_default "number above max" "$(printf '%s\n' "$CONFIG_NUMBER" | sed 's/default: 3/default: 12/')" \
  priority 12 "an integer in \`[1, 9]\`"
bad_default "number below min" "$(printf '%s\n' "$CONFIG_NUMBER" | sed 's/default: 3/default: 0/')" \
  priority 0 "an integer in \`[1, 9]\`"
bad_default "number not an integer" "$(printf '%s\n' "$CONFIG_NUMBER" | sed 's/default: 3/default: three/')" \
  priority three "an integer in \`[1, 9]\`"
bad_default "single-select" "$(printf '%s\n' "$CONFIG_MAIN" | sed 's/default: Backlog/default: Blocked/')" \
  status Blocked "one of its options: \`Backlog, In progress, Done\`"
bad_default "issue-field" "$(printf '%s\n' "$CONFIG_MAIN" | sed 's/default: Medium/default: Urgent/')" \
  priority Urgent "one of its options: \`High, Medium, Low\`"
bad_default "label" "$(printf '%s\n' "$CONFIG_MAIN" | sed 's/default: M$/default: XL/')" \
  size XL "one of its options: \`S, M, L\`"

bad_default "number a float" "$(printf '%s\n' "$CONFIG_NUMBER" | sed 's/default: 3/default: 3.5/')" \
  priority 3.5 "an integer in \`[1, 9]\`"

new_case "$(printf '%s\n' "$CONFIG_NUMBER" | sed -e 's/default: 3/default: 9/')"
run issue-field-options
expect "valid default: a number default at max is accepted" 0 "priority: number (default: 9)"

# bad_range <name> <config> <min> <max>: every script refuses a number slot
# whose range makes no sense, with the one error naming the slot.
bad_range() {
  local name=$1 config=$2 msg
  msg="sets \`priority\`'s range to \`[$3, $4]\`, which is not an integer range with \`min:\` at most \`max:\`."
  new_case "$config"
  run issue-field-options
  expect "invalid range, $name: issue-field-options refuses it" 1 "$msg"
  run issue-set-priority 2 3
  expect "invalid range, $name: issue-set-priority refuses it" 1 "$msg"
  run issue-view 2
  expect "invalid range, $name: issue-view refuses it" 1 "$msg"
  check "$(wc -l <"$CASE_DIR/gh.log" | tr -d ' ')" 0 "invalid range, $name: no gh call"
}
bad_range "float min" "$(printf '%s\n' "$CONFIG_NUMBER" | sed 's/min: 1$/min: 0.5/')" 0.5 9
bad_range "float max" "$(printf '%s\n' "$CONFIG_NUMBER" | sed 's/max: 9$/max: 9.5/')" 1 9.5
bad_range "min above max" "$(printf '%s\n' "$CONFIG_NUMBER" | sed -e 's/min: 1$/min: 9/' -e 's/max: 9$/max: 1/')" 9 1
bad_range "float bound, no default" \
  "$(printf '%s\n' "$CONFIG_NUMBER" | sed -e '/default: 3/d' -e 's/max: 9$/max: 9.5/')" 1 9.5
bad_range "float bound, other bound absent" \
  "$(printf '%s\n' "$CONFIG_NUMBER" | sed -e '/max: 9$/d' -e 's/min: 1$/min: 1.5/')" 1.5 inf

new_case none
jq '.repos["acme/widgets"].config |= sub("default: M\n"; "default: XL\n")' "$CASE_DIR/state.json" >"$CASE_DIR/state.new" &&
  mv "$CASE_DIR/state.new" "$CASE_DIR/state.json"
run issue-field-options --repo acme/widgets
expect "invalid default --repo: issue-field-options refuses the target's config" 1 \
  "target repo \`acme/widgets\`: This repo's \`.issues/repo-config.md\` sets \`size\`'s \`default:\` to \`XL\`"
run issue-create --title x --body-file x --repo acme/widgets
expect "invalid default --repo: issue-create refuses the target's config" 1 \
  "target repo \`acme/widgets\`: This repo's \`.issues/repo-config.md\` sets \`size\`'s \`default:\` to \`XL\`"

# ---------------------------------------------------------------------------
# repo-config-write: a draft is written only when it passes the loader checks.
# ---------------------------------------------------------------------------

# refuse_write <name> <draft> <substring>: the writer refuses the draft with
# the substring, and the repo keeps the config it had.
refuse_write() {
  new_case "$CONFIG_MAIN"
  printf '%s\n' "$2" >"$CASE_DIR/draft.md"
  run repo-config-write "$CASE_DIR/draft.md"
  expect "repo-config-write, $1: refused" 1 "refusing to write the draft" "$3"
  check "$(cat "$CASE_DIR/repo/.issues/repo-config.md")" "$CONFIG_MAIN" "repo-config-write, $1: config unchanged"
  check "$(ls -A "$CASE_DIR/repo/.issues")" "repo-config.md" "repo-config-write, $1: no file left behind"
}
refuse_write "float min" "$(printf '%s\n' "$CONFIG_NUMBER" | sed 's/min: 1$/min: 0.5/')" \
  "sets \`priority\`'s range to \`[0.5, 9]\`"
refuse_write "float max" "$(printf '%s\n' "$CONFIG_NUMBER" | sed 's/max: 9$/max: 9.5/')" \
  "sets \`priority\`'s range to \`[1, 9.5]\`"
refuse_write "min above max" "$(printf '%s\n' "$CONFIG_NUMBER" | sed -e 's/min: 1$/min: 9/' -e 's/max: 9$/max: 1/')" \
  "sets \`priority\`'s range to \`[9, 1]\`"
refuse_write "float default" "$(printf '%s\n' "$CONFIG_NUMBER" | sed 's/default: 3/default: 3.5/')" \
  "sets \`priority\`'s \`default:\` to \`3.5\`"
refuse_write "number default out of range" "$(printf '%s\n' "$CONFIG_NUMBER" | sed 's/default: 3/default: 12/')" \
  "sets \`priority\`'s \`default:\` to \`12\`, which is not an integer in \`[1, 9]\`"
refuse_write "default outside the options" "$(printf '%s\n' "$CONFIG_MAIN" | sed 's/default: M$/default: XL/')" \
  "sets \`size\`'s \`default:\` to \`XL\`, which is not one of its options: \`S, M, L\`"
refuse_write "stale schema" "$(printf '%s\n' "$CONFIG_MAIN" | sed 's/^schema-version: 7$/schema-version: 5/')" \
  "is at schema-version \`5\`"
refuse_write "missing front-matter field" "$(printf '%s\n' "$CONFIG_MAIN" | sed '/^issue-branch-naming-prefix:/d')" \
  "missing the canonical field \`issue-branch-naming-prefix\`"

new_case none
run repo-config-write "$CASE_DIR/nosuch.md"
expect "repo-config-write: a missing draft is refused" 1 "draft \`$CASE_DIR/nosuch.md\` does not exist"
check "$(ls -A "$CASE_DIR/repo")" ".git" "repo-config-write: nothing written for a missing draft"
run repo-config-write
expect "repo-config-write: usage" 2 "usage: repo-config-write <draft-path>"

new_case none
printf '%s\n' "$CONFIG_NUMBER" >"$CASE_DIR/draft.md"
run repo-config-write "$CASE_DIR/draft.md"
expect "repo-config-write: a valid draft is written" 0 "Wrote "
check "$(cmp "$CASE_DIR/draft.md" "$CASE_DIR/repo/.issues/repo-config.md" && echo same)" same \
  "repo-config-write: the file is the draft, byte for byte"
run issue-field-options priority
expect "repo-config-write: the written file reads" 0 "priority: number (default: 3)${ISS_NL}  min: 1${ISS_NL}  max: 9"

new_case "$CONFIG_NUMBER"
printf '%s\n' "$FRONT_MATTER" | sed 's/^issues: GitHub$/issues: Jira/' >"$CASE_DIR/draft.md"
run repo-config-write "$CASE_DIR/draft.md"
expect "repo-config-write: a Jira draft replaces the config" 0 "Wrote "
check "$(grep -c '^issues: Jira$' "$CASE_DIR/repo/.issues/repo-config.md")" 1 "repo-config-write: the Jira file landed"

# ---------------------------------------------------------------------------
# Set-slot verbs.
# ---------------------------------------------------------------------------

new_case "$CONFIG_MAIN"
run issue-set-status 3 "in PROGRESS"
expect "issue-set-status: adds to board and sets canonical name" 0 \
  "Set status on issue #3 to In progress." "https://github.com/acme/widgets/issues/3"
check "$(state '.repos["acme/widgets"].issues["3"].projectItems[0].fields.PVTSSF_status.name')" "In progress" \
  "issue-set-status: value landed"
run issue-set-status 3 Nope
expect "issue-set-status: unknown option" 1 "value \`Nope\` is not in \`status\`'s options. Known options: \`Backlog, In progress, Done\`."

run issue-set-priority 3 low
expect "issue-set-priority issue-field: set" 0 "#3 priority set to Low."
run issue-set-priority 3 LOW
expect "issue-set-priority issue-field: no-op" 0 "#3 priority already set to Low."
run issue-set-priority 3 7
expect "issue-set-priority issue-field: number input is a kind mismatch" 1 \
  "was called with a number, but this repo's \`priority\` is configured as \`kind: issue-field\`"
run issue-set-priority 5 High
expect "issue-set-priority issue-field: viewerCanSetFields false" 1 "cannot set native issue field \`Priority\` on issue \`#5\`"

run issue-set-size 4 m
expect "issue-set-size label: converges to one label" 0 "#4 size set to M (via label \`size:M\`)."
check "$(state '.repos["acme/widgets"].issues["4"].labels | sort | join(",")')" "size:M" "issue-set-size label: extras removed"
run issue-set-size 4 M
expect "issue-set-size label: no-op" 0 "#4 size already set to M (via label \`size:M\`)."

new_case "$CONFIG_NUMBER"
run issue-set-priority 2 5
expect "issue-set-priority number: set" 0 "#2 priority set to 5."
check "$(state '.repos["acme/widgets"].issues["2"].projectItems[0].fields.PVTF_prio.number')" "5.0" "issue-set-priority number: landed"
run issue-set-priority 2 10
expect "issue-set-priority number: out of range" 1 "value \`10\` for \`priority\` is out of range. Expected an integer in \`[1, 9]\`."
run issue-set-priority 2 three
expect "issue-set-priority number: non-integer is out of range" 1 "value \`three\` for \`priority\`"
run issue-set-priority 3 2.5
expect "issue-set-priority number: a float is out of range" 1 \
  "value \`2.5\` for \`priority\` is out of range. Expected an integer in \`[1, 9]\`."
run issue-set-size 2 M
expect "issue-set-size: kind skip warns and exits zero" 0 \
  "\`/issue-set-size\` has nothing to do: this repo has no \`size\` slot configured."
run issue-set-status 2 Done
expect "issue-set-status: absent slot warns and exits zero" 0 "has no \`status\` slot configured"

new_case "$CONFIG_NO_BLOCK"
run issue-set-priority 2 High
expect "issue-set-priority: no block aborts" 1 "no \`github-project:\` block in \`repo-config.md\`; run \`/repo-config\` to add it"

new_case "$(printf '%s\n' "$CONFIG_MAIN" | sed 's/PVTSSF_status/PVTSSF_gone/')"
run issue-set-status 2 Done
expect "issue-set-status: stale field ID" 1 "project field \`PVTSSF_gone\` no longer exists on project \`PVT_1\`"

new_case "$CONFIG_MAIN"
run issue-set-type 3 "tech debt"
expect "issue-set-type: set" 0 "#3 type set to Tech Debt."
run issue-set-type 3 "Tech Debt"
expect "issue-set-type: no-op" 0 "#3 type already set to Tech Debt."
run issue-set-type 3 Epic
expect "issue-set-type: unknown type" 1 "issue type \`Epic\` not in repo's \`github-project.issue-types\`. Known types: \`Bug, Feature, Tech Debt\`"

# ---------------------------------------------------------------------------
# Relationships.
# ---------------------------------------------------------------------------

new_case "$CONFIG_MAIN"
run issue-set-parent 5 4
expect "issue-set-parent: link" 0 "Linked issue #5 as a sub-issue of #4." "https://github.com/acme/widgets/issues/4"
run issue-set-child 4 5
expect "issue-set-child: same edge is a no-op" 0 "Issue #5 is already a sub-issue of #4; no change."
run issue-set-parent 5 3
expect "issue-set-parent: single-parent conflict" 1 \
  "issue \`#5\` already has parent \`#4\`; remove it first with \`/issue-unset-parent 5\` before setting a new parent"
run issue-unset-child 3 5
expect "issue-unset-child: other parent is a no-op" 0 "Issue #5 is not a sub-issue of #3; no change."
run issue-unset-child 4 5
expect "issue-unset-child: remove" 0 "Removed issue #5 as a sub-issue of #4."
run issue-unset-parent 5
expect "issue-unset-parent: none is a no-op" 0 "Issue #5 has no parent; no change."
run issue-unset-parent 2
expect "issue-unset-parent: remove" 0 "Removed issue #2 as a sub-issue of #1." "https://github.com/acme/widgets/issues/2"

run issue-set-blocked-by 4 acme/other#3
expect "issue-set-blocked-by: cross-repo" 0 "Marked issue #4 as blocked by acme/other#3."
run issue-set-blocks acme/other#3 4
expect "issue-set-blocks: same edge is a no-op" 0 "Issue acme/other#3 already blocks #4; no change."
run issue-unset-blocks acme/other#3 4
expect "issue-unset-blocks: remove" 0 "Removed blocking relationship: issue acme/other#3 no longer blocks #4."
run issue-unset-blocked-by 4 acme/other#3
expect "issue-unset-blocked-by: absent edge is a no-op" 0 "Issue #4 is not blocked by acme/other#3; no change."
run issue-set-blocked-by 4 acme/other#99
expect "issue-set-blocked-by: operand not found names its repo" 1 "issue \`#99\` not found in \`acme/other\`"

# ---------------------------------------------------------------------------
# Comment, close, update.
# ---------------------------------------------------------------------------

new_case "$CONFIG_MAIN"
printf '  \n\t\n' >"$CASE_DIR/repo/blank.md"
run issue-comment 2 --body-file blank.md
expect "issue-comment: whitespace-only body refused" 1 "is empty or whitespace-only"
check "$(grep -c '"comment"' "$CASE_DIR/gh.log")" 0 "issue-comment: nothing posted for a blank body"
printf 'Looks good.\n' >"$CASE_DIR/repo/body.md"
run issue-comment 2 --body-file body.md
expect "issue-comment: posted" 0 "Commented on issue #2 \"Widget issue 2\"." "#issuecomment-"

run issue-close 2 --comment "Done here; fixes #7 and Resolves #8."
expect "issue-close: comment then close, closing-keyword note" 0 \
  "Closed issue #2 \"Widget issue 2\"." "comment: posted" "state:   CLOSED" \
  "note: your comment contained closing keyword(s) referencing #7, #8"
check "$(state '.repos["acme/widgets"].issues["2"].state')" CLOSED "issue-close: closed"

new_case "$CONFIG_MAIN"
run issue-update 3 --prepend "first" --append "last one"
expect "issue-update: prepend and append" 0 "body:            appended 1 line(s), prepended 1 line(s)"
check "$(state '.repos["acme/widgets"].issues["3"].body')" "first${ISS_NL}Body of 3.${ISS_NL}last one" "issue-update: body composed"
run issue-update 3 --body-file x --append y
expect "issue-update: --body-file with --append refused" 2 "cannot be combined"
run issue-update 3 --add-labels "docs,nosuch" --add-assignees "hubot,ghost"
expect "issue-update: mismatches reported and exit non-zero" 1 \
  "labels added:    docs" "labels requested but not added: nosuch (not a valid label on this repo)" \
  "assignees added: hubot" "assignees requested but not added: ghost"
run issue-update 3 --add-assignees @default-assignee
expect "issue-update: @default-assignee falls back to the gh user" 0 "assignees added: octocat"
mkdir -p "$CASE_DIR/repo/.issues"
printf -- '---\nschema-version: 1\ndefault-assignee: hubot\n---\n' >"$CASE_DIR/repo/.issues/user-config.md"
run issue-update 4 --add-assignees @default-assignee
expect "issue-update: @default-assignee from the repo-level user-config" 0 "assignees added: hubot"
printf -- '---\ndefault-assignee: hubot\n---\n' >"$CASE_DIR/repo/.issues/user-config.md"
run issue-update 4 --add-assignees @default-assignee
expect "issue-update: unversioned user-config aborts" 1 "predates user-config schema versioning"

# ---------------------------------------------------------------------------
# Create.
# ---------------------------------------------------------------------------

new_case "$CONFIG_MAIN"
printf 'New body.\n' >"$CASE_DIR/repo/new.md"
run issue-create --title "Make it" --body-file new.md --type bug --priority low --status Done --labels docs --parent 1
expect "issue-create: fully configured" 0 \
  "Created issue #210 \"Make it\"" "  type:       Bug" "  priority:   Low" "  size:       M" \
  "  status:     Done" "  assignee:   octocat" "  parent:     #1" "https://github.com/acme/widgets/issues/210"
check "$(state '.repos["acme/widgets"].issues["210"] | [.issueType, .issueFields.IFSS_priority.name, (.labels|sort|join(",")), .projectItems[0].fields.PVTSSF_status.name, .parent] | join(" ")')" \
  "IT_bug Low docs,size:M Done I_acme_widgets_1" "issue-create: every write landed"
run issue-create --title "Bad" --body-file new.md --priority Extreme
expect "issue-create: invalid value refused before creating" 1 "value \`Extreme\` is not in \`priority\`'s options"
check "$(state '.repos["acme/widgets"].issues | has("211")')" false "issue-create: nothing created on a bad value"

new_case "$CONFIG_NUMBER"
printf 'New body.\n' >"$CASE_DIR/repo/new.md"
run issue-create --title "Plain" --body-file new.md
expect "issue-create: skip and absent slots" 0 \
  "  type:       Bug" "  priority:   3" "  size:       skipped: slot kind: skip" "  status:     skipped: slot absent from fields:" \
  "warning: slot 'size' is kind: skip in repo-config.md; skipping --size." \
  "warning: slot 'status' is missing from fields: in repo-config.md; skipping --status."

new_case "$CONFIG_NO_BLOCK"
printf 'New body.\n' >"$CASE_DIR/repo/new.md"
run issue-create --title "Plain" --body-file new.md --repo acme/widgets
expect "issue-create --repo: target config used" 0 "  type:       Feature" "  priority:   Medium" "  status:     Backlog"
run issue-create --title "Elsewhere" --body-file new.md --repo acme/other --labels bug
expect "issue-create --repo: target without repo-config" 0 \
  "Created issue acme/other#4 \"Elsewhere\"" "  type:       skipped: target repo has no repo-config" \
  "note: project fields skipped: \`acme/other\` has no \`.issues/repo-config.md\`." "https://github.com/acme/other/issues/4"
check "$(state '.repos["acme/other"].issues["4"].labels | join(",")')" bug "issue-create --repo: labels applied"
run issue-create --title "Stale" --body-file new.md --repo acme/stale
expect "issue-create --repo: stale target schema aborts" 1 \
  "target repo \`acme/stale\`: This repo's \`.issues/repo-config.md\` is at schema-version \`5\`"
check "$(state '.repos["acme/stale"].issues | length')" 0 "issue-create --repo: nothing created in a stale target"

run issue-create --title "Tracked elsewhere" --body-file new.md --repo acme/jira
expect "issue-create --repo: Jira target exits non-zero" 1 \
  "\`issues: Jira\` is configured, and this script serves only the GitHub backend."
check "$(state '.repos["acme/jira"].issues | length')" 0 "issue-create --repo: nothing created in a Jira target"

new_case "$(printf '%s\n' "$FRONT_MATTER" | sed 's/^issues: GitHub$/issues: Jira/')"
printf 'New body.\n' >"$CASE_DIR/repo/new.md"
run issue-create --title "Elsewhere" --body-file new.md --repo acme/widgets
expect "issue-create --repo: the invoking repo's tracker is not read" 0 \
  "Created issue #210 \"Elsewhere\"" "  type:       Feature" "  status:     Backlog"

new_case "$CONFIG_MAIN"
printf 'New body.\n' >"$CASE_DIR/repo/new.md"
run issue-create --title "Labelled" --body-file new.md --labels docs,nosuch
expect "issue-create: a dropped label exits non-zero" 1 \
  "  labels:     docs, size:M (requested docs,nosuch; nosuch did not land)" \
  "label(s) nosuch did not land on issue \`#210\`"
expect_absent "issue-create: a dropped label is not a partial run" "the run stopped before finishing"

# ---------------------------------------------------------------------------
# Paging: every connection read runs to its end (see the fixture's #3, #12).
# ---------------------------------------------------------------------------

new_case "$CONFIG_MAIN"
run issue-view 12
expect "issue-view: labels, assignees and every slot read past page one" 0 \
  "lbl-118, size:L" "user-104, user-105" "Status:     In progress" "Priority:   High" "Size:       L"
check "$(printf '%s\n' "$OUT" | grep -c '^  - #')" 220 "issue-view: all 110 blocked-by and 110 blocking rows"
check "$(printf '%s\n' "$OUT" | grep -c '^  - #209 Child 209$')" 2 "issue-view: the last edge on each side"
run issue-view 3
check "$(printf '%s\n' "$OUT" | grep -c '^  - #')" 110 "issue-view: all 110 sub-issues"
run issue-view-tree 3
expect "issue-view-tree: walks every sub-issue" 0 "  #209 Child 209  "
check "$(printf '%s\n' "$OUT" | grep -c '^  #[0-9]* Child ')" 110 "issue-view-tree: 110 children walked"

run issue-set-size 12 L
expect "issue-set-size: a label past page one is already set" 0 "#12 size already set to L (via label \`size:L\`)."
run issue-set-priority 12 high
expect "issue-set-priority: a native field past page one is already set" 0 "#12 priority already set to High."
run issue-set-size 12 S
expect "issue-set-size: converges past page one" 0 "#12 size set to S (via label \`size:S\`)."
check "$(state '.repos["acme/widgets"].issues["12"].labels | map(select(startswith("size:"))) | join(",")')" "size:S" \
  "issue-set-size: the label past page one was removed"
run issue-set-status 12 Done
expect "issue-set-status: the board item past page one is written" 0 "Set status on issue #12 to Done."
check "$(state '.repos["acme/widgets"].issues["12"].projectItems | [length, (.[-1].fields.PVTSSF_status.name)] | map(tostring) | join(" ")')" \
  "106 Done" "issue-set-status: no second board item added"

run issue-update 12 --add-labels docs --remove-assignees user-105
expect "issue-update: a re-read past page one sees the change" 0 "labels added:    docs" "assignees removed: user-105"

run issue-unset-blocked-by 12 209
expect "issue-unset-blocked-by: an edge past page one is present" 0 "no longer blocked by #209"
check "$(state '.repos["acme/widgets"].issues["12"].blockedBy | length')" 109 "issue-unset-blocked-by: edge removed"
run issue-set-blocked-by 12 5
expect "issue-set-blocked-by: a write landing past page one is seen" 0 "Marked issue #12 as blocked by #5."
run issue-unset-blocks 12 209
expect "issue-unset-blocks: an edge past page one is present" 0 \
  "Removed blocking relationship: issue #12 no longer blocks #209."

# ---------------------------------------------------------------------------
# Every write is re-read: with writes dropped, each write verb fails.
# ---------------------------------------------------------------------------

export FAKE_GH_DROP_WRITES=1
new_case "$CONFIG_MAIN"
printf 'Hi.\n' >"$CASE_DIR/repo/body.md"
for call in "issue-set-status 2 Done" "issue-set-priority 3 Low" "issue-set-size 3 L" "issue-set-type 3 Feature" \
            "issue-set-parent 5 4" "issue-set-child 4 5" "issue-unset-parent 2" "issue-unset-child 1 2" \
            "issue-set-blocked-by 5 4" "issue-set-blocks 4 5" "issue-unset-blocked-by 2 acme/other#3" \
            "issue-unset-blocks acme/other#3 2" "issue-close 3" "issue-comment 3 --body-file body.md" \
            "issue-update 3 --title Renamed" "issue-create --title T --body-file body.md"; do
  run $call
  case "$call" in
    issue-update*) expect "${call%% *}: a dropped write exits non-zero" 1 "did not land" ;;
    issue-create*) expect "${call%% *}: a dropped write exits non-zero" 1 "the run stopped before finishing" ;;
    *) expect "${call%% *}: a dropped write exits non-zero" 1 "the write did not land" ;;
  esac
done
unset FAKE_GH_DROP_WRITES

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all cases passed"
  rm -rf "$SANDBOX"
  exit 0
fi
echo "$FAILURES failure(s); sandbox left at $SANDBOX"
exit 1
