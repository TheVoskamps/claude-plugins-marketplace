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
# is how a change that did not land is staged. A fixture sourcing the
# common helper, and a git that fails under pr-merge-conflicts, check that
# a command no verb handles exits 3 wherever it fails.
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
query=
paginate=
for a in "$@"; do
  [ "$prev" = --jq ] && jq_expr=$a
  [ "$prev" = --body-file ] && body_file=$a
  case "$prev $a" in
    "-f query="*) query=${a#query=} ;;
  esac
  [ "$a" = --paginate ] && paginate=yes
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

# The checkout's repo lives on a case's `host`, github.com by default,
# and the PR on its `api-host`, the checkout's host unless the case names
# another. As gh does, an api call reaches the host its --hostname names
# and github.com without one, and finds nothing on any other host.
if [ "$1" = api ]; then
  api_host=github.com
  if [ "$2" = --hostname ]; then
    api_host=$3
    shift 3
    set -- api "$@"
  fi
  if [ "$api_host" != "$(val api-host "$(val host github.com)")" ]; then
    echo "stub gh: HTTP 404: Not Found (https://$api_host/api/v3/$2)" >&2
    exit 1
  fi
fi

pr_json() {
  views=$(($(val views 0) + 1))
  echo "$views" >"$S/views"
  mergeable=$(sed -n "${views}p" "$S/mergeable-seq" 2>/dev/null)
  [ -n "$mergeable" ] || mergeable=$(tail -n 1 "$S/mergeable-seq" 2>/dev/null)
  [ -n "$mergeable" ] || mergeable=MERGEABLE
  # gh spells a bot author `app/<slug>` where REST spells it `<slug>[bot]`.
  author=$(val author someone)
  case "$author" in
    *'[bot]') author="app/${author%\[bot\]}" ;;
  esac
  jq -n \
    --arg body "$(val body '')" \
    --argjson draft "$(val draft true)" \
    --arg author "$author" \
    --arg state "$(val state OPEN)" \
    --arg head "$(val head feature)" \
    --arg base "$(val base main)" \
    --arg mergeable "$mergeable" \
    --arg mss "$(val merge-state CLEAN)" \
    --arg review "$(val review-decision '')" \
    --argjson rollup "$(val rollup '[]')" \
    --arg url "$(val pr-url https://github.com/o/r/pull/7)" \
    --arg head_repo "$(val head-repo o/r)" \
    '{number: 7, title: "A title", state: $state, isDraft: $draft,
      author: {login: $author}, headRefName: $head, baseRefName: $base,
      headRepository: {nameWithOwner: $head_repo},
      url: $url, body: $body,
      mergeable: $mergeable, mergeStateStatus: $mss,
      reviewDecision: $review, statusCheckRollup: $rollup}'
}

case "$1 $2" in
  "repo view") jq -n --arg url "https://$(val host github.com)/$(val cur-repo o/r)" '{url: $url}' | out ;;
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
    # first. A case's `base-override` or `body-override` stands in for
    # the base or the body GitHub kept, and its `create-url` for what gh
    # printed.
    printf '%s\n' "$(val base-override "$5")" >"$S/base"
    printf '%s\n' "$7" >"$S/head"
    if landed; then echo true >"$S/draft"; else echo false >"$S/draft"; fi
    if [ -f "$S/body-override" ]; then cat "$S/body-override" >"$S/body"; else cat "$body_file" >"$S/body"; fi
    printf '%s\n' "$(val create-url "https://github.com/o/r/pull/7")"
    ;;
  "pr comment")
    # A case's `comment-url` stands in for what gh printed.
    if landed; then cat "$body_file" >"$S/comment-555"; else echo other >"$S/comment-555"; fi
    printf '%s\n' "$(val comment-url "https://github.com/o/r/pull/7#issuecomment-555")"
    ;;
  "pr review")
    me=$(val me me)
    # GitHub's refusal of a verdict on the author's own PR, as gh prints it.
    if [ "$me" = "$(val author someone)" ]; then
      case "$4" in
        --approve)
          echo "GraphQL: Review Can not approve your own pull request (addPullRequestReview)" >&2
          exit 1
          ;;
        --request-changes)
          echo "GraphQL: Review Can not request changes on your own pull request (addPullRequestReview)" >&2
          exit 1
          ;;
      esac
    fi
    case "$4" in
      --approve) state=APPROVED ;;
      --request-changes) state=CHANGES_REQUESTED ;;
      *) state=COMMENTED ;;
    esac
    # A case's `review-state` or `review-body` stands in for the state or
    # the body GitHub recorded, instead of the ones posted.
    state=$(val review-state "$state")
    if landed; then
      reviews=$(val reviews.json '[]')
      printf '%s\n' "$reviews" | jq --arg me "$me" --arg state "$state" \
        --arg body "$(val review-body "$(cat "$body_file")")" \
        '. + [{id: (length + 100), user: {login: $me}, state: $state, body: $body}]' \
        >"$S/reviews.json"
    fi
    ;;
  "api --paginate") val reviews.json '[]' | out ;;
  "api graphql")
    # A PR's files connection, a case's `files-count` files long and
    # served 100 to a page, the file at index i being `dir/f<i>.txt`.
    # As gh does, only --paginate over a query that pages on $endCursor
    # and asks for pageInfo reaches past the first page, and --jq
    # applies to every page.
    case "$query" in
      *'after: $endCursor'*'pageInfo { hasNextPage endCursor }'*) ;;
      *) paginate= ;;
    esac
    total=$(val files-count 0)
    start=0
    while :; do
      end=$((start + 100))
      [ "$end" -le "$total" ] || end=$total
      next=false
      [ "$end" -lt "$total" ] && next=true
      jq -n --argjson s "$start" --argjson e "$end" --argjson next "$next" \
        '{data: {repository: {pullRequest: {files: {
           nodes: [range($s; $e) | {path: "dir/f\(.).txt", additions: ., deletions: 1, changeType: "MODIFIED"}],
           pageInfo: {hasNextPage: $next, endCursor: "c\($e)"}}}}}}' | out
      [ -n "$paginate" ] && [ "$next" = true ] || break
      start=$end
    done
    ;;
  "api repos/"*"/issues/comments/555")
    jq -n --arg body "$(cat "$S/comment-555")" '{body: $body}' | out
    ;;
  "api repos/"*"/pulls/7/reviews/"*)
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
check "$(printf '%s\n' "$OUT" | head -n 1)" "github.com/o/r#7 A title (OPEN, draft)" \
  "pr-view: the dump opens with the canonical reference, title, state and draft"
check "$(printf '%s\n' "$OUT" | tail -n 1)" "the body" "pr-view: the dump ends with the body"

new_case view-ref
run pr-view 7 --ref
check "$RC" "0" "pr-view --ref: exit 0"
check "$(calls)" "pr view 7 --json number,url --jq ((.url | ltrimstr(\"https://\") | sub(\"/pull/[0-9]+/?\$\"; \"\")) + \"#\\(.number)\")" \
  "pr-view --ref: reads the number and URL alone"
check "$OUT" "github.com/o/r#7" "pr-view --ref: prints <host>/<owner>/<repo>#<N>"

new_case view-ref-fork
echo https://ghe.example.com/base-o/base-r/pull/7 >"$CASE/pr-url"
echo fork-o/base-r >"$CASE/head-repo"
echo ghe.example.com >"$CASE/host"
run pr-view 7 --ref
check "$OUT" "ghe.example.com/base-o/base-r#7" "pr-view --ref: a fork PR prints its base repository, on its host"

new_case view-ref-json
run pr-view 7 --ref --json body
check "$RC" "2" "pr-view: --ref with --json is a usage error"
check "$(calls)" "" "pr-view: --ref with --json calls no gh"

# --- PR references -------------------------------------------------------
# Each form is driven through pr-diff, whose `pr diff` call shows where
# the reference sent it; the api host is pr-comment's below.

new_case ref-hash
run pr-diff '#7'
check "$(calls)" "pr diff 7" "reference #N: the current repository's PR, with no --repo"

new_case ref-repo
echo acme/r >"$CASE/cur-repo"
echo ghe.example.com >"$CASE/host"
run pr-diff 'r2#7'
check "$RC" "0" "reference repo#N: exit 0"
check "$(calls)" "repo view --json url --jq .url
pr diff 7 --repo ghe.example.com/acme/r2" "reference repo#N: under the current repository's owner, on its host"

new_case ref-owner-repo
echo ghe.example.com >"$CASE/host"
run pr-diff 'o2/r2#7'
check "$(calls)" "repo view --json url --jq .url
pr diff 7 --repo ghe.example.com/o2/r2" "reference owner/repo#N: that repository, on the current repository's host"

new_case ref-host-owner-repo
run pr-diff 'ghe.example.com/o2/r2#7'
check "$(calls)" "pr diff 7 --repo ghe.example.com/o2/r2" "reference host/owner/repo#N: that repository on that host, with no lookup"

new_case ref-url
run pr-diff 'https://ghe.example.com/o2/r2/pull/7'
check "$(calls)" "pr diff 7 --repo ghe.example.com/o2/r2" "reference PR URL: the same as host/owner/repo#N"

new_case ref-url-slash
run pr-diff 'https://ghe.example.com/o2/r2/pull/7/'
check "$(calls)" "pr diff 7 --repo ghe.example.com/o2/r2" "reference PR URL: a trailing / is ignored"

new_case ref-issue-url
run pr-diff 'https://ghe.example.com/o2/r2/issues/7'
check "$RC" "2" "reference issue URL: a usage error"
check_contains "$ERR" "pr-diff: \`https://ghe.example.com/o2/r2/issues/7\` is not a PR. Pass N, #N, repo#N, owner/repo#N, host/owner/repo#N, or https://host/owner/repo/pull/N." \
  "reference issue URL: the usage error names the accepted forms"
check "$(calls)" "" "reference issue URL: calls no gh"

new_case ref-dash-repo
run pr-diff 'ghe.example.com/o2/-r#7'
check "$(calls)" "pr diff 7 --repo ghe.example.com/o2/-r" "reference: a repository name may start with -"

new_case ref-dash-lone-repo
echo acme/r >"$CASE/cur-repo"
echo ghe.example.com >"$CASE/host"
run pr-diff '-r#7'
check "$(calls)" "repo view --json url --jq .url
pr diff 7 --repo ghe.example.com/acme/-r" "reference: a lone repository name may start with -"

new_case ref-long-parts
run pr-diff 'h-1.hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh.com/ooooooooooooooooooooooooooooooooooooooo/rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr#7'
check "$(calls)" "pr diff 7 --repo h-1.hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh.com/ooooooooooooooooooooooooooooooooooooooo/rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr" "reference: a 63-character host label, a 39-character owner and a 100-character repository name"

for bad in 'h/o/r/x#7' 'o/r#' '-o/r#7' '-h/o/r#7' 'h-/o/r#7' 'h..x/o/r#7' 'h_x/o/r#7' 'o--p/r#7' 'o_p/r#7' 'o.p/r#7' 'oooooooooooooooooooooooooooooooooooooooo/r#7' 'o/rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr#7' 'hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh.x/o/r#7' 'o/r+s#7' 'https://-h/o/r/pull/7' 'https://h/-o/r/pull/7' 'o//r#7' '/r#7' 'o r#7' 'o/r#7x' '##7' 'http://h/o/r/pull/7' 'https://h/o/pull/7'; do
  new_case "ref-malformed-$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '_')"
  run pr-diff "$bad"
  check "$RC:$(calls)" "2:" "reference \`$bad\`: a usage error that calls no gh"
done

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
check_contains "$ERR" "pr-view: \`seven\` is not a PR." "pr-view: the usage error names the bad value"

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

# --- pr-files ------------------------------------------------------------
new_case files
echo 250 >"$CASE/files-count"
run pr-files 7
check "$RC" "0" "pr-files: exit 0"
check_contains "$(calls)" "api --hostname github.com graphql --paginate -f owner=o -f repo=r -F pr=7 -f query=" \
  "pr-files: pages the GraphQL files connection of the current repository's PR, on its host"
check "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "250" "pr-files: prints every file of a PR with more than 100"
check "$(printf '%s\n' "$OUT" | head -n 1)" "$(printf 'MODIFIED\t0\t1\tdir/f0.txt')" \
  "pr-files: one changeType, additions, deletions and path line per file, tab-separated"
check "$(printf '%s\n' "$OUT" | tail -n 1)" "$(printf 'MODIFIED\t249\t1\tdir/f249.txt')" \
  "pr-files: the last page's last file is there"

new_case files-other-repo
echo 3 >"$CASE/files-count"
echo ghe.example.com >"$CASE/api-host"
run pr-files 'ghe.example.com/o2/r2#7'
check "$RC" "0" "pr-files: exit 0 for a PR in another repository"
check_contains "$(calls)" "api --hostname ghe.example.com graphql --paginate -f owner=o2 -f repo=r2 -F pr=7" \
  "pr-files: asks the host, owner and repository the reference names"
check "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "3" "pr-files: prints that PR's files"

new_case files-fails
echo "api --hostname" >"$CASE/fail"
run pr-files 7
check "$RC" "3" "pr-files: a failed gh call exits 3"
check_contains "$ERR" "pr-files: gh api graphql failed (exit 1)" "pr-files: the catalogue line names the failed call"

new_case files-two-prs
run pr-files 7 8
check "$RC:$(calls)" "2:" "pr-files: more than one PR is a usage error that calls no gh"

# --- the ERR trap ---------------------------------------------------------
# A command a verb does not handle exits 3 with the catalogue line naming
# it, never with the command's own status -- wherever it fails.
cat >"$SANDBOX/trap-fixture" <<FIXTURE
#!/usr/bin/env bash
set -euo pipefail
. "$BIN/lib/github-prs-common.sh"
fails() { sh -c 'exit 7'; echo "the function went on"; }
case "\$1" in
  top) sh -c 'exit 7' ;;
  function) fails ;;
  substitution) out=\$(echo before; sh -c 'exit 7'; echo after) ;;
  function-in-substitution) out=\$(fails) || exit \$? ;;
esac
echo "the script went on"
FIXTURE
for where in top function substitution function-in-substitution; do
  new_case "trap-$where"
  OUT=$(/bin/bash "$SANDBOX/trap-fixture" "$where" 2>"$CASE/stderr")
  RC=$?
  ERR=$(cat "$CASE/stderr")
  check "$RC" "3" "ERR trap, failure $where: exits 3, not the command's 7"
  check_contains "$ERR" "trap-fixture: \`sh -c 'exit 7'\` failed (exit 7)" \
    "ERR trap, failure $where: the catalogue line names the failed command and its status"
  check "$OUT" "" "ERR trap, failure $where: nothing after the failure runs"
done

# --- pr-closing-issues ---------------------------------------------------
new_case closing
printf 'Summary\n\nCloses #3\n' >"$CASE/body"
run pr-closing-issues 7
check "$RC" "0" "pr-closing-issues: exit 0"
check "$(calls)" "pr view 7 --json body --jq .body" \
  "pr-closing-issues: reads the body, and needs no repository lookup for #N"
check "$OUT" "PR #7 closes issues 3" "pr-closing-issues: reports the set"

# closing_case <name> <body> <expected stdout> -- run pr-closing-issues
# on PR 7 of the checkout's repository, github.com/o/r, with <body>.
closing_case() {
  new_case "closing-$1"
  printf '%s\n' "$2" >"$CASE/body"
  run pr-closing-issues 7
  check "$OUT" "$3" "pr-closing-issues: $1"
}

closing_case "#N" 'Closes #3' "PR #7 closes issues 3"
closing_case "repo#N" 'Fixes r#4' "PR #7 closes issues 4"
closing_case "owner/repo#N" 'Resolves o/r#5' "PR #7 closes issues 5"
closing_case "host/owner/repo#N" 'closed github.com/o/r#6' "PR #7 closes issues 6"
closing_case "an issue URL" 'Closes https://github.com/o/r/issues/8' "PR #7 closes issues 8"
closing_case "any case, a colon, one keyword per reference" \
  "$(printf 'FIXES: #9\nresolve O/R#10 and Closed #11\nCloses #12, #13')" "PR #7 closes issues 9, 10, 11, 12"
closing_case "an issue closed twice is reported once, in ascending order" \
  "$(printf 'Closes #21\nCloses #3\nCloses #21')" "PR #7 closes issues 3, 21"
closing_case "a bare N closes nothing" 'Closes 14' "PR #7 closes no issues"
closing_case "GH-N closes nothing" 'Closes GH-15' "PR #7 closes no issues"
closing_case "a word between keyword and reference closes nothing" \
  'Closes Dependabot alert #16' "PR #7 closes no issues"
closing_case "a reference naming another repository closes nothing" \
  "$(printf 'Closes x/r#17\nCloses https://github.com/o/x/issues/18\nCloses ghe.example.com/o/r#19')" \
  "PR #7 closes no issues"
closing_case "a keyword inside a word, or with no space before the reference, closes nothing" \
  "$(printf 'prefix #20\nfix_bug.py\ncloses:#22\nReferences: #23')" "PR #7 closes no issues"
closing_case "a reference running into a word closes nothing" 'Closes #24abc' "PR #7 closes no issues"

new_case closing-other-repo
printf 'Closes #3\nCloses o2/r2#4\nCloses o/r#5\n' >"$CASE/body"
run pr-closing-issues 'o2/r2#7'
check "$OUT" "PR github.com/o2/r2#7 closes issues 3, 4" \
  "pr-closing-issues: a PR in another repository closes that repository's issues"

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

new_case ready-other-repo
echo true >"$CASE/draft"
run pr-ready 'o2/r2#7'
check "$RC" "0" "pr-ready: exit 0 for a PR in another repository"
check "$(call_line 2)" "pr ready 7 --repo github.com/o2/r2" "pr-ready: flips the PR in the repository the reference names"
check "$(call_line 3)" "pr view 7 --json isDraft --jq .isDraft --repo github.com/o2/r2" "pr-ready: re-reads it there"
check "$OUT" "PR github.com/o2/r2#7 is ready for review" "pr-ready: names the PR by its reference"

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
printf '%s\n' "New body with \`ticks\` and \$dollar" >"$SANDBOX/new-body.md"
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
check "$(call_line 1)" "repo view --json url --jq .url" "pr-comment: resolves the repository's host first"
check "$(call_line 2)" "pr comment 7 --body-file $SANDBOX/new-body.md" "pr-comment: posts by path"
check "$(call_line 3)" "api --hostname github.com repos/{owner}/{repo}/issues/comments/555 --jq .body" \
  "pr-comment: re-reads the comment by the id gh reported, on the repository's host"
check "$OUT" "https://github.com/o/r/pull/7#issuecomment-555" "pr-comment: prints the comment URL"

new_case comment-ghe
echo ghe.example.com >"$CASE/host"
run pr-comment 7 --body-file "$SANDBOX/new-body.md"
check "$RC" "0" "pr-comment: exit 0 in a GitHub Enterprise checkout"
check "$(call_line 3)" "api --hostname ghe.example.com repos/{owner}/{repo}/issues/comments/555 --jq .body" \
  "pr-comment: the re-read carries the checkout's host as --hostname"

new_case comment-other-host
echo ghe.example.com >"$CASE/api-host"
run pr-comment 'ghe.example.com/o2/r2#7' --body-file "$SANDBOX/new-body.md"
check "$RC" "0" "pr-comment: exit 0 for a PR on another host"
check "$(call_line 1)" "pr comment 7 --body-file $SANDBOX/new-body.md --repo ghe.example.com/o2/r2" \
  "pr-comment: posts to the repository the reference names"
check "$(call_line 2)" "api --hostname ghe.example.com repos/o2/r2/issues/comments/555 --jq .body" \
  "pr-comment: the re-read goes to the reference's host and repository, not the checkout's"
check "$(calls | grep -c '^repo view')" "0" "pr-comment: a reference with a host needs no repository lookup"

new_case comment-noop
touch "$CASE/noop"
run pr-comment 7 --body-file "$SANDBOX/new-body.md"
check "$RC" "1" "pr-comment: exit 1 when the posted body differs"
check "$ERR" "pr-comment: PR #7: the comment did not land: comment 555's body differs from $SANDBOX/new-body.md" \
  "pr-comment: the not-landed message"

new_case comment-no-id
echo "https://github.com/o/r/pull/7" >"$CASE/comment-url"
run pr-comment 7 --body-file "$SANDBOX/new-body.md"
check "$RC" "1" "pr-comment: exit 1 when gh's URL names no comment id"
check "$ERR" "pr-comment: PR #7: the comment did not land: gh reported \`https://github.com/o/r/pull/7\`, which names no comment id" \
  "pr-comment: the no-comment-id message"
check "$(calls | grep -c '^api')" "0" "pr-comment: a URL with no comment id is not re-read"

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

new_case link-all-linked
printf 'Summary\n\nCloses #3\nFixes o/r#4\n' >"$CASE/body"
run pr-link-issue 7 4 3
check "$RC" "0" "pr-link-issue: exit 0 when the body already closes every issue"
check "$(calls | grep -c '^pr edit')" "0" "pr-link-issue: a body already closing every issue is not written"
check "$OUT" "PR #7 already closes 4, 3" "pr-link-issue: reports the issues already closed"

new_case link-some-linked
printf 'Summary\n\nCloses #3\n' >"$CASE/body"
run pr-link-issue 7 3 4 4
check "$RC" "0" "pr-link-issue: exit 0 when the missing lines land"
check "$(cat "$CASE/stdin")" "$(printf 'Summary\n\nCloses #3\n\nCloses #4')" \
  "pr-link-issue: appends only the issues the body does not close, once each"
check "$OUT" "PR #7 already closes 3; appended Closes #4" \
  "pr-link-issue: names both the issues already closed and the lines appended"

new_case link-twice
echo "Summary" >"$CASE/body"
run pr-link-issue 7 3 4
run pr-link-issue 7 3 4
check "$(calls | grep -c '^pr edit')" "1" "pr-link-issue: a second run writes nothing"
check "$(cat "$CASE/body")" "$(printf 'Summary\n\nCloses #3\nCloses #4')" \
  "pr-link-issue: two runs leave one closing line per issue"
check "$OUT" "PR #7 already closes 3, 4" "pr-link-issue: the second run reports the issues already closed"

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
check "$ERR" "pr-create: PR #7: the draft PR did not land: the re-read reports isDraft, base and head as \`true main issue-3-4-x\`, not \`true integ issue-3-4-x\`" \
  "pr-create: the wrong-base message"

new_case create-not-draft
touch "$CASE/noop"
run pr-create --head b --title T --body-file "$SANDBOX/summary.md" 3
check "$RC" "1" "pr-create: exit 1 when the PR is not a draft"
check "$ERR" "pr-create: PR #7: the draft PR did not land: the re-read reports isDraft, base and head as \`false integ b\`, not \`true integ b\`" \
  "pr-create: the not-draft message"

new_case create-wrong-body
echo "Other text" >"$CASE/body-override"
run pr-create --head b --title T --body-file "$SANDBOX/summary.md" 3
check "$RC" "1" "pr-create: exit 1 when the PR carries another body"
check "$ERR" "pr-create: PR #7: the PR body did not land: the re-read body is not the body written" \
  "pr-create: the wrong-body message"

new_case create-no-pr-in-url
echo "https://github.com/o/r/pulls" >"$CASE/create-url"
run pr-create --head b --title T --body-file "$SANDBOX/summary.md" 3
check "$RC" "1" "pr-create: exit 1 when gh's URL names no PR number"
check "$ERR" "pr-create: gh pr create reported \`https://github.com/o/r/pulls\`, which names no PR number" \
  "pr-create: the no-PR-number message"
check "$(calls | grep -c '^pr view')" "0" "pr-create: a URL with no PR number is not re-read"

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

new_case create-blank-lead
mv "$REPO/.issues/repo-config.md" "$SANDBOX/repo-config.md"
{ printf '\n  \n'; cat "$SANDBOX/repo-config.md"; } >"$REPO/.issues/repo-config.md"
run pr-create --head b --title T --body-file "$SANDBOX/summary.md" 3
mv "$SANDBOX/repo-config.md" "$REPO/.issues/repo-config.md"
check "$RC" "0" "pr-create: blank lines before the opening --- still open the front matter"
check "$(call_line 1)" "pr create --draft --base integ --head b --title T --body-file -" \
  "pr-create: reads the base from front matter behind blank lines"

new_case create-no-front-matter
mv "$REPO/.issues/repo-config.md" "$SANDBOX/repo-config.md"
{ printf 'Preamble\n'; cat "$SANDBOX/repo-config.md"; } >"$REPO/.issues/repo-config.md"
run pr-create --head b --title T --body-file "$SANDBOX/summary.md" 3
mv "$SANDBOX/repo-config.md" "$REPO/.issues/repo-config.md"
check "$RC" "4" "pr-create: a first non-blank line other than --- leaves no front matter"
check "$(calls)" "" "pr-create: a repo-config with no front matter opens no PR"

# --- pr-review-submit ----------------------------------------------------
new_case review-approve
run pr-review-submit 7 --verdict approve "Looks good"
check "$RC" "0" "pr-review-submit: exit 0 when the review lands"
check "$(call_line 3)" "pr review 7 --approve --body-file -" "pr-review-submit: approve posts with --approve"
check "$(grep -c '^pr review' "$CASE/calls")" "1" "pr-review-submit: a review GitHub accepts posts once"
check "$(cat "$CASE/stdin")" "$(printf 'APPROVED\n\nLooks good')" "pr-review-submit: the body opens with the verdict word"
check "$OUT" "PR #7: verdict approve, review state approved, body inline" \
  "pr-review-submit: reports the state created and the body form"
check "$(grep '^api' "$CASE/calls" | grep -vc '^api --hostname github.com ')" "0" \
  "pr-review-submit: every api call carries the repository's host as --hostname"

new_case review-ghe
echo ghe.example.com >"$CASE/host"
run pr-review-submit 7 --verdict approve "Looks good"
check "$RC" "0" "pr-review-submit: exit 0 in a GitHub Enterprise checkout"
check "$(grep -c '^api --hostname ghe.example.com ' "$CASE/calls")" "3" \
  "pr-review-submit: its three api reads carry the checkout's host as --hostname"
check "$(grep '^api' "$CASE/calls" | grep -vc '^api --hostname ghe.example.com ')" "0" \
  "pr-review-submit: no api call goes to another host"

new_case review-other-repo
echo ghe.example.com >"$CASE/api-host"
run pr-review-submit 'https://ghe.example.com/o2/r2/pull/7' --verdict approve "Looks good"
check "$RC" "0" "pr-review-submit: exit 0 for a PR in another repository"
check "$(call_line 2)" "pr review 7 --approve --body-file - --repo ghe.example.com/o2/r2" \
  "pr-review-submit: the review posts to the repository the reference names"
check "$(grep -c '^api --hostname ghe.example.com .*repos/o2/r2/pulls/7/reviews' "$CASE/calls")" "3" \
  "pr-review-submit: its api reads go to the reference's host and repository"
check "$OUT" "PR ghe.example.com/o2/r2#7: verdict approve, review state approved, body inline" \
  "pr-review-submit: the report names the PR by its reference"

new_case review-self
echo me >"$CASE/author"
printf '%s\n' "Finding with \`ticks\` and \$HOME" >"$SANDBOX/review.md"
run pr-review-submit 7 --verdict request_changes --body-file "$SANDBOX/review.md"
check "$RC" "0" "pr-review-submit: a self-review exits 0"
check "$(call_line 3)" "pr review 7 --request-changes --body-file -" "pr-review-submit: a self-review first posts its verdict"
check "$(call_line 4)" "pr review 7 --comment --body-file -" "pr-review-submit: GitHub's refusal reposts with --comment"
check "$ERR" "" "pr-review-submit: the refusal it handled is not reported"
check "$(cat "$CASE/stdin")" "$(printf 'CHANGES_REQUESTED\n\n%s' "Finding with \`ticks\` and \$HOME")" \
  "pr-review-submit: a downgraded review keeps its verdict line, and the file's bytes reach gh"
check "$(cat "$SANDBOX/review.md")" "Finding with \`ticks\` and \$HOME" "pr-review-submit: the caller's file is untouched"
check "$OUT" "PR #7: verdict request_changes, review state commented, body file" \
  "pr-review-submit: a downgraded review reports commented"

new_case review-self-approve
echo me >"$CASE/author"
run pr-review-submit 7 --verdict approve "Looks good"
check "$RC" "0" "pr-review-submit: a self-approval exits 0"
check "$(call_line 4)" "pr review 7 --comment --body-file -" "pr-review-submit: a refused approval reposts with --comment"
check "$OUT" "PR #7: verdict approve, review state commented, body inline" \
  "pr-review-submit: a refused approval reports commented"

new_case review-post-fails
echo "pr review" >"$CASE/fail"
run pr-review-submit 7 --verdict approve "Looks good"
check "$RC" "3" "pr-review-submit: any other gh failure exits 3"
check "$ERR" "$(printf '%s\n%s' "stub gh: pr review refused" "pr-review-submit: gh pr review failed (exit 1)")" \
  "pr-review-submit: gh's own error, then the catalogue line"
check "$(grep -c '^pr review' "$CASE/calls")" "1" "pr-review-submit: any other gh failure posts no comment"

new_case review-noop
touch "$CASE/noop"
run pr-review-submit 7 --verdict comment "Note"
check "$RC" "1" "pr-review-submit: exit 1 when no new review appears"
check "$ERR" "pr-review-submit: PR #7: the review did not land: no new review is on the PR" \
  "pr-review-submit: the not-landed message"

new_case review-noop-identical
touch "$CASE/noop"
printf '%s\n' '[{"id": 90, "user": {"login": "me"}, "state": "COMMENTED", "body": "COMMENTED\n\nNote"}]' >"$CASE/reviews.json"
run pr-review-submit 7 --verdict comment "Note"
check "$RC" "1" "pr-review-submit: an earlier review with the same body does not pass for the new one"

new_case review-wrong-state
echo APPROVED >"$CASE/review-state"
run pr-review-submit 7 --verdict comment "Note"
check "$RC" "1" "pr-review-submit: exit 1 when the new review carries another state"
check "$ERR" "pr-review-submit: PR #7: the review did not land: review 100 has state APPROVED, not COMMENTED" \
  "pr-review-submit: the wrong-state message"

new_case review-wrong-body
echo "Other text" >"$CASE/review-body"
run pr-review-submit 7 --verdict comment "Note"
check "$RC" "1" "pr-review-submit: exit 1 when the new review carries another body"
check "$ERR" "pr-review-submit: PR #7: the review did not land: review 100's body is not the body written" \
  "pr-review-submit: the wrong-body message"

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
check "$ERR" "pr-ready-to-merge: PR #7: mergeable is still UNKNOWN after 3 reads. GitHub has not finished computing the merge state." \
  "pr-ready-to-merge: the still-unknown message"

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
git -C "$SEED" checkout -q --orphan unrelated
git -C "$SEED" rm -q -rf .
echo alone >"$SEED/alone.txt"
git -C "$SEED" add . && git -C "$SEED" commit -q -m unrelated
git -C "$SEED" checkout -q main
printf 'one\nMAIN\nthree\n' >"$SEED/file.txt"
git -C "$SEED" commit -q -am main
git -C "$SEED" push -q origin main feature clean unrelated
git clone -q "$ORIGIN" "$CLONE"
echo ".claude/" >"$CLONE/.git/info/exclude"

# run_conflicts <args...> -- run pr-merge-conflicts from $CLONE, with a
# case's own bin/ ahead of the stubs when it has one.
run_conflicts() {
  OUT=$(cd "$CLONE" && PATH="$CASE/bin:$SANDBOX/bin:$PATH" STUB_DIR="$CASE" \
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

# A git whose per-file `diff` fails: a command the verb runs without
# handling it, inside a loop, after the worktree exists.
new_case conflicts-diff-fails
echo feature >"$CASE/head"
mkdir -p "$CASE/bin"
cat >"$CASE/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *' diff -- '*) echo "stub git: diff refused" >&2; exit 9 ;;
esac
exec "$(command -v git)" "\$@"
STUB
chmod +x "$CASE/bin/git"
run_conflicts 7
check "$RC" "3" "pr-merge-conflicts: an unhandled git failure exits 3, not git's 9"
check_contains "$ERR" "pr-merge-conflicts: \`git -C \"\$tree\" diff -- \"\$file\"\` failed (exit 9)" \
  "pr-merge-conflicts: the catalogue line names the failed git command"
check "$(git -C "$CLONE" worktree list | wc -l | tr -d ' ')" "1" \
  "pr-merge-conflicts: the worktree is removed after an unhandled failure too"

new_case conflicts-clean
echo clean >"$CASE/head"
run_conflicts 7
check "$RC" "0" "pr-merge-conflicts: a clean trial merge exits 0"
check_contains "$OUT" "The trial merge is clean: no conflicts with origin/main." "pr-merge-conflicts: says the merge is clean"

new_case conflicts-merge-refused
echo feature >"$CASE/head"
echo unrelated >"$CASE/base"
run_conflicts 7
check "$RC" "3" "pr-merge-conflicts: a merge that fails without a conflict exits 3"
check "$ERR" "fatal: refusing to merge unrelated histories
pr-merge-conflicts: the trial merge of origin/unrelated failed without leaving a conflicted file" \
  "pr-merge-conflicts: git's own error precedes the catalogue line"
check "$(git -C "$CLONE" worktree list | wc -l | tr -d ' ')" "1" "pr-merge-conflicts: a refused merge's worktree is removed"

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

# A PR of another repository is fetched from that repository's URL, which
# the clone's insteadOf points at a bare repository standing in for it.
OTHER="$SANDBOX/other.git"
git clone -q --bare "$ORIGIN" "$OTHER"
git -C "$CLONE" config url."$OTHER".insteadOf https://other.example/o2/r2.git
new_case conflicts-other-repo
echo feature >"$CASE/head"
origin_refs=$(git -C "$CLONE" for-each-ref refs/remotes)
run_conflicts 'other.example/o2/r2#7'
check "$RC" "0" "pr-merge-conflicts: exit 0 for a PR of another repository"
check "$(call_line 1)" "pr view 7 --json headRefName,baseRefName --jq \"\\(.headRefName) \\(.baseRefName)\" --repo other.example/o2/r2" \
  "pr-merge-conflicts: reads head and base from the repository the reference names"
check_contains "$OUT" "  file.txt" "pr-merge-conflicts: another repository's conflicts are reported"
check "$(git -C "$CLONE" for-each-ref refs/pr-merge-conflicts)" "" \
  "pr-merge-conflicts: the refs fetched from another repository are deleted"
check "$(git -C "$CLONE" for-each-ref refs/remotes)" "$origin_refs" \
  "pr-merge-conflicts: no remote-tracking ref changes for another repository's PR"

# Two other repositories' PR 7 must not fetch into the same refs, or one
# run's cleanup deletes the other's. A post-checkout hook, which the
# worktree add fires, records the refs each run holds at that point.
new_case conflicts-two-other-repos
echo feature >"$CASE/head"
git -C "$CLONE" config url."$OTHER".insteadOf https://third.example/o3/r3.git --add
mkdir -p "$CASE/hooks"
printf '#!/bin/sh\ngit for-each-ref --format="%%(refname)" refs/pr-merge-conflicts >>"%s"\n' \
  "$CASE/refs-seen" >"$CASE/hooks/post-checkout"
chmod +x "$CASE/hooks/post-checkout"
git -C "$CLONE" config core.hooksPath "$CASE/hooks"
run_conflicts 'other.example/o2/r2#7'
check "$RC" "0" "pr-merge-conflicts: one other repository's PR 7 runs"
mv "$CASE/refs-seen" "$CASE/refs-other"
run_conflicts 'third.example/o3/r3#7'
check "$RC" "0" "pr-merge-conflicts: a second other repository's PR 7 runs"
git -C "$CLONE" config --unset core.hooksPath
check "$(cat "$CASE/refs-other" "$CASE/refs-seen" | wc -l | tr -d ' ')" "4" \
  "pr-merge-conflicts: each run holds its head and base refs at the worktree add"
check "$(sort "$CASE/refs-other" "$CASE/refs-seen" | uniq -d)" "" \
  "pr-merge-conflicts: two other repositories' PR 7 fetch into distinct refs"

new_case conflicts-other-repo-clean
echo clean >"$CASE/head"
run_conflicts 'other.example/o2/r2#7'
check_contains "$OUT" "The trial merge is clean: no conflicts with main of other.example/o2/r2." \
  "pr-merge-conflicts: names another repository's base"

new_case conflicts-other-repo-own-leftover
echo feature >"$CASE/head"
git -C "$CLONE" worktree add -q --detach "$CLONE/.claude/worktrees/pr-merge-conflicts-7" origin/feature
run_conflicts 'other.example/o2/r2#7'
check "$RC" "0" "pr-merge-conflicts: another repository's PR 7 runs beside the checkout's own"
check "$([ -e "$CLONE/.claude/worktrees/pr-merge-conflicts-7" ] && echo kept || echo removed)" "kept" \
  "pr-merge-conflicts: another repository's PR 7 leaves the checkout's own PR 7 worktree alone"
git -C "$CLONE" worktree remove --force "$CLONE/.claude/worktrees/pr-merge-conflicts-7"

new_case conflicts-other-repo-leftover-fails
echo feature >"$CASE/head"
mkdir -p "$CLONE/.claude/worktrees/pr-merge-conflicts-other.example+o2+r2-7"
run_conflicts 'other.example/o2/r2#7'
check "$RC" "3" "pr-merge-conflicts: a leftover that is not a worktree fails the removal"
check "$(git -C "$CLONE" for-each-ref refs/pr-merge-conflicts)" "" \
  "pr-merge-conflicts: a failed leftover removal still deletes the refs fetched from another repository"
rmdir "$CLONE/.claude/worktrees/pr-merge-conflicts-other.example+o2+r2-7"

new_case conflicts-own-repo-by-reference
echo feature >"$CASE/head"
run_conflicts 'github.com/o/r#7'
check "$RC" "0" "pr-merge-conflicts: a reference naming the checkout's own repository merges from origin"
check "$(git -C "$CLONE" for-each-ref refs/pr-merge-conflicts)" "" \
  "pr-merge-conflicts: the checkout's own repository fetches no refs of the verb's own"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
