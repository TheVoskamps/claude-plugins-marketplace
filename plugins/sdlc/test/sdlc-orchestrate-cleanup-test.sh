#!/usr/bin/env bash
#
# sdlc-orchestrate-cleanup-test.sh -- drive plugins/sdlc/bin/sdlc-orchestrate-cleanup,
# under the bash 3.2 macOS ships, against a primary clone of a local
# bare origin holding worktrees, branches, .claude/tmp/ scratch and a
# directory of session scratchpads, with stub git-default-branch, gh,
# pr-view, pr-closing-issues and sdlc-agent-result-persist executables
# first on PATH and a logging git wrapper in front of the real git: each
# scope's dry run printing what its real run acts on and removing
# nothing; --pr removing only the worktrees its state names an agent
# for -- whatever their HEAD, nested ones included -- those agents'
# worktree-agent-<id> branches, its local head branch and its issues'
# scratch, reading the agents before it deletes the review state; --all
# removing every worktree, every branch but the default branch, all
# scratch and every scratchpad but its own; removal of a dirty, unpushed
# and locked worktree; the primary clone switched to the default branch
# before any branch is deleted, in both scopes, and the fast-forward of
# the default branch there or in the worktree holding it; an action that
# fails while the rest carry on; an open PR, a PR in another repository
# and an unresolved default branch refused with nothing removed; that no
# run pushes to origin; and the usage errors.
#
# Needs git on PATH. Reaches no network.
#
# Usage: sdlc-orchestrate-cleanup-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../bin/sdlc-orchestrate-cleanup"
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
# serve/delete.fail. Each logs its arguments to serve/<name>.args. The
# git wrapper logs every call to serve/git.log.
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
cat >"$SANDBOX/bin/git" <<EOF
#!/bin/sh
echo "\$*" >>"$SERVE/git.log"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SANDBOX/bin/"*

# build <case> -- a fresh primary clone, PRIMARY, with origin's main one
# commit ahead of it, holding:
#   .claude/worktrees/agent-a    on issue-7-feat, dirty, one commit
#                                unpushed, and locked
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
# s2/scratchpad, s3/scratchpad and s2/tasks. The stubs serve a merged PR
# of this checkout's repository closing issue 7, whose state names the
# agents a, b, n and x -- x with no worktree -- review state for PRs 7
# and 8, and main as the default branch.
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
  git -C "$PRIMARY" worktree lock --reason "claude agent agent-a (pid 1)" "$WT/agent-a"
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
EXPECTED="delete review-state $PR
remove worktree $WT/agent-b/.claude/worktrees/agent-n
remove worktree $WT/agent-b
remove worktree $WT/agent-a
delete branch issue-7-feat
delete branch worktree-agent-b
remove scratch $PRIMARY/.claude/tmp/issue-7"
BEFORE=$(snapshot)
run --pr 7 --dry-run
check "$RC" "0" "--pr dry run: exit 0"
check "$OUT" "$(printf '%s\n' "$EXPECTED" | sed 's/^/would-/')" "--pr dry run: every item as would-<action>"
check "$(snapshot)" "$BEFORE" "--pr dry run: nothing removed"
check "$(git -C "$PRIMARY" rev-parse main)" "$BASE" "--pr dry run: the default branch is not pulled"
check "$(grep -cE 'fetch|pull|switch|prune|remove|unlock|branch -D' "$SERVE/git.log")" "0" \
  "--pr dry run: no git call acts"

rm -f "$SERVE/sdlc-agent-result-persist.args" "$SERVE/gh.args"
run --pr 7
check "$RC" "0" "--pr: exit 0"
check "$OUT" "$EXPECTED" "--pr: the dry run's items, acted on"
check "$(cat "$SERVE/deleted")" "$PR" "--pr: only the PR's review state is deleted"
check "$(sed -n 1p "$SERVE/pr-view.args")" "7 --ref" "--pr: the PR is resolved to its reference"
check "$(cat "$SERVE/gh.args")" "repo view --json url --jq .url" "--pr: this checkout's repository comes from gh repo view"
check "$(awk '{print $2}' "$SERVE/sdlc-agent-result-persist.args" | tr '\n' ' ')" "print-agents list delete " \
  "--pr: the PR's agents are read before its review state is deleted"
check "$(sed -n 1p "$SERVE/sdlc-agent-result-persist.args")" "--mode print-agents --pr $PR" \
  "--pr: the agents are read for the PR's reference"
check "$(sed -n 2p "$SERVE/sdlc-agent-result-persist.args")" "--mode list h.example/o/r" \
  "--pr: review state is listed for the PR's repository"
check "$([ -e "$WT/agent-a" ] || [ -e "$WT/agent-b" ] && echo left)" "" \
  "--pr: the agents' worktrees are gone, dirty, unpushed, locked and off the PR's commits included"
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

# --- --pr with the head branch checked out in the primary clone ------------
build pr-switch
git -C "$WT/agent-a" checkout -q --detach
git -C "$PRIMARY" checkout -q issue-7-feat
run --pr 7
check "$RC" "0" "--pr, head branch in the primary clone: exit 0"
check "$([ -e "$WT/agent-a" ] && echo left)" "" "--pr: a locked worktree at a detached HEAD is unlocked and removed"
check_contains "$OUT" "delete branch issue-7-feat
delete branch worktree-agent-b" "--pr, head branch in the primary clone: its deletion does not fail"
check "$(branches)" "main other-branch worktree-agent-c " "--pr, head branch in the primary clone: the head branch is deleted"
check "$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)" "main" \
  "--pr, head branch in the primary clone: the primary clone is on the default branch"
check "$(git -C "$PRIMARY" rev-parse main)" "$ORIGIN_MAIN" "--pr, head branch in the primary clone: and it is pulled"
check "$(grep -n -e '^-C [^ ]* switch main' -e '^-C [^ ]* branch -D' "$SERVE/git.log" | sed -n 1p | cut -d' ' -f3)" \
  "switch" "--pr, head branch in the primary clone: the switch runs before any branch is deleted"

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
EXPECTED="delete review-state $PR
delete review-state h.example/o/r#8
remove worktree $WT/agent-d
remove worktree $WT/agent-c
remove worktree $WT/agent-b/.claude/worktrees/agent-n
remove worktree $WT/agent-b
remove worktree $WT/agent-a
delete branch issue-7-feat
delete branch other-branch
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
check "$OUT" "$(printf '%s\n' "$EXPECTED" | sed 's/^/would-/')" "--all dry run: every item as would-<action>"
check "$(snapshot)" "$BEFORE" "--all dry run: nothing removed"
check "$(cat "$SERVE/sdlc-agent-result-persist.args")" "--mode list" "--all: review state is listed for this repository, and nothing else is read"

run --all --scratchpad "$PAD"
check "$RC" "0" "--all: exit 0"
check "$OUT" "$EXPECTED" "--all: the dry run's items, acted on"
check "$(cat "$SERVE/deleted" | tr '\n' ' ')" "$PR h.example/o/r#8 " "--all: every PR's review state is deleted"
check "$(git -C "$PRIMARY" worktree list --porcelain | grep -c '^worktree ')" "1" "--all: only the primary clone remains"
check "$([ -e "$WT" ] && ls -A "$WT")" "" "--all: no worktree directory is left"
check "$(branches)" "main " "--all: only the default branch is left"
check "$(ls -A "$PRIMARY/.claude/tmp")" "" "--all: all scratch is removed"
check "$(printf '%s ' "$SESSIONS"/*/*)" "$PAD $SESSIONS/s2/tasks " "--all: only this session's scratchpad, and no other session file, is left"
check "$(git -C "$PRIMARY" rev-parse main)" "$ORIGIN_MAIN" "--all: the default branch is fast-forwarded"
untouched_origin "--all"

# --- an action that fails, and the switch to the default branch -------------
build failing
git -C "$PRIMARY" checkout -q other-branch
echo 'h.example/o/r#8' >"$SERVE/delete.fail"
run --all --scratchpad "$PAD"
check "$RC" "1" "a failed action: exit 1"
check_contains "$OUT" "delete review-state h.example/o/r#8
failed delete review-state h.example/o/r#8: persist: stub refused h.example/o/r#8
remove worktree" "a failed action: its failure line quotes the error, and the run goes on"
check_contains "$OUT" "remove scratchpad $SESSIONS/s3/scratchpad" "a failed action: the last item is still acted on"
check "$(printf '%s\n' "$OUT" | grep -c '^failed')" "1" "a failed action: no other action fails"
check_contains "$OUT" "delete branch other-branch
delete branch worktree-agent-b" "switch: the branch the primary clone had checked out is deleted without failing"
check "$(branches)" "main " "switch: every branch but the default branch is deleted"
check "$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)" "main" "switch: the primary clone is switched to the default branch"
check "$(git -C "$PRIMARY" rev-parse main)" "$ORIGIN_MAIN" "switch: and pulled"
untouched_origin "a failed action"

# --- usage ----------------------------------------------------------------
build usage
BEFORE=$(snapshot)
rm -f "$SERVE/git-default-branch.args"
for args in "" "--dry-run" "--pr" "--pr 7 --all --scratchpad $PAD" "--all" "--pr 7 --scratchpad $PAD" \
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
