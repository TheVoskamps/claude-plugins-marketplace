#!/usr/bin/env bash
#
# github-prs-test.sh -- drive every script in plugins/github-prs/bin/,
# under the bash 3.2 macOS ships, against a stub `gh` on PATH. The stub
# records each call's argv, keeps the PR's state in files so a mutating
# verb's re-read sees what the mutation left, and applies a call's
# `--jq` expression with the real `jq`, so the scripts' own filters run.
# A case that touches `noop` makes every mutation report success without
# landing as asked -- a create opens a PR that is not a draft, a comment
# carries other text, and every other mutation changes nothing -- which
# is how a change that did not land is staged.
#
# Needs jq and git on PATH. Reaches no network.
#
# Usage: github-prs-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$TEST_DIR/../bin"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/github-prs-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0

check() {
  if [ "$1" = "$2" ]; then
    echo "PASS  $3"
  else
    echo "FAIL  $3"
    echo "      expected: $2"
    echo "      actual:   $1"
    FAILURES=$((FAILURES + 1))
  fi
}

check_contains() {
  case "$1" in
    *"$2"*) echo "PASS  $3" ;;
    *)
      echo "FAIL  $3"
      echo "      expected to contain: $2"
      echo "      actual:              $1"
      FAILURES=$((FAILURES + 1))
      ;;
  esac
}

mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
S=$STUB_DIR
printf '%s\n' "$*" >>"$S/calls"

jq_expr=
prev=
body_file=
for a in "$@"; do
  [ "$prev" = --jq ] && jq_expr=$a
  [ "$prev" = --body-file ] && body_file=$a
  prev=$a
done
if [ "$body_file" = - ]; then
  cat >"$S/stdin"
  body_file="$S/stdin"
fi

if [ -f "$S/fail" ] && [ "$1 $2" = "$(cat "$S/fail")" ]; then
  echo "stub gh: $1 $2 refused" >&2
  exit 1
fi

out() { if [ -n "$jq_expr" ]; then jq -r "$jq_expr"; else cat; fi; }
landed() { [ ! -f "$S/noop" ]; }
val() { if [ -f "$S/$1" ]; then cat "$S/$1"; else printf '%s' "$2"; fi; }

pr_json() {
  views=$(($(val views 0) + 1))
  echo "$views" >"$S/views"
  mergeable=$(sed -n "${views}p" "$S/mergeable-seq" 2>/dev/null)
  [ -n "$mergeable" ] || mergeable=$(tail -n 1 "$S/mergeable-seq" 2>/dev/null)
  [ -n "$mergeable" ] || mergeable=MERGEABLE
  jq -n \
    --arg body "$(val body '')" \
    --argjson draft "$(val draft true)" \
    --arg author "$(val author someone)" \
    --arg state "$(val state OPEN)" \
    --arg head "$(val head feature)" \
    --arg base "$(val base main)" \
    --arg mergeable "$mergeable" \
    --arg mss "$(val merge-state CLEAN)" \
    --arg review "$(val review-decision '')" \
    --argjson rollup "$(val rollup '[]')" \
    '{number: 7, title: "A title", state: $state, isDraft: $draft,
      author: {login: $author}, headRefName: $head, baseRefName: $base,
      url: "https://github.com/o/r/pull/7", body: $body,
      mergeable: $mergeable, mergeStateStatus: $mss,
      reviewDecision: $review, statusCheckRollup: $rollup}'
}

case "$1 $2" in
  "pr view") pr_json | out ;;
  "pr diff") echo "diff --git a/x b/x" ;;
  "pr list") val list.json '[]' | out ;;
  "pr ready")
    if landed; then
      if [ "${4:-}" = --undo ]; then echo true >"$S/draft"; else echo false >"$S/draft"; fi
    fi
    ;;
  "pr edit")
    if landed; then cat "$body_file" >"$S/body"; fi
    ;;
  "pr create")
    # Positional: pr-create passes `--draft --base <base> --head <head>`
    # first. A case's `base-override` stands in for the base GitHub kept.
    printf '%s\n' "$(val base-override "$5")" >"$S/base"
    printf '%s\n' "$7" >"$S/head"
    if landed; then echo true >"$S/draft"; else echo false >"$S/draft"; fi
    cat "$body_file" >"$S/body"
    echo "https://github.com/o/r/pull/7"
    ;;
  "pr comment")
    if landed; then cat "$body_file" >"$S/comment-555"; else echo other >"$S/comment-555"; fi
    echo "https://github.com/o/r/pull/7#issuecomment-555"
    ;;
  "pr review")
    me=$(val me me)
    if [ "$me" = "$(val author someone)" ] && [ "$4" != --comment ]; then
      echo "failed to create review: Can not approve your own pull request" >&2
      exit 1
    fi
    case "$4" in
      --approve) state=APPROVED ;;
      --request-changes) state=CHANGES_REQUESTED ;;
      *) state=COMMENTED ;;
    esac
    if landed; then
      reviews=$(val reviews.json '[]')
      printf '%s\n' "$reviews" | jq --arg me "$me" --arg state "$state" \
        --arg body "$(cat "$body_file")" \
        '. + [{id: (length + 100), user: {login: $me}, state: $state, body: $body}]' \
        >"$S/reviews.json"
    fi
    ;;
  "api user") jq -n --arg me "$(val me me)" '{login: $me}' | out ;;
  "api --paginate") val reviews.json '[]' | out ;;
  "api repos/{owner}/{repo}/issues/comments/555")
    jq -n --arg body "$(cat "$S/comment-555")" '{body: $body}' | out
    ;;
  "api repos/{owner}/{repo}/pulls/7/reviews/"*)
    id=${2##*/}
    val reviews.json '[]' | jq ".[] | select(.id == $id)" | out
    ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$SANDBOX/bin/gh"

# `sleep` is stubbed so the merge-readiness retry schedule costs nothing;
# the waits it was asked for are recorded instead.
cat >"$SANDBOX/bin/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$STUB_DIR/sleeps"
STUB
chmod +x "$SANDBOX/bin/sleep"

REPO="$SANDBOX/repo"
mkdir -p "$REPO/.issues"
git -C "$REPO" init -q
cat >"$REPO/.issues/repo-config.md" <<'CONFIG'
---
schema-version: 7
default-pr-target-branch: integ
issue-link-prefix: "#"
---
CONFIG

# new_case <name> -- a fresh stub state directory.
new_case() {
  CASE="$SANDBOX/case-$1"
  mkdir -p "$CASE"
}

# run <verb> <args...> -- run one script from $REPO; leaves OUT, ERR, RC.
run() {
  local verb=$1
  shift
  OUT=$(cd "$REPO" && PATH="$SANDBOX/bin:$PATH" STUB_DIR="$CASE" \
    /bin/bash "$BIN/$verb" "$@" 2>"$CASE/stderr")
  RC=$?
  ERR=$(cat "$CASE/stderr")
}

calls() { cat "$CASE/calls" 2>/dev/null; }
call_line() { sed -n "${1}p" "$CASE/calls"; }

# --- every script is executable -----------------------------------------
for script in "$BIN"/pr-*; do
  name=${script##*/}
  check "$([ -x "$script" ] && echo yes)" "yes" "$name is executable"
done

# --- pr-view -------------------------------------------------------------
new_case view-dump
echo "the body" >"$CASE/body"
run pr-view '#7'
check "$RC" "0" "pr-view: exit 0"
check_contains "$(call_line 1)" \
  "pr view 7 --json number,title,state,isDraft,author,headRefName,baseRefName,url,body --jq" \
  "pr-view: the default dump asks gh for the fixed field list, with the leading # stripped"
check "$(printf '%s\n' "$OUT" | head -n 1)" "#7 A title (OPEN, draft)" "pr-view: the dump opens with number, title, state and draft"
check "$(printf '%s\n' "$OUT" | tail -n 1)" "the body" "pr-view: the dump ends with the body"

new_case view-json
run pr-view 7 --json reviews --jq '.reviews | length'
check "$(calls)" "pr view 7 --json reviews --jq .reviews | length" "pr-view: --json and --jq pass through to gh"

new_case view-json-only
run pr-view 7 --json headRefName
check "$(calls)" "pr view 7 --json headRefName" "pr-view: --json alone passes through with no --jq"

new_case view-jq-alone
run pr-view 7 --jq .body
check "$RC" "2" "pr-view: --jq without --json is a usage error"
check "$(calls)" "" "pr-view: a usage error calls no gh"

new_case view-bad-pr
run pr-view seven
check "$RC" "2" "pr-view: a non-numeric PR is a usage error"
check_contains "$ERR" "pr-view: \`seven\` is not a PR number." "pr-view: the usage error names the bad value"

new_case view-gh-fails
echo "pr view" >"$CASE/fail"
run pr-view 7
check "$RC" "3" "pr-view: a failed gh call exits 3"
check_contains "$ERR" "stub gh: pr view refused" "pr-view: gh's own stderr passes through"
check_contains "$ERR" "pr-view: gh pr view failed (exit 1)" "pr-view: the catalogue line names the failed call"

# --- pr-list -------------------------------------------------------------
new_case list
run pr-list --head issue-9-x --state merged
check "$RC" "0" "pr-list: exit 0"
check "$(calls)" "pr list --head issue-9-x --state merged --json number,title,state,headRefName,baseRefName,mergedAt,closedAt,url" \
  "pr-list: lists by head and state with the fixed field list"
check "$OUT" "[]" "pr-list: prints gh's JSON array"

new_case list-default
run pr-list --head b
check "$(calls)" "pr list --head b --state open --json number,title,state,headRefName,baseRefName,mergedAt,closedAt,url" \
  "pr-list: the state defaults to open"

new_case list-bad-state
run pr-list --head b --state gone
check "$RC" "2" "pr-list: an unknown state is a usage error"

new_case list-no-head
run pr-list
check "$RC" "2" "pr-list: a missing --head is a usage error"

# --- pr-diff -------------------------------------------------------------
new_case diff
run pr-diff 7
check "$(calls)" "pr diff 7" "pr-diff: calls gh pr diff"
check "$OUT" "diff --git a/x b/x" "pr-diff: prints the diff verbatim"

new_case diff-fails
echo "pr diff" >"$CASE/fail"
run pr-diff 7
check "$RC" "3" "pr-diff: a failed gh call exits 3"
check_contains "$ERR" "stub gh: pr diff refused" "pr-diff: gh's error passes through verbatim"

# --- pr-closing-issues ---------------------------------------------------
new_case closing
printf 'Summary\n\nCloses #3\n' >"$CASE/body"
run pr-closing-issues 7
check "$(calls)" "pr view 7 --json body --jq .body" "pr-closing-issues: reads the body"
check "$OUT" "$(printf 'Summary\n\nCloses #3')" "pr-closing-issues: prints the body"

# --- pr-ready / pr-draft -------------------------------------------------
new_case ready
echo true >"$CASE/draft"
run pr-ready 7
check "$RC" "0" "pr-ready: exit 0 when the flip lands"
check "$(call_line 1)" "pr ready 7" "pr-ready: calls gh pr ready"
check "$(call_line 2)" "pr view 7 --json isDraft --jq .isDraft" "pr-ready: re-reads isDraft"
check "$OUT" "PR #7 is ready for review" "pr-ready: reports the flip"

new_case ready-noop
echo true >"$CASE/draft"
touch "$CASE/noop"
run pr-ready 7
check "$RC" "1" "pr-ready: exit 1 when the re-read is still a draft"
check "$ERR" "pr-ready: PR #7: the ready flip did not land: the re-read still reports isDraft true" \
  "pr-ready: the not-landed message"

new_case draft
echo false >"$CASE/draft"
run pr-draft 7
check "$RC" "0" "pr-draft: exit 0 when the flip lands"
check "$(call_line 1)" "pr ready 7 --undo" "pr-draft: calls gh pr ready --undo"
check "$(call_line 2)" "pr view 7 --json isDraft --jq .isDraft" "pr-draft: re-reads isDraft"

new_case draft-noop
echo false >"$CASE/draft"
touch "$CASE/noop"
run pr-draft 7
check "$RC" "1" "pr-draft: exit 1 when the re-read is not a draft"
check "$ERR" "pr-draft: PR #7: the draft flip did not land: the re-read still reports isDraft false" \
  "pr-draft: the not-landed message"

# --- pr-update -----------------------------------------------------------
# shellcheck disable=SC2016 # the backtick and $ are the bytes under test
printf 'New body with `ticks` and $dollar\n' >"$SANDBOX/new-body.md"
new_case update
echo "old" >"$CASE/body"
run pr-update 7 --body-file "$SANDBOX/new-body.md"
check "$RC" "0" "pr-update: exit 0 when the body lands"
check "$(call_line 1)" "pr edit 7 --body-file $SANDBOX/new-body.md" "pr-update: edits the body by path"
check "$(call_line 2)" "pr view 7 --json body --jq .body" "pr-update: re-reads the body"

new_case update-noop
echo "old" >"$CASE/body"
touch "$CASE/noop"
run pr-update 7 --body-file "$SANDBOX/new-body.md"
check "$RC" "1" "pr-update: exit 1 when the body did not change"
check "$ERR" "pr-update: PR #7: the body edit did not land: the re-read body differs from $SANDBOX/new-body.md" \
  "pr-update: the not-landed message"

new_case update-missing-file
run pr-update 7 --body-file "$SANDBOX/absent.md"
check "$RC" "2" "pr-update: a missing body file is a usage error"
check "$(calls)" "" "pr-update: a usage error calls no gh"

# --- pr-comment ----------------------------------------------------------
new_case comment
run pr-comment 7 --body-file "$SANDBOX/new-body.md"
check "$RC" "0" "pr-comment: exit 0 when the comment lands"
check "$(call_line 1)" "pr comment 7 --body-file $SANDBOX/new-body.md" "pr-comment: posts by path"
check "$(call_line 2)" "api repos/{owner}/{repo}/issues/comments/555 --jq .body" \
  "pr-comment: re-reads the comment by the id gh reported"
check "$OUT" "https://github.com/o/r/pull/7#issuecomment-555" "pr-comment: prints the comment URL"

new_case comment-noop
touch "$CASE/noop"
run pr-comment 7 --body-file "$SANDBOX/new-body.md"
check "$RC" "1" "pr-comment: exit 1 when the posted body differs"
check "$ERR" "pr-comment: PR #7: the comment did not land: comment 555's body differs from $SANDBOX/new-body.md" \
  "pr-comment: the not-landed message"

# --- pr-link-issue -------------------------------------------------------
new_case link
printf 'Summary\n\nCloses #3\n' >"$CASE/body"
run pr-link-issue 7 '#4' 5,
check "$RC" "0" "pr-link-issue: exit 0 when the lines land"
check "$(call_line 1)" "pr view 7 --json body --jq .body" "pr-link-issue: reads the existing body"
check "$(call_line 2)" "pr edit 7 --body-file -" "pr-link-issue: writes the body through stdin"
check "$(cat "$CASE/stdin")" "$(printf 'Summary\n\nCloses #3\n\nCloses #4\nCloses #5')" \
  "pr-link-issue: keeps the body and appends one line per issue after a blank line"
check "$(call_line 3)" "pr view 7 --json body --jq .body" "pr-link-issue: re-reads the body"
check "$OUT" "PR #7: appended Closes #4, Closes #5" "pr-link-issue: reports what it appended"

new_case link-empty
run pr-link-issue 7 4
check "$(cat "$CASE/stdin")" "Closes #4" "pr-link-issue: an empty body gets the lines alone"

new_case link-noop
echo "Summary" >"$CASE/body"
touch "$CASE/noop"
run pr-link-issue 7 4
check "$RC" "1" "pr-link-issue: exit 1 when the body did not change"
check "$ERR" "pr-link-issue: PR #7: the closing lines did not land: the re-read body is not the body written" \
  "pr-link-issue: the not-landed message"

# --- pr-create -----------------------------------------------------------
printf 'Summary of the change\n' >"$SANDBOX/summary.md"
new_case create
run pr-create --head issue-3-4-x --title "Add a thing" --body-file "$SANDBOX/summary.md" 3 '#4'
check "$RC" "0" "pr-create: exit 0 when the draft lands"
check "$(call_line 1)" "pr create --draft --base integ --head issue-3-4-x --title Add a thing --body-file -" \
  "pr-create: opens a draft against the configured base"
check "$(cat "$CASE/stdin")" "$(printf 'Summary of the change\n\nCloses #3\nCloses #4')" \
  "pr-create: the body ends with one closing line per issue, using the configured prefix"
check "$(call_line 2)" "pr view 7 --json isDraft,baseRefName,headRefName --jq \"\\(.isDraft) \\(.baseRefName) \\(.headRefName)\"" \
  "pr-create: re-reads draft, base and head"
check "$(call_line 3)" "pr view 7 --json body --jq .body" "pr-create: re-reads the body"
check "$OUT" "https://github.com/o/r/pull/7" "pr-create: prints the PR URL"

new_case create-mismatch
echo main >"$CASE/base-override"
run pr-create --head issue-3-4-x --title T --body-file "$SANDBOX/summary.md" 3
check "$RC" "1" "pr-create: exit 1 when the PR is not on the configured base"
check_contains "$ERR" "PR #7: the draft PR did not land" "pr-create: the not-landed message"

new_case create-not-draft
touch "$CASE/noop"
run pr-create --head b --title T --body-file "$SANDBOX/summary.md" 3
check "$RC" "1" "pr-create: exit 1 when the PR is not a draft"

new_case create-no-issue
run pr-create --head b --title T --body-file "$SANDBOX/summary.md"
check "$RC" "2" "pr-create: no issue number is a usage error"

new_case create-no-config
mv "$REPO/.issues/repo-config.md" "$SANDBOX/repo-config.md"
run pr-create --head b --title T --body-file "$SANDBOX/summary.md" 3
mv "$SANDBOX/repo-config.md" "$REPO/.issues/repo-config.md"
check "$RC" "4" "pr-create: a missing repo-config exits 4"
check "$ERR" "pr-create: This repo has no \`.issues/repo-config.md\`. Run \`/repo-config\` to create one." \
  "pr-create: the missing-config message"
check "$(calls)" "" "pr-create: a missing repo-config opens no PR"

# --- pr-review-submit ----------------------------------------------------
new_case review-approve
run pr-review-submit 7 --verdict approve "Looks good"
check "$RC" "0" "pr-review-submit: exit 0 when the review lands"
check "$(call_line 1)" "api user --jq .login" "pr-review-submit: reads the authenticated login"
check "$(call_line 2)" "pr view 7 --json author --jq .author.login" "pr-review-submit: reads the PR's author"
check "$(call_line 4)" "pr review 7 --approve --body-file -" "pr-review-submit: approve posts with --approve"
check "$(cat "$CASE/stdin")" "$(printf 'APPROVED\n\nLooks good')" "pr-review-submit: the body opens with the verdict word"
check "$OUT" "PR #7: verdict approve, review state approved, body inline" \
  "pr-review-submit: reports the state created and the body form"

new_case review-self
echo me >"$CASE/author"
# shellcheck disable=SC2016 # the backtick and $ are the bytes under test
printf 'Finding with `ticks` and $HOME\n' >"$SANDBOX/review.md"
run pr-review-submit 7 --verdict request_changes --body-file "$SANDBOX/review.md"
check "$RC" "0" "pr-review-submit: a self-review exits 0"
check "$(call_line 4)" "pr review 7 --comment --body-file -" "pr-review-submit: a self-review posts with --comment"
# shellcheck disable=SC2016 # the backtick and $ are the bytes under test
check "$(cat "$CASE/stdin")" "$(printf 'CHANGES_REQUESTED\n\nFinding with `ticks` and $HOME')" \
  "pr-review-submit: a downgraded review keeps its verdict line, and the file's bytes reach gh"
check "$(cat "$SANDBOX/review.md")" "Finding with \`ticks\` and \$HOME" "pr-review-submit: the caller's file is untouched"
check "$OUT" "PR #7: verdict request_changes, review state commented, body file" \
  "pr-review-submit: a downgraded review reports commented"

new_case review-noop
touch "$CASE/noop"
run pr-review-submit 7 --verdict comment "Note"
check "$RC" "1" "pr-review-submit: exit 1 when no new review appears"
check "$ERR" "pr-review-submit: PR #7: the review did not land: no new review by me is on the PR" \
  "pr-review-submit: the not-landed message"

new_case review-no-verdict
run pr-review-submit 7 "body"
check "$RC" "2" "pr-review-submit: no verdict is a usage error"
check_contains "$ERR" "No \`--verdict\` was supplied. Pass exactly one of \`approve\`, \`request_changes\`, or \`comment\`." \
  "pr-review-submit: the no-verdict message"

new_case review-two-verdicts
run pr-review-submit 7 --verdict approve --verdict comment "body"
check "$RC" "2" "pr-review-submit: two verdicts are a usage error"
check_contains "$ERR" "\`--verdict\` was supplied more than once, as \`approve\` and \`comment\`." \
  "pr-review-submit: the two-verdicts message"

new_case review-bad-verdict
run pr-review-submit 7 --verdict lgtm "body"
check_contains "$ERR" "\`lgtm\` is not a verdict. Pass \`approve\`, \`request_changes\`, or \`comment\`." \
  "pr-review-submit: the bad-verdict message"

new_case review-both-bodies
run pr-review-submit 7 --verdict comment "body" --body-file "$SANDBOX/review.md"
check_contains "$ERR" "Both an inline \`<body>\` and \`--body-file <path>\` were supplied. Pass exactly one." \
  "pr-review-submit: the both-bodies message"

new_case review-no-body
run pr-review-submit 7 --verdict comment
check_contains "$ERR" "No review body was supplied. Pass either an inline \`<body>\` or \`--body-file <path>\`." \
  "pr-review-submit: the no-body message"
check "$(calls)" "" "pr-review-submit: a usage error calls no gh"

# --- pr-ready-to-merge ---------------------------------------------------
new_case merge-clean
echo MERGEABLE >"$CASE/mergeable-seq"
echo APPROVED >"$CASE/review-decision"
cat >"$CASE/rollup" <<'JSON'
[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},
 {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":""},
 {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE"},
 {"__typename":"StatusContext","context":"ci/legacy","state":"PENDING"},
 {"__typename":"StatusContext","context":"ci/other","state":"ERROR"},
 {"__typename":"StatusContext","context":"ci/ok","state":"SUCCESS"}]
JSON
run pr-ready-to-merge 7
check "$RC" "0" "pr-ready-to-merge: exit 0 on a resolved state"
check_contains "$(call_line 1)" "pr view 7 --json number,state,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup --jq" \
  "pr-ready-to-merge: reads state, merge fields, review decision and checks"
check "$OUT" "PR #7: mergeable MERGEABLE, mergeStateStatus CLEAN — mergeable
reviewDecision: APPROVED
checks running:
  lint: status IN_PROGRESS
  ci/legacy: state PENDING
checks not green:
  test: status COMPLETED, conclusion FAILURE
  ci/other: state ERROR" "pr-ready-to-merge: the report block classifies every check"

new_case merge-retry
printf 'UNKNOWN\nUNKNOWN\nMERGEABLE\n' >"$CASE/mergeable-seq"
echo BEHIND >"$CASE/merge-state"
run pr-ready-to-merge 7
check "$RC" "0" "pr-ready-to-merge: a state that resolves on the third read exits 0"
check "$(tr '\n' ' ' <"$CASE/sleeps")" "10 30 " "pr-ready-to-merge: waits 10 s, then 30 s"
check "$(calls | grep -c '^pr view')" "3" "pr-ready-to-merge: reads three times"
check_contains "$OUT" "PR #7: merge state still computing, attempt 2 of 3 — waiting 10 s." \
  "pr-ready-to-merge: announces the first wait"
check_contains "$OUT" "mergeStateStatus BEHIND — the branch is behind its base" "pr-ready-to-merge: BEHIND's meaning"
check_contains "$OUT" "reviewDecision: (none)" "pr-ready-to-merge: an empty review decision reads (none)"
check_contains "$OUT" "checks running: none" "pr-ready-to-merge: an empty list reads none"

new_case merge-unknown
echo UNKNOWN >"$CASE/mergeable-seq"
echo UNKNOWN >"$CASE/merge-state"
run pr-ready-to-merge 7
check "$RC" "1" "pr-ready-to-merge: still UNKNOWN after three reads exits 1"
check "$(calls | grep -c '^pr view')" "3" "pr-ready-to-merge: gives up after three reads"
check_contains "$OUT" "mergeable UNKNOWN, mergeStateStatus UNKNOWN — still computing after the whole retry schedule" \
  "pr-ready-to-merge: reports UNKNOWN rather than a guess"

new_case merge-closed
echo MERGED >"$CASE/state"
run pr-ready-to-merge 7
check "$RC" "1" "pr-ready-to-merge: a PR that is not open exits 1"
check "$ERR" "pr-ready-to-merge: PR #7 is MERGED, not open. Merge readiness is only computed for an open PR." \
  "pr-ready-to-merge: the not-open message"
check "$(calls | grep -c '^pr view')" "1" "pr-ready-to-merge: a PR that is not open is read once"

new_case merge-unnamed-state
echo SOMETHING_NEW >"$CASE/merge-state"
run pr-ready-to-merge 7
check_contains "$OUT" "mergeStateStatus SOMETHING_NEW
" "pr-ready-to-merge: a state the table does not name carries no meaning"

# --- pr-merge-conflicts --------------------------------------------------
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
CLONE="$SANDBOX/clone"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$ORIGIN"
git init -q -b main "$SEED"
printf 'one\ntwo\nthree\n' >"$SEED/file.txt"
echo keep >"$SEED/other.txt"
git -C "$SEED" add . && git -C "$SEED" commit -q -m base
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" checkout -q -b feature
printf 'one\nFEATURE\nthree\n' >"$SEED/file.txt"
git -C "$SEED" commit -q -am feature
git -C "$SEED" checkout -q -b clean main
echo more >>"$SEED/other.txt"
git -C "$SEED" commit -q -am clean
git -C "$SEED" checkout -q main
printf 'one\nMAIN\nthree\n' >"$SEED/file.txt"
git -C "$SEED" commit -q -am main
git -C "$SEED" push -q origin main feature clean
git clone -q "$ORIGIN" "$CLONE"
echo ".claude/" >"$CLONE/.git/info/exclude"

run_conflicts() {
  OUT=$(cd "$CLONE" && PATH="$SANDBOX/bin:$PATH" STUB_DIR="$CASE" \
    /bin/bash "$BIN/pr-merge-conflicts" "$@" 2>"$CASE/stderr")
  RC=$?
  ERR=$(cat "$CASE/stderr")
}

new_case conflicts
echo feature >"$CASE/head"
before=$(git -C "$CLONE" status --porcelain)
run_conflicts 7
check "$RC" "0" "pr-merge-conflicts: exit 0 when conflicts are reported"
check "$(calls)" "pr view 7 --json headRefName,baseRefName --jq \"\\(.headRefName) \\(.baseRefName)\"" \
  "pr-merge-conflicts: reads head and base from the PR"
check_contains "$OUT" "PR #7: head feature, base main" "pr-merge-conflicts: names head and base"
check_contains "$OUT" "Conflicting files:
  file.txt" "pr-merge-conflicts: lists the conflicting file"
check_contains "$OUT" "+=======" "pr-merge-conflicts: prints the file's conflicting hunk"
check "$([ -e "$CLONE/.claude/worktrees/pr-merge-conflicts-7" ] && echo left || echo removed)" "removed" \
  "pr-merge-conflicts: the throwaway worktree is removed"
check "$(git -C "$CLONE" worktree list | wc -l | tr -d ' ')" "1" "pr-merge-conflicts: no worktree stays registered"
check "$(git -C "$CLONE" status --porcelain)" "$before" "pr-merge-conflicts: the clone's status is unchanged"

new_case conflicts-clean
echo clean >"$CASE/head"
run_conflicts 7
check "$RC" "0" "pr-merge-conflicts: a clean trial merge exits 0"
check_contains "$OUT" "The trial merge is clean: no conflicts with origin/main." "pr-merge-conflicts: says the merge is clean"

new_case conflicts-leftover
echo feature >"$CASE/head"
git -C "$CLONE" worktree add -q --detach "$CLONE/.claude/worktrees/pr-merge-conflicts-7" origin/feature
git -C "$CLONE/.claude/worktrees/pr-merge-conflicts-7" merge -q --no-commit --no-ff origin/main >/dev/null 2>&1
run_conflicts 7
check "$RC" "0" "pr-merge-conflicts: an interrupted run's worktree is cleared first"
check_contains "$OUT" "  file.txt" "pr-merge-conflicts: the conflicts are still reported"
check "$(git -C "$CLONE" worktree list | wc -l | tr -d ' ')" "1" "pr-merge-conflicts: the leftover is gone too"

new_case conflicts-stale-registration
echo feature >"$CASE/head"
git -C "$CLONE" worktree add -q --detach "$CLONE/.claude/worktrees/pr-merge-conflicts-7" origin/feature
rm -rf "$CLONE/.claude/worktrees/pr-merge-conflicts-7"
run_conflicts 7
check "$RC" "0" "pr-merge-conflicts: a registration whose directory is gone is pruned"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
