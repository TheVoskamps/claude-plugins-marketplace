#!/usr/bin/env bash
#
# sdlc-orchestrate-cleanup-test.sh -- drive plugins/sdlc/bin/sdlc-orchestrate-cleanup,
# under the bash 3.2 macOS ships, against a primary clone of a local
# bare origin holding worktrees, branches, .claude/tmp/ scratch and a
# directory of session scratchpads, with stub git-default-branch, gh,
# pr-view, pr-closing-issues, issue-view and sdlc-agent-result-persist
# executables and git-tools' own git-issue-branch first on PATH and a
# logging git wrapper in front of the real git: each scope's dry run
# printing what its real run acts on and removing nothing; --pr removing
# only the worktrees its state names an agent for -- whatever their HEAD,
# nested ones included -- and any other worktree under .claude/worktrees/
# holding its head branch, those agents' worktree-agent-<id> branches,
# its local head branch once its issues are closed and its issues'
# scratch; review state neither listed nor deleted in either scope
# without --review-state, and with it the PR's or every PR's deleted,
# --pr reading the agents before it deletes the review state; a branch
# checked out outside .claude/worktrees/ kept rather than failed; the
# primary clone detached off the head branch when another worktree holds
# the default branch; --all removing every worktree, every
# worktree-agent-<id> branch and closed issue branch and no other, all
# scratch and every scratchpad but its own; removal of a dirty, unpushed
# worktree; locked worktrees -- a live lock, a dead pid, a reused pid, a
# lock of another reason -- kept, with and without --stale-locks, and the
# worktree around a kept one; under --pr, the invoking session's live
# lock on a recorded agent's worktree released and that worktree removed,
# and every other live lock kept; the branches of kept worktrees and of
# open or unreadable issues kept, an open head branch the primary clone
# holds for the same reason in a dry run and a real run; scratch and
# scratchpads held back while a locked worktree remains, under --pr only
# for the PR's own; the primary
# clone switched to the default branch before any branch is deleted, in
# both scopes, and the fast-forward of the default branch there or in
# the worktree holding it; an action that fails while the rest carry on;
# an open PR, a PR in another repository and an unresolved default
# branch refused with nothing removed; that no run pushes to origin; and
# the usage errors.
#
# Needs git and ps on PATH, and plugins/git-tools/bin/git-issue-branch in
# the same checkout. Reaches no network.
#
# Usage: sdlc-orchestrate-cleanup-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../bin/sdlc-orchestrate-cleanup"
ISSUE_BRANCH="$(cd "$TEST_DIR/../../git-tools/bin" && pwd)/git-issue-branch"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-orchestrate-cleanup-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
# The real path, so the paths git reports and the ones expected here
# are spelled alike.
SANDBOX=$(cd "$SANDBOX" && pwd -P)
# No state a run could reach is the user's own, whatever a stub misses.
export XDG_STATE_HOME="$SANDBOX/state"
FAILURES=0
PR='h.example/o/r#7'

# check <actual> <expected> <label>: passes when the two are equal, and
# otherwise prints both and counts a failure in FAILURES.
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

# check_contains <actual> <substring> <label>: passes when the actual
# text contains the substring, and otherwise prints both and counts a
# failure in FAILURES.
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

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REAL_GIT=$(command -v git)
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
SERVE="$SANDBOX/serve"

# The origin: main, and the PR's head branch issue-7-feat with two
# commits, C1 and C2.
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q -b main "$SEED"
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" commit -q --allow-empty -m base
BASE=$(git -C "$SEED" rev-parse HEAD)
git -C "$SEED" checkout -q -b issue-7-feat
git -C "$SEED" commit -q --allow-empty -m c1
C1=$(git -C "$SEED" rev-parse HEAD)
git -C "$SEED" commit -q --allow-empty -m c2
git -C "$SEED" push -q origin main issue-7-feat
git -C "$SEED" checkout -q main

# The stubs. git-default-branch prints serve/default and fails when it
# is absent. gh prints serve/repo-url for `repo view`. pr-view fails when
# serve/pr-view.fail exists, and otherwise prints the reference for --ref
# and serve/facts for anything else; pr-closing-issues prints
# serve/closing; and sdlc-agent-result-persist prints serve/list for
# --mode list and serve/agents for --mode print-agents, and logs
# --mode delete's --pr to serve/deleted, failing for the PR named in
# serve/delete.fail. issue-view prints issue <N>'s title line with the
# state in serve/issue-<N>, a title carrying parentheses of its own, and
# fails when that file is absent. Each logs its arguments to
# serve/<name>.args. git-issue-branch runs git-tools' own. The git
# wrapper logs every call to serve/git.log.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/git-default-branch" <<EOF
#!/bin/sh
echo "\$*" >>"$SERVE/git-default-branch.args"
[ -f "$SERVE/default" ] || { echo "git-default-branch: stub: no default" >&2; exit 1; }
cat "$SERVE/default"
EOF
cat >"$SANDBOX/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >>"$SERVE/gh.args"
cat "$SERVE/repo-url"
EOF
cat >"$SANDBOX/bin/pr-view" <<EOF
#!/bin/sh
echo "\$*" >>"$SERVE/pr-view.args"
[ ! -f "$SERVE/pr-view.fail" ] || { echo "pr-view: stub failure" >&2; exit 1; }
case "\$2" in
  --ref) echo "$PR" ;;
  *) cat "$SERVE/facts" ;;
esac
EOF
cat >"$SANDBOX/bin/pr-closing-issues" <<EOF
#!/bin/sh
echo "\$*" >>"$SERVE/pr-closing-issues.args"
cat "$SERVE/closing"
EOF
cat >"$SANDBOX/bin/sdlc-agent-result-persist" <<EOF
#!/bin/sh
echo "\$*" >>"$SERVE/sdlc-agent-result-persist.args"
case "\$2" in
  list) cat "$SERVE/list" ;;
  print-agents) cat "$SERVE/agents" ;;
  delete)
    if [ "\$4" = "\$(cat "$SERVE/delete.fail" 2>/dev/null)" ]; then
      echo "persist: stub refused \$4" >&2
      exit 2
    fi
    echo "\$4" >>"$SERVE/deleted"
    ;;
esac
EOF
cat >"$SANDBOX/bin/issue-view" <<EOF
#!/bin/sh
echo "\$*" >>"$SERVE/issue-view.args"
[ -f "$SERVE/issue-\$1" ] || { echo "issue-view: stub: no issue \$1" >&2; exit 1; }
printf '#%s A title (CLOSED soon)    (%s)\n' "\$1" "\$(cat "$SERVE/issue-\$1")"
EOF
printf '#!/bin/sh\nexec "%s" "$@"\n' "$ISSUE_BRANCH" >"$SANDBOX/bin/git-issue-branch"
cat >"$SANDBOX/bin/git" <<EOF
#!/bin/sh
echo "\$*" >>"$SERVE/git.log"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SANDBOX/bin/"*

# build <case> -- a fresh primary clone, PRIMARY, with origin's main one
# commit ahead of it, holding:
#   .claude/worktrees/agent-a    on issue-7-feat, dirty, one commit
#                                unpushed
#   .claude/worktrees/agent-b    detached at main, on none of the PR's
#                                commits
#   .claude/worktrees/agent-b/.claude/worktrees/agent-n
#                                nested, detached at C1
#   .claude/worktrees/agent-c    on worktree-agent-c, at main
#   .claude/worktrees/agent-d    detached at main
#   branches main, issue-7-feat, other-branch, worktree-agent-b,
#   worktree-agent-c
#   .claude/tmp/issue-7, .claude/tmp/task-17, .claude/tmp/other-9
# and SESSIONS holding s1/scratchpad -- this session's, PAD -- and
# s2/scratchpad, s3/scratchpad and s2/tasks. No worktree is locked. The
# stubs serve a merged PR of this checkout's repository closing issue 7,
# closed, whose state names the agents a, b, n and x -- x with no
# worktree -- review state for PRs 7 and 8, and main as the default
# branch.
build() {
  CASE="$SANDBOX/$1"
  PRIMARY="$CASE/primary"
  WT="$PRIMARY/.claude/worktrees"
  SESSIONS="$CASE/sessions"
  PAD="$SESSIONS/s1/scratchpad"
  git clone -q "$ORIGIN" "$PRIMARY"
  git -C "$PRIMARY" branch -q issue-7-feat origin/issue-7-feat
  git -C "$PRIMARY" branch -q other-branch
  git -C "$PRIMARY" branch -q worktree-agent-b
  git -C "$PRIMARY" worktree add -q "$WT/agent-a" issue-7-feat
  echo dirty >"$WT/agent-a/dirty.txt"
  git -C "$WT/agent-a" commit -q --allow-empty -m unpushed
  echo more >"$WT/agent-a/more.txt"
  git -C "$PRIMARY" worktree add -q --detach "$WT/agent-b" main
  git -C "$PRIMARY" worktree add -q --detach "$WT/agent-b/.claude/worktrees/agent-n" "$C1"
  git -C "$PRIMARY" worktree add -q -b worktree-agent-c "$WT/agent-c" main
  git -C "$PRIMARY" worktree add -q --detach "$WT/agent-d" main
  mkdir -p "$PRIMARY/.claude/tmp/issue-7" "$PRIMARY/.claude/tmp/task-17"
  echo x >"$PRIMARY/.claude/tmp/other-9"
  mkdir -p "$PAD" "$SESSIONS/s2/scratchpad" "$SESSIONS/s3/scratchpad" "$SESSIONS/s2/tasks"

  git -C "$SEED" commit -q --allow-empty -m "main advances ($1)"
  git -C "$SEED" push -q origin main
  ORIGIN_MAIN=$(git -C "$SEED" rev-parse HEAD)

  rm -rf "$SERVE"
  mkdir -p "$SERVE"
  echo main >"$SERVE/default"
  echo https://h.example/o/r >"$SERVE/repo-url"
  printf 'MERGED\nissue-7-feat\n' >"$SERVE/facts"
  echo "PR $PR closes issues 7" >"$SERVE/closing"
  echo CLOSED >"$SERVE/issue-7"
  printf 'a\nb\nn\nx\n' >"$SERVE/agents"
  printf '%s\n%s\n' "$PR" 'h.example/o/r#8' >"$SERVE/list"
  ORIGIN_REFS=$(git -C "$ORIGIN" for-each-ref)
}

# run <arg>... -- run the script from PRIMARY with the stubs first on
# PATH; leaves OUT, ERR, RC.
run() {
  OUT=$(cd "$PRIMARY" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$SCRIPT" "$@" 2>"$SANDBOX/stderr")
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
}

# snapshot -- what a run could remove: the worktrees, the branches, the
# scratch, the scratchpads and the review state deleted.
snapshot() {
  git -C "$PRIMARY" worktree list --porcelain | grep '^worktree '
  git -C "$PRIMARY" for-each-ref --format='%(refname)' refs/heads/
  ls -A "$PRIMARY/.claude/tmp" 2>/dev/null
  ls -d "$SESSIONS"/*/* 2>/dev/null
  cat "$SERVE/deleted" 2>/dev/null
}

# branches -- the local branches, one line.
branches() {
  git -C "$PRIMARY" for-each-ref --format='%(refname:lstrip=2)' refs/heads/ | tr '\n' ' '
}

# untouched_origin <label> -- origin's refs are what build left, and no
# git call the script made pushed.
untouched_origin() {
  check "$(git -C "$ORIGIN" for-each-ref)" "$ORIGIN_REFS" "$1: origin's refs are unchanged"
  check "$(grep -cw push "$SERVE/git.log")" "0" "$1: no git push ran"
}

check "$([ -x "$SCRIPT" ] && echo yes)" "yes" "sdlc-orchestrate-cleanup is executable"

# --- --pr ---------------------------------------------------------------
build pr
EXPECTED="remove worktree $WT/agent-b/.claude/worktrees/agent-n
remove worktree $WT/agent-b
remove worktree $WT/agent-a
delete branch issue-7-feat
delete branch worktree-agent-b
remove scratch $PRIMARY/.claude/tmp/issue-7"
BEFORE=$(snapshot)
run --pr 7 --dry-run
check "$RC" "0" "--pr dry run: exit 0"
check "$OUT" "$(printf '%s\n' "$EXPECTED" | sed 's/^/would-/')" "--pr dry run: every item as would-<action>, no review-state line"
check "$(snapshot)" "$BEFORE" "--pr dry run: nothing removed"
check "$(git -C "$PRIMARY" rev-parse main)" "$BASE" "--pr dry run: the default branch is not pulled"
check "$(grep -cE 'fetch|pull|switch|prune|remove|unlock|branch -D' "$SERVE/git.log")" "0" \
  "--pr dry run: no git call acts"
check "$(awk '{print $2}' "$SERVE/sdlc-agent-result-persist.args" | tr '\n' ' ')" "print-agents " \
  "--pr dry run: review state is neither listed nor deleted, only the agents read"

rm -f "$SERVE/sdlc-agent-result-persist.args" "$SERVE/gh.args"
run --pr 7
check "$RC" "0" "--pr: exit 0"
check "$OUT" "$EXPECTED" "--pr: the dry run's items, acted on"
check "$([ -f "$SERVE/deleted" ] && echo deleted)" "" "--pr: no review state is deleted"
check "$(sed -n 1p "$SERVE/pr-view.args")" "7 --ref" "--pr: the PR is resolved to its reference"
check "$(cat "$SERVE/gh.args")" "repo view --json url --jq .url" "--pr: this checkout's repository comes from gh repo view"
check "$(cat "$SERVE/sdlc-agent-result-persist.args")" "--mode print-agents --pr $PR" \
  "--pr: the agents are read for the PR's reference, and review state is neither listed nor deleted"
check "$([ -e "$WT/agent-a" ] || [ -e "$WT/agent-b" ] && echo left)" "" \
  "--pr: the agents' worktrees are gone, dirty, unpushed and off the PR's commits included"
check "$([ -d "$WT/agent-c" ] && [ -d "$WT/agent-d" ] && echo kept)" "kept" \
  "--pr: worktrees of agents the PR's state does not name are kept, one at the same HEAD as a removed one"
check "$(git -C "$PRIMARY" worktree list --porcelain | grep -c '^worktree ')" "3" "--pr: three worktrees remain registered"
check "$(branches)" "main other-branch worktree-agent-c " "--pr: only the head branch and the agents' branches are deleted"
check "$(printf '%s ' "$PRIMARY/.claude/tmp/"*)" "$PRIMARY/.claude/tmp/other-9 $PRIMARY/.claude/tmp/task-17 " \
  "--pr: only the closed issue's scratch is removed"
check "$(printf '%s ' "$SESSIONS"/*/*)" "$PAD $SESSIONS/s2/scratchpad $SESSIONS/s2/tasks $SESSIONS/s3/scratchpad " \
  "--pr: no scratchpad is touched"
check "$(git -C "$PRIMARY" rev-parse main)" "$ORIGIN_MAIN" "--pr: the default branch is fast-forwarded in place"
untouched_origin "--pr"

# --- --pr --review-state -----------------------------------------------------
build pr-review-state
EXPECTED="delete review-state $PR
remove worktree $WT/agent-b/.claude/worktrees/agent-n
remove worktree $WT/agent-b
remove worktree $WT/agent-a
delete branch issue-7-feat
delete branch worktree-agent-b
remove scratch $PRIMARY/.claude/tmp/issue-7"
BEFORE=$(snapshot)
run --review-state --pr 7 --dry-run
check "$RC" "0" "--pr --review-state dry run: exit 0"
check "$OUT" "$(printf '%s\n' "$EXPECTED" | sed 's/^/would-/')" \
  "--pr --review-state dry run: every item as would-<action>, the review state included"
check "$(snapshot)" "$BEFORE" "--pr --review-state dry run: nothing removed"

rm -f "$SERVE/sdlc-agent-result-persist.args"
run --pr 7 --review-state
check "$RC" "0" "--pr --review-state: exit 0"
check "$OUT" "$EXPECTED" "--pr --review-state: the dry run's items, acted on"
check "$(cat "$SERVE/deleted")" "$PR" "--pr --review-state: only the PR's review state is deleted"
check "$(awk '{print $2}' "$SERVE/sdlc-agent-result-persist.args" | tr '\n' ' ')" "print-agents list delete " \
  "--pr --review-state: the PR's agents are read before its review state is deleted"
check "$(sed -n 2p "$SERVE/sdlc-agent-result-persist.args")" "--mode list h.example/o/r" \
  "--pr --review-state: review state is listed for the PR's repository"
check "$(branches)" "main other-branch worktree-agent-c " "--pr --review-state: only the head branch and the agents' branches are deleted"

# --- --pr with the head branch checked out in the primary clone ------------
build pr-switch
git -C "$WT/agent-a" checkout -q --detach
git -C "$PRIMARY" checkout -q issue-7-feat
run --pr 7
check "$RC" "0" "--pr, head branch in the primary clone: exit 0"
check "$([ -e "$WT/agent-a" ] && echo left)" "" "--pr: an agent's worktree at a detached HEAD is removed"
check_contains "$OUT" "delete branch issue-7-feat
delete branch worktree-agent-b" "--pr, head branch in the primary clone: its deletion does not fail"
check "$(branches)" "main other-branch worktree-agent-c " "--pr, head branch in the primary clone: the head branch is deleted"
check "$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)" "main" \
  "--pr, head branch in the primary clone: the primary clone is on the default branch"
check "$(git -C "$PRIMARY" rev-parse main)" "$ORIGIN_MAIN" "--pr, head branch in the primary clone: and it is pulled"
check "$(grep -n -e '^-C [^ ]* switch main' -e '^-C [^ ]* branch -D' "$SERVE/git.log" | sed -n 1p | cut -d' ' -f3)" \
  "switch" "--pr, head branch in the primary clone: the switch runs before any branch is deleted"

# --- --pr with the head branch in a worktree no recorded agent ran in -----
build pr-unrecorded
git -C "$WT/agent-a" checkout -q --detach
git -C "$PRIMARY" worktree add -q "$WT/manual" issue-7-feat
run --pr 7 --dry-run
check_contains "$OUT" "would-remove worktree $WT/manual" "--pr, head branch in an unrecorded worktree, dry run: the worktree is listed"
check_contains "$OUT" "would-delete branch issue-7-feat" "--pr, head branch in an unrecorded worktree, dry run: and the branch"
run --pr 7
check "$RC" "0" "--pr, head branch in an unrecorded worktree: exit 0"
check_contains "$OUT" "remove worktree $WT/manual" "--pr, head branch in an unrecorded worktree: the worktree is removed"
check "$([ -e "$WT/manual" ] && echo left)" "" "--pr, head branch in an unrecorded worktree: its directory is gone"
check "$(branches)" "main other-branch worktree-agent-c " "--pr, head branch in an unrecorded worktree: the head branch is deleted"
check "$([ -d "$WT/agent-c" ] && [ -d "$WT/agent-d" ] && echo kept)" "kept" \
  "--pr, head branch in an unrecorded worktree: unrecorded worktrees off the PR's branches are kept"

# --- --pr with the head branch in the primary clone, main held elsewhere ---
build pr-detach
git -C "$WT/agent-a" checkout -q --detach
git -C "$PRIMARY" checkout -q issue-7-feat
git -C "$PRIMARY" worktree add -q "$CASE/main-wt" main
run --pr 7 --dry-run
check_contains "$OUT" "would-delete branch issue-7-feat" "--pr, primary clone on the head branch, main held elsewhere, dry run: the branch is listed"
run --pr 7
check "$RC" "0" "--pr, primary clone on the head branch, main held elsewhere: exit 0"
check "$(printf '%s\n' "$OUT" | grep -c '^failed')" "0" "--pr, primary clone on the head branch, main held elsewhere: nothing fails"
check "$(branches)" "main other-branch worktree-agent-c " \
  "--pr, primary clone on the head branch, main held elsewhere: the head branch is deleted"
check "$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)" "HEAD" \
  "--pr, primary clone on the head branch, main held elsewhere: the primary clone is detached"
check "$(git -C "$CASE/main-wt" rev-parse HEAD)" "$ORIGIN_MAIN" \
  "--pr, primary clone on the head branch, main held elsewhere: main is pulled in its worktree"

# --- a branch checked out outside .claude/worktrees/ is kept ---------------
build keep
git -C "$WT/agent-a" checkout -q --detach
git -C "$PRIMARY" worktree add -q "$CASE/head-wt" issue-7-feat
run --pr 7 --dry-run
check_contains "$OUT" "would-keep branch issue-7-feat: checked out at $CASE/head-wt" \
  "kept branch, dry run: listed as would-keep"
run --pr 7
check "$RC" "0" "kept branch: exit 0"
check_contains "$OUT" "keep branch issue-7-feat: checked out at $CASE/head-wt" "kept branch: reported as kept"
check "$(printf '%s\n' "$OUT" | grep -c -e '^failed' -e '^delete branch issue-7-feat')" "0" \
  "kept branch: neither deleted nor failed"
check "$(branches)" "issue-7-feat main other-branch worktree-agent-c " "kept branch: the branch is still there"
check "$([ -d "$CASE/head-wt" ] && echo kept)" "kept" "kept branch: the worktree outside .claude/worktrees/ is not removed"
run --all --scratchpad "$PAD"
check "$RC" "0" "kept branch, --all: exit 0"
check_contains "$OUT" "keep branch issue-7-feat: checked out at $CASE/head-wt" "kept branch, --all: reported as kept"
check "$(branches)" "issue-7-feat main other-branch " \
  "kept branch, --all: every other worktree-agent-<id> and issue branch is deleted"

# --- --pr refusals --------------------------------------------------------
build open
printf 'OPEN\nissue-7-feat\n' >"$SERVE/facts"
BEFORE=$(snapshot)
run --pr 7
check "$RC:$OUT" "3:" "open PR: exit 3, nothing on stdout"
check_contains "$ERR" "PR $PR is open; nothing was removed" "open PR: stderr says so"
check "$(snapshot)" "$BEFORE" "open PR: nothing removed"
run --pr 7 --dry-run
check "$RC:$OUT" "3:" "open PR, dry run: exit 3, nothing on stdout"

printf 'MERGED\nissue-7-feat\n' >"$SERVE/facts"
echo https://h.example/o/other >"$SERVE/repo-url"
rm -f "$SERVE/sdlc-agent-result-persist.args" "$SERVE/git.log"
run --pr 7
check "$RC:$OUT" "5:" "another repository's PR: exit 5, nothing on stdout"
check_contains "$ERR" "PR $PR is not in this checkout's repository, h.example/o/other; nothing was removed" \
  "another repository's PR: stderr names both repositories"
check "$(snapshot)" "$BEFORE" "another repository's PR: nothing removed"
check "$([ -f "$SERVE/sdlc-agent-result-persist.args" ] && echo ran)" "" \
  "another repository's PR: no review state is read"
check "$(grep -cE 'switch|remove|branch -D' "$SERVE/git.log")" "0" "another repository's PR: no git call acts"
run --pr 7 --dry-run
check "$RC:$OUT" "5:" "another repository's PR, dry run: exit 5, nothing on stdout"
echo https://H.example/O/R/ >"$SERVE/repo-url"
run --pr 7 --dry-run
check "$RC" "0" "this repository spelled in another case: the PR is this checkout's"
echo https://h.example/o/r >"$SERVE/repo-url"

rm -f "$SERVE/default"
run --pr 7
check "$RC:$OUT" "4:" "no default branch: exit 4, nothing on stdout"
check_contains "$ERR" "git-default-branch named no default branch; nothing was removed" "no default branch: stderr says so"
check_contains "$ERR" "git-default-branch: stub: no default" "no default branch: git-default-branch's own error passes through"
check "$(snapshot)" "$BEFORE" "no default branch: nothing removed"
rm -f "$SERVE/sdlc-agent-result-persist.args" "$SERVE/git.log"
run --all --scratchpad "$PAD"
check "$RC" "4" "no default branch, --all: exit 4"
check "$([ -f "$SERVE/sdlc-agent-result-persist.args" ] || [ -f "$SERVE/git.log" ] && echo ran)" "" \
  "no default branch: nothing past it ran"

echo main >"$SERVE/default"
touch "$SERVE/pr-view.fail"
run --pr 7
check "$RC:$OUT" "1:" "pr-view fails: exit 1, nothing on stdout"
check_contains "$ERR" "pr-view 7 --ref failed" "pr-view fails: stderr names the call"
check "$(snapshot)" "$BEFORE" "pr-view fails: nothing removed"

# --- the fast-forward where a worktree holds the default branch -------------
build in-place
git -C "$PRIMARY" checkout -q --detach
git -C "$PRIMARY" worktree add -q "$CASE/main-wt" main
run --pr 7
check "$RC" "0" "default branch held elsewhere: exit 0"
check "$(git -C "$CASE/main-wt" rev-parse HEAD)" "$ORIGIN_MAIN" "default branch held elsewhere: pulled in that worktree"
check "$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)" "HEAD" "default branch held elsewhere: the primary clone is not switched"

# --- --all ----------------------------------------------------------------
build all
EXPECTED="remove worktree $WT/agent-d
remove worktree $WT/agent-c
remove worktree $WT/agent-b/.claude/worktrees/agent-n
remove worktree $WT/agent-b
remove worktree $WT/agent-a
delete branch issue-7-feat
delete branch worktree-agent-b
delete branch worktree-agent-c
remove scratch $PRIMARY/.claude/tmp/issue-7
remove scratch $PRIMARY/.claude/tmp/other-9
remove scratch $PRIMARY/.claude/tmp/task-17
remove scratchpad $SESSIONS/s2/scratchpad
remove scratchpad $SESSIONS/s3/scratchpad"
BEFORE=$(snapshot)
run --all --scratchpad "$PAD/" --dry-run
check "$RC" "0" "--all dry run: exit 0"
check "$OUT" "$(printf '%s\n' "$EXPECTED" | sed 's/^/would-/')" "--all dry run: every item as would-<action>, no review-state line"
check "$(snapshot)" "$BEFORE" "--all dry run: nothing removed"
check "$([ -f "$SERVE/sdlc-agent-result-persist.args" ] && echo ran)" "" "--all dry run: review state is neither listed nor deleted"

run --all --scratchpad "$PAD"
check "$RC" "0" "--all: exit 0"
check "$OUT" "$EXPECTED" "--all: the dry run's items, acted on"
check "$([ -f "$SERVE/sdlc-agent-result-persist.args" ] && echo ran)" "" "--all: review state is neither listed nor deleted"
check "$(git -C "$PRIMARY" worktree list --porcelain | grep -c '^worktree ')" "1" "--all: only the primary clone remains"
check "$([ -e "$WT" ] && ls -A "$WT")" "" "--all: no worktree directory is left"
check "$(branches)" "main other-branch " "--all: only the default branch and a branch of neither kind are left"
check "$(ls -A "$PRIMARY/.claude/tmp")" "" "--all: all scratch is removed"
check "$(printf '%s ' "$SESSIONS"/*/*)" "$PAD $SESSIONS/s2/tasks " "--all: only this session's scratchpad, and no other session file, is left"
check "$(git -C "$PRIMARY" rev-parse main)" "$ORIGIN_MAIN" "--all: the default branch is fast-forwarded"
untouched_origin "--all"

# --- --all --review-state ----------------------------------------------------
build all-review-state
RS_EXPECTED="delete review-state $PR
delete review-state h.example/o/r#8"
run --all --review-state --scratchpad "$PAD" --dry-run
check "$RC" "0" "--all --review-state dry run: exit 0"
check "$(printf '%s\n' "$OUT" | grep ' review-state ')" "$(printf '%s\n' "$RS_EXPECTED" | sed 's/^/would-/')" \
  "--all --review-state dry run: every PR's review state as would-delete"
check "$([ -f "$SERVE/deleted" ] && echo deleted)" "" "--all --review-state dry run: no review state is deleted"
check "$(cat "$SERVE/sdlc-agent-result-persist.args")" "--mode list" \
  "--all --review-state dry run: review state is listed for this repository, and nothing else is read"
run --review-state --all --scratchpad "$PAD"
check "$RC" "0" "--all --review-state: exit 0"
check "$(printf '%s\n' "$OUT" | sed -n 1,2p)" "$RS_EXPECTED" "--all --review-state: the review state is deleted first"
check "$(cat "$SERVE/deleted" | tr '\n' ' ')" "$PR h.example/o/r#8 " "--all --review-state: every PR's review state is deleted"
check "$(branches)" "main other-branch " "--all --review-state: only the default branch and a branch of neither kind are left"

# --- an action that fails, and the switch to the default branch -------------
build failing
git -C "$PRIMARY" checkout -q worktree-agent-b
echo 'h.example/o/r#8' >"$SERVE/delete.fail"
run --all --scratchpad "$PAD" --review-state
check "$RC" "1" "a failed action: exit 1"
check_contains "$OUT" "delete review-state h.example/o/r#8
failed delete review-state h.example/o/r#8: persist: stub refused h.example/o/r#8
remove worktree" "a failed action: its failure line quotes the error, and the run goes on"
check_contains "$OUT" "remove scratchpad $SESSIONS/s3/scratchpad" "a failed action: the last item is still acted on"
check "$(printf '%s\n' "$OUT" | grep -c '^failed')" "1" "a failed action: no other action fails"
check_contains "$OUT" "delete branch worktree-agent-b
delete branch worktree-agent-c" "switch: the branch the primary clone had checked out is deleted without failing"
check "$(branches)" "main other-branch " "switch: every worktree-agent-<id> and issue branch is deleted"
check "$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)" "main" "switch: the primary clone is switched to the default branch"
check "$(git -C "$PRIMARY" rev-parse main)" "$ORIGIN_MAIN" "switch: and pulled"
untouched_origin "a failed action"

# --- locked worktrees -----------------------------------------------------
# The harness's lock shape, for this test's own shell -- a running pid --
# with its real start time, and two stale ones: a pid that has exited,
# and this shell's pid under another start time, as a reused pid reads.
LIVE_START=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$$")
DEAD_PID=$(sh -c 'echo $$')
# A running process that is no ancestor of the script.
sleep 600 >/dev/null 2>&1 &
OTHER_PID=$!
disown "$OTHER_PID"
trap 'kill "$OTHER_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
OTHER_START=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$OTHER_PID")
# lock_all -- lock agent-a live, agent-c with a dead pid, agent-d with a
# reused pid, and the nested agent-n with a reason of another shape.
lock_all() {
  git -C "$PRIMARY" worktree lock --reason "claude agent agent-a (pid $$ start $LIVE_START)" "$WT/agent-a"
  git -C "$PRIMARY" worktree lock --reason "claude agent agent-c (pid $DEAD_PID start Mon Jan  1 00:00:00 2001)" "$WT/agent-c"
  git -C "$PRIMARY" worktree lock --reason "claude agent agent-d (pid $$ start Mon Jan  1 00:00:00 2001)" "$WT/agent-d"
  git -C "$PRIMARY" worktree lock --reason "held by hand" "$WT/agent-b/.claude/worktrees/agent-n"
}

# locks -- the locked worktrees, one line.
locks() {
  git -C "$PRIMARY" worktree list --porcelain | awk '/^worktree /{p=$2} /^locked/{print p}' | tr '\n' ' '
}

build locks
lock_all
LOCKED_BEFORE=$(locks)
EXPECTED="keep worktree $WT/agent-d: locked
keep worktree $WT/agent-c: locked
keep worktree $WT/agent-b/.claude/worktrees/agent-n: locked
keep worktree $WT/agent-b: holds worktree $WT/agent-b/.claude/worktrees/agent-n
keep worktree $WT/agent-a: locked by running pid $$
keep branch issue-7-feat: worktree $WT/agent-a is kept
keep branch worktree-agent-b: worktree $WT/agent-b is kept
keep branch worktree-agent-c: worktree $WT/agent-c is kept
keep .claude/tmp: 4 locked worktree(s)
keep scratchpads: 4 locked worktree(s)"
BEFORE=$(snapshot)
run --all --scratchpad "$PAD" --dry-run
check "$RC" "0" "locks, --all dry run: exit 0"
check "$OUT" "$(printf '%s\n' "$EXPECTED" | sed 's/^/would-/')" "locks, --all dry run: every keep as would-keep"
run --all --scratchpad "$PAD"
check "$RC" "0" "locks, --all: exit 0, a keep being no failure"
check "$OUT" "$EXPECTED" "locks, --all: every locked worktree kept whatever its lock, the one around a kept one too"
check "$(snapshot)" "$BEFORE" "locks, --all: no worktree, branch, scratch or scratchpad is removed"
check "$(locks)" "$LOCKED_BEFORE" "locks, --all: every lock is still in place"
check "$(grep -cE 'worktree (unlock|remove)' "$SERVE/git.log")" "0" "locks, --all: no worktree is unlocked or removed"
untouched_origin "locks, --all"

build stale-locks
lock_all
EXPECTED="would-remove worktree $WT/agent-d
would-remove worktree $WT/agent-c
would-keep worktree $WT/agent-b/.claude/worktrees/agent-n: locked
would-keep worktree $WT/agent-b: holds worktree $WT/agent-b/.claude/worktrees/agent-n
would-keep worktree $WT/agent-a: locked by running pid $$
would-keep branch issue-7-feat: worktree $WT/agent-a is kept
would-keep branch worktree-agent-b: worktree $WT/agent-b is kept
would-delete branch worktree-agent-c
would-keep .claude/tmp: 2 locked worktree(s)
would-keep scratchpads: 2 locked worktree(s)"
run --all --scratchpad "$PAD" --stale-locks --dry-run
check "$RC" "0" "--stale-locks, --all dry run: exit 0"
check "$OUT" "$EXPECTED" "--stale-locks, --all dry run: the stale locks' worktrees listed for removal, the rest kept"
run --stale-locks --all --scratchpad "$PAD"
check "$RC" "0" "--stale-locks, --all: exit 0"
check "$OUT" "$(printf '%s\n' "$EXPECTED" | sed 's/^would-//')" "--stale-locks, --all: the dry run's items, acted on"
check "$([ -e "$WT/agent-c" ] || [ -e "$WT/agent-d" ] && echo left)" "" \
  "--stale-locks, --all: the dead pid's and the reused pid's worktrees are removed"
check "$(locks)" "$WT/agent-a $WT/agent-b/.claude/worktrees/agent-n " \
  "--stale-locks, --all: the live lock and the lock of another reason are kept"
check "$(branches)" "issue-7-feat main other-branch worktree-agent-b " \
  "--stale-locks, --all: only the removed worktree's branch is deleted"
check "$(printf '%s ' "$PRIMARY/.claude/tmp/"*)" \
  "$PRIMARY/.claude/tmp/issue-7 $PRIMARY/.claude/tmp/other-9 $PRIMARY/.claude/tmp/task-17 " \
  "--stale-locks, --all: .claude/tmp/ is kept while a locked worktree remains"
check "$(printf '%s ' "$SESSIONS"/*/*)" "$PAD $SESSIONS/s2/scratchpad $SESSIONS/s2/tasks $SESSIONS/s3/scratchpad " \
  "--stale-locks, --all: the scratchpads are kept while a locked worktree remains"

build stale-only
git -C "$PRIMARY" worktree lock --reason "claude agent agent-c (pid $DEAD_PID start Mon Jan  1 00:00:00 2001)" "$WT/agent-c"
run --all --scratchpad "$PAD" --stale-locks
check "$RC" "0" "--stale-locks, only a stale lock: exit 0"
check "$(git -C "$PRIMARY" worktree list --porcelain | grep -c '^worktree ')" "1" \
  "--stale-locks, only a stale lock: only the primary clone remains"
check "$(ls -A "$PRIMARY/.claude/tmp")" "" "--stale-locks, only a stale lock: all scratch is removed, no locked worktree remaining"
check "$(printf '%s ' "$SESSIONS"/*/*)" "$PAD $SESSIONS/s2/tasks " \
  "--stale-locks, only a stale lock: and every other scratchpad"

# Each case below runs once without --stale-locks and once with it, to
# the same outcome.
for flag in "" --stale-locks; do
  with=${flag:+ $flag}

  # --- issue branches under --all -------------------------------------------
  build "issue-branches$flag"
  git -C "$PRIMARY" branch -q issue-9-open
  git -C "$PRIMARY" branch -q issue-11-unread
  git -C "$PRIMARY" branch -q issue-7-12-pair
  echo OPEN >"$SERVE/issue-9"
  echo CLOSED >"$SERVE/issue-12"
  run --all --scratchpad "$PAD" ${flag:+"$flag"}
  check "$RC" "0" "issue branches, --all$with: exit 0"
  check "$(printf '%s\n' "$OUT" | grep ' branch ')" "keep branch issue-11-unread: issue #11 is open
delete branch issue-7-12-pair
delete branch issue-7-feat
keep branch issue-9-open: issue #9 is open
delete branch worktree-agent-b
delete branch worktree-agent-c" \
    "issue branches, --all$with: all-closed issue branches deleted, open and unreadable ones kept"
  check "$(branches)" "issue-11-unread issue-9-open main other-branch " "issue branches, --all$with: the kept branches remain"
  check "$(sort "$SERVE/issue-view.args" | tr '\n' ' ')" "11 12 7 9 " "issue branches, --all$with: each issue is read once"

  # --- --pr and the head branch's issues -------------------------------------
  build "pr-open-issue$flag"
  echo OPEN >"$SERVE/issue-7"
  git -C "$PRIMARY" branch -q issue-12-other
  echo CLOSED >"$SERVE/issue-12"
  run --pr 7 ${flag:+"$flag"}
  check "$RC" "0" "--pr$with, head branch's issue open: exit 0"
  check_contains "$OUT" "remove worktree $WT/agent-a
keep branch issue-7-feat: issue #7 is open
delete branch worktree-agent-b" "--pr$with, head branch's issue open: the PR's worktree goes, the head branch is kept"
  check "$(branches)" "issue-12-other issue-7-feat main other-branch worktree-agent-c " \
    "--pr$with, head branch's issue open: no other issue branch is deleted, closed or not"
  check "$(cat "$SERVE/issue-view.args")" "7" "--pr$with: only the head branch's issues are read"

  # --- --pr, an open head branch in the primary clone, main held elsewhere ---
  # No move off the branch is attempted, so the real run keeps it for its
  # open issue, as the dry run does.
  build "pr-open-primary$flag"
  echo OPEN >"$SERVE/issue-7"
  git -C "$WT/agent-a" checkout -q --detach
  git -C "$PRIMARY" checkout -q issue-7-feat
  git -C "$PRIMARY" worktree add -q "$CASE/main-wt" main
  run --pr 7 --dry-run ${flag:+"$flag"}
  check "$(printf '%s\n' "$OUT" | grep ' branch issue-7-feat')" "would-keep branch issue-7-feat: issue #7 is open" \
    "--pr$with, open head branch in the primary clone, dry run: kept for its open issue"
  run --pr 7 ${flag:+"$flag"}
  check "$RC" "0" "--pr$with, open head branch in the primary clone: exit 0"
  check "$(printf '%s\n' "$OUT" | grep ' branch issue-7-feat')" "keep branch issue-7-feat: issue #7 is open" \
    "--pr$with, open head branch in the primary clone: kept for its open issue, as in the dry run"
  check "$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)" "issue-7-feat" \
    "--pr$with, open head branch in the primary clone: the primary clone stays on it"

  # --- --pr and locked worktrees -------------------------------------------
  build "pr-locked-own$flag"
  git -C "$PRIMARY" worktree lock --reason "held by hand" "$WT/agent-a"
  run --pr 7 ${flag:+"$flag"}
  check "$RC" "0" "--pr$with, the PR's worktree locked: exit 0"
  check "$OUT" "remove worktree $WT/agent-b/.claude/worktrees/agent-n
remove worktree $WT/agent-b
keep worktree $WT/agent-a: locked
keep branch issue-7-feat: worktree $WT/agent-a is kept
delete branch worktree-agent-b
keep .claude/tmp: 1 locked worktree(s)" \
    "--pr$with, the PR's worktree locked: it, its branch and the PR's scratch are kept"
  check "$([ -d "$PRIMARY/.claude/tmp/issue-7" ] && echo kept)" "kept" "--pr$with, the PR's worktree locked: the PR's scratch is still there"

  build "pr-locked-other$flag"
  git -C "$PRIMARY" worktree lock --reason "claude agent agent-d (pid $DEAD_PID start Mon Jan  1 00:00:00 2001)" "$WT/agent-d"
  run --pr 7 ${flag:+"$flag"}
  check "$RC" "0" "--pr$with, another worktree locked: exit 0"
  check "$OUT" "remove worktree $WT/agent-b/.claude/worktrees/agent-n
remove worktree $WT/agent-b
remove worktree $WT/agent-a
delete branch issue-7-feat
delete branch worktree-agent-b
remove scratch $PRIMARY/.claude/tmp/issue-7" \
    "--pr$with, another worktree locked: a locked worktree outside the PR's holds nothing back"
  check "$(locks)" "$WT/agent-d " "--pr$with, another worktree locked: it is left, lock and all, stale or not"

  # --- --pr and the invoking session's own locks ------------------------------
  # This shell is an ancestor of the script, as the invoking session is.
  # agent-a, a recorded agent's, carries this shell's live lock; agent-b, a
  # recorded agent's, the live lock of a process that is not an ancestor;
  # manual, unrecorded but holding the head branch, and agent-d, unrecorded
  # and not the PR's, carry this shell's live lock.
  build "pr-own-session$flag"
  git -C "$WT/agent-a" checkout -q --detach
  git -C "$PRIMARY" worktree add -q "$WT/manual" issue-7-feat
  git -C "$PRIMARY" worktree lock --reason "claude agent agent-a (pid $$ start $LIVE_START)" "$WT/agent-a"
  git -C "$PRIMARY" worktree lock --reason "claude agent agent-b (pid $OTHER_PID start $OTHER_START)" "$WT/agent-b"
  git -C "$PRIMARY" worktree lock --reason "claude agent agent-m (pid $$ start $LIVE_START)" "$WT/manual"
  git -C "$PRIMARY" worktree lock --reason "claude agent agent-d (pid $$ start $LIVE_START)" "$WT/agent-d"
  EXPECTED="keep worktree $WT/manual: locked by running pid $$
remove worktree $WT/agent-b/.claude/worktrees/agent-n
keep worktree $WT/agent-b: locked by running pid $OTHER_PID
remove worktree $WT/agent-a
keep branch issue-7-feat: worktree $WT/manual is kept
keep branch worktree-agent-b: worktree $WT/agent-b is kept
keep .claude/tmp: 2 locked worktree(s)"
  run --pr 7 --dry-run ${flag:+"$flag"}
  check "$OUT" "$(printf '%s\n' "$EXPECTED" | sed 's/^/would-/')" \
    "--pr$with, own-session locks, dry run: every item as would-<action>"
  run --pr 7 ${flag:+"$flag"}
  check "$RC" "0" "--pr$with, own-session locks: exit 0"
  check "$OUT" "$EXPECTED" \
    "--pr$with, own-session locks: only the recorded agent's own-session lock is released, its worktree removed"
  check "$([ -e "$WT/agent-a" ] && echo left)" "" "--pr$with, own-session locks: the recorded agent's worktree is gone"
  check "$(locks)" "$WT/agent-b $WT/agent-d $WT/manual " \
    "--pr$with, own-session locks: another pid's lock and the unrecorded worktrees' locks are kept"
done

# --- usage ----------------------------------------------------------------
build usage
BEFORE=$(snapshot)
rm -f "$SERVE/git-default-branch.args"
for args in "" "--dry-run" "--review-state" "--review-state --dry-run" "--stale-locks" "--pr" "--pr 7 --all --scratchpad $PAD" "--all" "--pr 7 --scratchpad $PAD" \
  "--all --scratchpad $CASE" "--all --scratchpad $SESSIONS/s9/scratchpad" "--pr 7 --bogus"; do
  read -r -a argv <<<"$args"
  run ${argv[@]+"${argv[@]}"}
  check "$RC:$OUT" "2:" "usage: \`$args\` exits 2 with nothing on stdout"
done
run --pr ""
check "$RC:$OUT" "2:" "usage: an empty --pr exits 2 with nothing on stdout"
check_contains "$ERR" "\`--pr\` needs a non-empty value." "usage: an empty --pr says so"
run --pr 7 --scratchpad ""
check "$RC:$OUT" "2:" "usage: --pr with an empty --scratchpad exits 2 with nothing on stdout"
run --all --scratchpad "$PAD" --pr ""
check "$RC:$OUT" "2:" "usage: --all with an empty --pr exits 2 with nothing on stdout"
run --all --scratchpad ""
check "$RC:$OUT" "2:" "usage: an empty --scratchpad exits 2 with nothing on stdout"
check "$([ -f "$SERVE/git-default-branch.args" ] && echo ran)" "" "usage: nothing ran"
check "$(snapshot)" "$BEFORE" "usage: nothing removed"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
