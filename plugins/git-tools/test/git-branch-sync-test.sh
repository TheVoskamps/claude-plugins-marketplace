#!/usr/bin/env bash
#
# git-branch-sync-test.sh -- drive plugins/git-tools/bin/git-branch-sync,
# under the bash 3.2 macOS ships, against a local bare origin, a seed
# checkout that plays everyone else pushing to it, and a clone the
# script runs in, all under `mktemp -d`. A logging git wrapper on PATH
# records each push's arguments, so the test asserts which push form was
# picked and that no --force or --mirror ever was.
#
# It covers each subcommand on its own path and the exits that separate
# them: a diverged checkout refused, a stopped rebase finished through
# continue and one aborted, a resolution that empties the stopped commit,
# a conflicted path git would quote, a stop reached from a subdirectory,
# and abort and continue exiting 1 rather than 6 when the rebase check's
# git-path read fails. It covers the push's refusals: a second writer who pushed
# after the checkout, with and without a rebase in between, a
# post-receive hook that moves the branch so the verification fails, and
# a pre-receive hook that refuses, which stays an unclassified failure.
#
# For the claim, a linked worktree of the clone plays the dead agent's.
# It covers a checkout refused for a branch that worktree has checked out
# and for one it is rebasing; reclaim refused for a dirty holder with and
# without --holder-ended, and under --holder-ended for a holder with
# unpushed commits and for one mid-rebase; a branch no worktree holds,
# released, and refused once it has unpushed commits; a lock naming a
# running process, compared from a zone five hours off UTC, refused and
# then overridden by --holder-ended with the lock kept; a lock whose PID
# is gone, one whose start time differs, and no lock, each proceeding;
# and dirt only under an excluded path.
#
# It covers the holders with no working tree: a directory that is gone
# and a .git file naming a missing gitdir, each refused while the branch
# has unpushed commits and released once it has none, and a worktree
# nested in the clone whose .git is missing, released while the
# enclosing clone keeps its branch. A checkout of an unheld branch walks
# past a worktree whose gitdir is missing. A dirty holder, a mid-rebase
# one, a mid-rebase one whose directory is then deleted, which is still
# refused, and one whose directory is gone with no rebase each run once
# with worktree.useRelativePaths off and once with it on.
#
# Needs git on PATH. Reaches no network.
#
# Usage: git-branch-sync-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../bin/git-branch-sync"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/git-branch-sync-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0

# check <actual> <expected> <label> -- print PASS or FAIL for <label>,
# counting a failure in FAILURES when <actual> differs from <expected>.
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

# check_contains <actual> <needle> <label> -- as check, passing when
# <actual> contains <needle>.
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

# check_lacks <actual> <needle> <label> -- as check, passing when
# <actual> does not contain <needle>.
check_lacks() {
  case "$1" in
    *"$2"*)
      echo "FAIL  $3"
      echo "      expected not to contain: $2"
      echo "      actual:                  $1"
      FAILURES=$((FAILURES + 1))
      ;;
    *) echo "PASS  $3" ;;
  esac
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$SANDBOX/home"
mkdir -p "$HOME"
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
CLONE="$SANDBOX/clone"
REAL_GIT=$(command -v git)
PUSH_LOG="$SANDBOX/push.log"
# Every push of the run, never truncated, for the final no-force check.
ALL_PUSH_LOG="$SANDBOX/all-push.log"

# commit_file <dir> <file> <content> <message> -- commit one file's new
# content in <dir>, and print the new commit's SHA.
commit_file() {
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$4"
  git -C "$1" rev-parse HEAD
}

# A git that logs every push's arguments and otherwise is git.
mkdir -p "$SANDBOX/logbin"
cat >"$SANDBOX/logbin/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = push ]; then
  printf '%s\n' "\$*" >>"$PUSH_LOG"
  printf '%s\n' "\$*" >>"$ALL_PUSH_LOG"
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$SANDBOX/logbin/git"

git init -q --bare -b main "$ORIGIN"
git init -q -b main "$SEED"
git -C "$SEED" remote add origin "$ORIGIN"
commit_file "$SEED" base.txt base "base" >/dev/null
printf 'one\n' >"$SEED/shared.txt"
printf 'one\n' >"$SEED/other.txt"
git -C "$SEED" add shared.txt other.txt
git -C "$SEED" commit -q -m "shared files"
git -C "$SEED" checkout -q -b feature
A=$(commit_file "$SEED" a.txt "a" "feature A")
git -C "$SEED" push -q origin main feature
git clone -q "$ORIGIN" "$CLONE"

# branch_sync <args...> -- run git-branch-sync from $CLONE, or from its
# subdirectory $CASE_DIR when set, through the logging git, with an
# editor that leaves a marker if anything opens it, and with $CASE_PATH,
# when set, ahead of the logging git on PATH; leaves OUT, ERR, RC.
# Not named `run`: shellcheck checks the arguments of a `run` call as a
# command of their own, so `run continue` reads as the builtin.
branch_sync() {
  OUT=$(cd "$CLONE${CASE_DIR:+/$CASE_DIR}" && PATH="${CASE_PATH:+$CASE_PATH:}$SANDBOX/logbin:$PATH" \
    GIT_EDITOR="touch $SANDBOX/editor-opened" /bin/bash "$SCRIPT" "$@" 2>"$SANDBOX/stderr")
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
}

clone_head() { git -C "$CLONE" rev-parse HEAD; }
origin_tip() { git -C "$ORIGIN" rev-parse "refs/heads/$1"; }
in_rebase() {
  if [ -d "$CLONE/.git/rebase-merge" ] || [ -d "$CLONE/.git/rebase-apply" ]; then echo yes; else echo no; fi
}
last_push() { tail -n 1 "$PUSH_LOG"; }
recorded() { git -C "$CLONE" rev-parse -q --verify "refs/git-branch-sync/$1" || echo none; }

check "$([ -x "$SCRIPT" ] && echo yes)" "yes" "git-branch-sync is executable"

# --- usage ------------------------------------------------------------------
usage_case() {
  branch_sync "$@"
  check "$RC:$OUT" "2:" "usage: \`$*\` exits 2 with nothing on stdout"
}
usage_case
usage_case bogus
usage_case checkout
usage_case checkout a b
usage_case rebase
usage_case continue
usage_case abort x
usage_case push x
usage_case push --exclude
usage_case push --exclude a x
usage_case release
usage_case reclaim
usage_case reclaim a b
usage_case reclaim --exclude
usage_case reclaim --bogus a

# --- push before any checkout -----------------------------------------------
: >"$PUSH_LOG"
branch_sync push
check "$RC" "12" "push with no recorded tip: exit 12"
check_contains "$ERR" "no tip is recorded for main" "push with no recorded tip: stderr names the branch"
check "$(cat "$PUSH_LOG")" "" "push with no recorded tip: no push was run"

# --- checkout ---------------------------------------------------------------
branch_sync checkout feature
check "$RC" "0" "checkout: a branch with no local copy exits 0"
check "$(git -C "$CLONE" branch --show-current)" "feature" "checkout: the branch is checked out"
check "$(clone_head)" "$A" "checkout: at origin's tip"
check "$(recorded feature)" "$A" "checkout: records origin's tip"

B=$(commit_file "$SEED" b.txt "b" "feature B")
git -C "$SEED" push -q origin feature
branch_sync checkout feature
check "$RC" "0" "checkout: a local branch behind origin exits 0"
check "$(clone_head)" "$B" "checkout: fast-forwarded to origin's tip"

LOCAL=$(commit_file "$CLONE" local.txt "local" "local only")
branch_sync checkout feature
check "$RC:$(clone_head)" "0:$LOCAL" "checkout: a local branch ahead of origin is kept as it is"
git -C "$CLONE" reset -q --hard "$B"

branch_sync checkout nope
check "$RC" "1" "checkout: a branch origin lacks exits 1"
check_contains "$ERR" "origin/nope does not exist after the fetch" "checkout: stderr names the missing ref"

# Diverge: the clone commits, the seed pushes something else.
DIVERGED=$(commit_file "$CLONE" mine.txt "mine" "mine")
C=$(commit_file "$SEED" c.txt "c" "feature C")
git -C "$SEED" push -q origin feature
git -C "$CLONE" checkout -q --detach
branch_sync checkout feature
check "$RC" "4" "checkout: a diverged local branch exits 4"
check "$(git -C "$CLONE" rev-parse refs/heads/feature)" "$DIVERGED" "checkout: the diverged branch is not reset"
check "$(git -C "$CLONE" branch --show-current)" "" "checkout: nothing was checked out"
git -C "$CLONE" branch -q -f feature "$C"
branch_sync checkout feature
check "$RC:$(clone_head)" "0:$C" "checkout: back in step with origin"

# --- rebase and push, clean -------------------------------------------------
git -C "$SEED" checkout -q main
U1=$(commit_file "$SEED" upstream.txt "u1" "upstream one")
git -C "$SEED" push -q origin main
: >"$PUSH_LOG"
branch_sync rebase main
check "$RC" "0" "clean rebase: exit 0"
check "$OUT" "" "clean rebase: nothing on stdout"
check "$(git -C "$CLONE" merge-base --is-ancestor "$U1" HEAD && echo on-base)" "on-base" "clean rebase: the branch sits on origin/main"
check "$(git -C "$CLONE" branch --show-current)" "feature" "clean rebase: the branch is still checked out"

branch_sync push
check "$RC" "0" "push after a rebase: exit 0"
check "$(origin_tip feature)" "$(clone_head)" "push after a rebase: origin holds the rebased head"
check_contains "$(last_push)" "--force-with-lease=refs/heads/feature:$C" \
  "push after a rebase: the lease names the recorded tip"
check "$(recorded feature)" "$(clone_head)" "push after a rebase: records the pushed tip"

: >"$PUSH_LOG"
branch_sync push
check "$RC" "0" "push with nothing new: exit 0 after verifying"
check_lacks "$(last_push)" "--force-with-lease" "push with nothing new: a plain push"

D=$(commit_file "$CLONE" d.txt "d" "feature D")
branch_sync push
check "$RC:$(origin_tip feature)" "0:$D" "push of a new commit: exit 0, origin holds it"
check_lacks "$(last_push)" "--force-with-lease" "push of a new commit: a plain push"

git -C "$CLONE" reset -q --hard HEAD~1
: >"$PUSH_LOG"
branch_sync push
check "$RC" "11" "push behind origin: exit 11"
check_contains "$ERR" "is behind its recorded tip ($D); nothing was pushed" "push behind origin: stderr names the recorded tip"
check "$(cat "$PUSH_LOG")" "" "push behind origin: no push was run"
check "$(origin_tip feature)" "$D" "push behind origin: origin keeps its tip"
git -C "$CLONE" reset -q --hard "$D"

# --- another writer pushes after the checkout -------------------------------
# writer_pushes <file> -- the seed pushes one commit onto origin/feature;
# prints its SHA.
writer_pushes() {
  git -C "$SEED" checkout -q feature
  git -C "$SEED" fetch -q origin
  git -C "$SEED" reset -q --hard origin/feature
  commit_file "$SEED" "$1" "$1" "writer $1"
  git -C "$SEED" push -q origin feature
}

branch_sync checkout feature
W1=$(writer_pushes w1.txt)
commit_file "$CLONE" mine1.txt "mine1" "mine one" >/dev/null
branch_sync push
check "$RC" "8" "another writer, no rebase: exit 8"
check "$(origin_tip feature)" "$W1" "another writer, no rebase: origin keeps the writer's commit"
git -C "$CLONE" fetch -q origin
git -C "$CLONE" reset -q --hard "$W1"
branch_sync checkout feature
check "$RC:$(recorded feature)" "0:$W1" "another writer: checkout records the writer's tip"

git -C "$SEED" checkout -q main
commit_file "$SEED" upstream2.txt "u2" "upstream two" >/dev/null
git -C "$SEED" push -q origin main
W2=$(writer_pushes w2.txt)
commit_file "$CLONE" mine2.txt "mine2" "mine two" >/dev/null
branch_sync rebase main
check "$RC" "0" "another writer, then a rebase: the rebase is clean"
: >"$PUSH_LOG"
branch_sync push
check "$RC" "8" "another writer, then a rebase: exit 8"
check_contains "$(last_push)" "--force-with-lease=refs/heads/feature:$W1" \
  "another writer, then a rebase: the lease names the tip checkout recorded"
check "$(origin_tip feature)" "$W2" "another writer, then a rebase: origin keeps the writer's commit"
git -C "$CLONE" fetch -q origin
git -C "$CLONE" reset -q --hard "$W2"
branch_sync checkout feature

# --- a stopped rebase finished through continue -----------------------------
# Feature E conflicts with main in two files and feature F in a third,
# so the rebase stops twice.
git -C "$SEED" fetch -q origin
git -C "$SEED" checkout -q feature
git -C "$SEED" reset -q --hard origin/feature
export GIT_AUTHOR_NAME=Author GIT_AUTHOR_EMAIL=author@example.com
printf 'feature shared\n' >"$SEED/shared.txt"
printf 'feature other\n' >"$SEED/other.txt"
git -C "$SEED" add shared.txt other.txt
git -C "$SEED" commit -q -m "feature E"
commit_file "$SEED" base.txt "feature base" "feature F" >/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
git -C "$SEED" push -q origin feature
git -C "$SEED" checkout -q main
printf 'main shared\n' >"$SEED/shared.txt"
printf 'main other\n' >"$SEED/other.txt"
printf 'main base\n' >"$SEED/base.txt"
git -C "$SEED" add shared.txt other.txt base.txt
git -C "$SEED" commit -q -m "main touches all three"
git -C "$SEED" push -q origin main
branch_sync checkout feature

branch_sync rebase main
check "$RC" "3" "stopped rebase: exit 3"
check "$OUT" "other.txt
shared.txt" "stopped rebase: stdout is the conflicted paths, one per line, and nothing else"
check "$(in_rebase)" "yes" "stopped rebase: the rebase is in progress"

printf 'resolved shared\n' >"$CLONE/shared.txt"
branch_sync continue shared.txt
check "$RC:$OUT" "5:" "continue with another conflicted path left unstaged: exit 5"
check_contains "$ERR" "other.txt" "continue refused: stderr names the unresolved path"
check "$(in_rebase)" "yes" "continue refused: the rebase is still in progress"

printf 'resolved other\n' >"$CLONE/other.txt"
branch_sync continue other.txt
check "$RC" "3" "continue: the next stop exits 3"
check "$OUT" "base.txt" "continue: stdout is the next stop's conflicted path"
check "$(git -C "$CLONE" log -1 --format='%an <%ae>|%s' HEAD)" "Author <author@example.com>|feature E" \
  "continue: the stopped commit keeps its author and message"

printf 'resolved base\n' >"$CLONE/base.txt"
branch_sync continue base.txt
check "$RC:$OUT" "0:" "continue: the last stop finishes the rebase, exit 0"
check "$(in_rebase)" "no" "continue: no rebase is left in progress"
check "$(git -C "$CLONE" log -1 --format='%an|%s' HEAD)" "Author|feature F" \
  "continue: the last commit keeps its author and message"
check "$(git -C "$CLONE" branch --show-current)" "feature" "continue: the branch is checked out again"
check "$([ -e "$SANDBOX/editor-opened" ] && echo opened || echo never)" "never" "continue: no editor was opened"
branch_sync push
check "$RC:$(origin_tip feature)" "0:$(clone_head)" "push after a resolved rebase: exit 0, origin holds the head"

# --- abort ------------------------------------------------------------------
git -C "$SEED" fetch -q origin
git -C "$SEED" checkout -q feature
git -C "$SEED" reset -q --hard origin/feature
commit_file "$SEED" shared.txt "feature again" "feature G" >/dev/null
git -C "$SEED" push -q origin feature
git -C "$SEED" checkout -q main
commit_file "$SEED" shared.txt "main again" "main again" >/dev/null
git -C "$SEED" push -q origin main
branch_sync checkout feature
PRE_REBASE=$(clone_head)
branch_sync rebase main
check "$RC" "3" "abort: the rebase stopped"
branch_sync abort
check "$RC" "0" "abort: exit 0"
check "$(clone_head)" "$PRE_REBASE" "abort: the branch is at its pre-rebase tip"
check "$(git -C "$CLONE" branch --show-current)" "feature" "abort: the branch is checked out again"
check "$(in_rebase)" "no" "abort: no rebase is left in progress"

branch_sync abort
check "$RC" "6" "abort with no rebase in progress: exit 6"
branch_sync continue shared.txt
check "$RC" "6" "continue with no rebase in progress: exit 6"

# A git whose `rev-parse --git-path` fails: the rebase check cannot tell,
# so abort and continue exit 1 rather than report no rebase as 6.
mkdir -p "$SANDBOX/gitpathbin"
cat >"$SANDBOX/gitpathbin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *' rev-parse --git-path '*) echo "stub git: git-path refused" >&2; exit 9 ;;
esac
exec "$SANDBOX/logbin/git" "\$@"
STUB
chmod +x "$SANDBOX/gitpathbin/git"
CASE_PATH="$SANDBOX/gitpathbin" branch_sync abort
check "$RC" "1" "abort, git-path fails: exit 1, not 6"
check_contains "$ERR" "rev-parse --git-path" "abort, git-path fails: stderr names the command"
CASE_PATH="$SANDBOX/gitpathbin" branch_sync continue shared.txt
check "$RC" "1" "continue, git-path fails: exit 1, not 6"
check_contains "$ERR" "rev-parse --git-path" "continue, git-path fails: stderr names the command"

# --- a resolution that empties the stopped commit ---------------------------
# Branch `skipper` changes other.txt, main changes it differently; taking
# main's side leaves the stopped commit with no change, so it is skipped.
git -C "$SEED" checkout -q main
git -C "$SEED" checkout -q -b skipper
commit_file "$SEED" other.txt "skipper other" "skipper K" >/dev/null
git -C "$SEED" push -q origin skipper
git -C "$SEED" checkout -q main
MAIN_TIP=$(commit_file "$SEED" other.txt "main skip" "main skip")
git -C "$SEED" push -q origin main
branch_sync checkout skipper
branch_sync rebase main
check "$RC:$OUT" "3:other.txt" "skip: the rebase stopped on other.txt"
printf 'main skip\n' >"$CLONE/other.txt"
branch_sync continue other.txt
check "$RC:$OUT" "0:" "skip: continue with an emptying resolution exits 0"
check "$(in_rebase)" "no" "skip: no rebase is left in progress"
check "$(clone_head)" "$MAIN_TIP" "skip: the emptied commit is dropped, the branch is at origin/main"
check "$(git -C "$CLONE" branch --show-current)" "skipper" "skip: the branch is checked out again"
check "$([ -e "$SANDBOX/editor-opened" ] && echo opened || echo never)" "never" "skip: no editor was opened"

# --- a conflicted path git would quote --------------------------------------
# A tab, a quote, a non-ASCII letter and a backslash: git quotes each
# unless asked for raw paths.
ODD=$(printf 'odd\t"\303\251\\.txt')
git -C "$SEED" checkout -q main
printf 'odd base\n' >"$SEED/$ODD"
git -C "$SEED" add -A
git -C "$SEED" commit -q -m "odd base"
git -C "$SEED" push -q origin main
git -C "$SEED" checkout -q -b odd
printf 'odd branch\n' >"$SEED/$ODD"
git -C "$SEED" commit -q -a -m "odd branch"
git -C "$SEED" push -q origin odd
git -C "$SEED" checkout -q main
printf 'odd main\n' >"$SEED/$ODD"
git -C "$SEED" commit -q -a -m "odd main"
git -C "$SEED" push -q origin main
branch_sync checkout odd
branch_sync rebase main
check "$RC:$OUT" "3:$ODD" "odd path: stdout is the conflicted path, unquoted"
printf 'odd resolved\n' >"$CLONE/$ODD"
branch_sync continue "$OUT"
check "$RC:$OUT" "0:" "odd path: continue takes the path rebase printed"
check "$(git -C "$CLONE" show HEAD:"$ODD")" "odd resolved" "odd path: the resolution is committed"

# --- a stopped rebase run from a subdirectory -------------------------------
# rebase and continue both run in sub/; the path rebase prints is
# relative to the top level.
git -C "$SEED" checkout -q main
mkdir -p "$SEED/sub"
commit_file "$SEED" sub/f.txt "sub base" "sub base" >/dev/null
git -C "$SEED" push -q origin main
git -C "$SEED" checkout -q -b subdir
commit_file "$SEED" sub/f.txt "sub branch" "sub branch" >/dev/null
git -C "$SEED" push -q origin subdir
git -C "$SEED" checkout -q main
commit_file "$SEED" sub/f.txt "sub main" "sub main" >/dev/null
git -C "$SEED" push -q origin main
branch_sync checkout subdir
CASE_DIR=sub branch_sync rebase main
check "$RC:$OUT" "3:sub/f.txt" "subdirectory: rebase prints the path relative to the top level"
printf 'sub resolved\n' >"$CLONE/sub/f.txt"
CASE_DIR=sub branch_sync continue "$OUT"
check "$RC:$OUT" "0:" "subdirectory: continue takes the path rebase printed"
check "$(in_rebase)" "no" "subdirectory: no rebase is left in progress"
check "$(git -C "$CLONE" show HEAD:sub/f.txt)" "sub resolved" "subdirectory: the resolution is committed"

# --- a stopped rebase from a subdirectory under diff.relative=true ----------
# One conflict inside sub/, one outside it: both are printed, relative to
# the top level, whatever the user's diff.relative says.
git -C "$SEED" checkout -q main
commit_file "$SEED" sub/g.txt "rel base" "rel base" >/dev/null
commit_file "$SEED" top.txt "rel base" "rel top base" >/dev/null
git -C "$SEED" push -q origin main
git -C "$SEED" checkout -q -b relative
printf 'rel branch\n' >"$SEED/sub/g.txt"
printf 'rel branch\n' >"$SEED/top.txt"
git -C "$SEED" commit -q -a -m "rel branch"
git -C "$SEED" push -q origin relative
git -C "$SEED" checkout -q main
printf 'rel main\n' >"$SEED/sub/g.txt"
printf 'rel main\n' >"$SEED/top.txt"
git -C "$SEED" commit -q -a -m "rel main"
git -C "$SEED" push -q origin main
branch_sync checkout relative
git -C "$CLONE" config diff.relative true
CASE_DIR=sub branch_sync rebase main
check "$RC:$OUT" "3:sub/g.txt
top.txt" "diff.relative: rebase prints every conflicted path relative to the top level"
printf 'rel resolved\n' >"$CLONE/sub/g.txt"
printf 'rel resolved\n' >"$CLONE/top.txt"
CASE_DIR=sub branch_sync continue sub/g.txt
check "$RC" "5" "diff.relative: continue still sees the conflict outside the subdirectory"
check_contains "$ERR" "top.txt" "diff.relative: continue names the path outside the subdirectory"
CASE_DIR=sub branch_sync continue top.txt
check "$RC:$OUT" "0:" "diff.relative: continue takes the paths rebase printed"
git -C "$CLONE" config --unset diff.relative

branch_sync checkout feature
check "$RC" "0" "back on feature"

# --- detached HEAD ----------------------------------------------------------
git -C "$CLONE" checkout -q --detach
branch_sync rebase main
check "$RC" "7" "rebase on a detached HEAD: exit 7"
branch_sync push
check "$RC" "7" "push on a detached HEAD: exit 7"
git -C "$CLONE" checkout -q feature

# --- push failures ----------------------------------------------------------
# The remote moves just before the script's push: a git whose push lets
# the seed push first, then logs and runs the script's own.
mkdir -p "$SANDBOX/racebin"
cat >"$SANDBOX/racebin/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = push ]; then
  "$REAL_GIT" -C "$SEED" checkout -q feature
  "$REAL_GIT" -C "$SEED" fetch -q origin
  "$REAL_GIT" -C "$SEED" reset -q --hard origin/feature
  printf 'race %s\n' "\$\$" >"$SEED/race.txt"
  "$REAL_GIT" -C "$SEED" add race.txt
  "$REAL_GIT" -C "$SEED" commit -q -m race
  "$REAL_GIT" -C "$SEED" push -q origin feature
fi
exec "$SANDBOX/logbin/git" "\$@"
STUB
chmod +x "$SANDBOX/racebin/git"

commit_file "$CLONE" plain.txt "plain" "plain push" >/dev/null
CASE_PATH="$SANDBOX/racebin" branch_sync push
check "$RC" "8" "plain push, remote moved just before it: exit 8"

git -C "$CLONE" fetch -q origin
git -C "$CLONE" reset -q --hard origin/feature
branch_sync checkout feature
git -C "$CLONE" commit -q --amend -m "rewritten"
: >"$PUSH_LOG"
CASE_PATH="$SANDBOX/racebin" branch_sync push
check "$RC" "8" "lease push, remote moved just before it: exit 8"
check_contains "$(last_push)" "--force-with-lease" "lease push, remote moved just before it: a lease push"

git -C "$CLONE" fetch -q origin
git -C "$CLONE" reset -q --hard origin/feature
branch_sync checkout feature

printf 'dirty\n' >>"$CLONE/base.txt"
branch_sync push
check "$RC" "10" "push verification, a dirty tree: exit 10"
git -C "$CLONE" checkout -q -- base.txt

# Dirty only under excluded paths: a tracked file modified under mem/,
# an untracked one beside it, and one under outer/mem/ inside the
# untracked outer/.
mkdir -p "$CLONE/mem"
commit_file "$CLONE" mem/tracked.md "kept" "tracked memory" >/dev/null
branch_sync push
check "$RC" "0" "push --exclude setup: the tracked memory file is pushed"
printf 'changed\n' >>"$CLONE/mem/tracked.md"
printf 'new\n' >"$CLONE/mem/new.md"
mkdir -p "$CLONE/outer/mem"
printf 'new\n' >"$CLONE/outer/mem/x.md"
branch_sync push
check "$RC" "10" "push without --exclude, dirty under mem/ and outer/mem/: exit 10"
branch_sync push --exclude mem/ --exclude outer/mem/
check "$RC" "0" "push --exclude, dirty only under the excluded paths: exit 0"
CASE_DIR=outer branch_sync push --exclude mem/ --exclude outer/mem/
check "$RC" "0" "push --exclude from a subdirectory: pathspecs are relative to the top level"
branch_sync push --exclude mem/
check "$RC" "10" "push --exclude, dirty outside one exclude: exit 10"
printf 'dirty\n' >>"$CLONE/base.txt"
branch_sync push --exclude mem/ --exclude outer/mem/
check "$RC" "10" "push --exclude, a dirty path no exclude matches: exit 10"
git -C "$CLONE" checkout -q -- base.txt mem/tracked.md
rm -rf "$CLONE/mem/new.md" "$CLONE/outer"

# The remote accepts the push, then moves the branch somewhere else.
OTHER=$(git -C "$CLONE" rev-parse HEAD~1)
cat >"$ORIGIN/hooks/post-receive" <<HOOK
#!/usr/bin/env bash
git update-ref refs/heads/feature $OTHER
HOOK
chmod +x "$ORIGIN/hooks/post-receive"
commit_file "$CLONE" moved.txt "moved" "moved after push" >/dev/null
branch_sync push
check "$RC" "9" "push verification, HEAD differs from the remote tip: exit 9"
check_contains "$ERR" "differs from origin/feature $OTHER" "push verification: stderr names both SHAs"
rm -f "$ORIGIN/hooks/post-receive"

# A remote that refuses the push for its own reason is not a moved remote.
cat >"$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
echo "refused by policy" >&2
exit 1
HOOK
chmod +x "$ORIGIN/hooks/pre-receive"
branch_sync push
check "$RC" "1" "push refused by a remote hook: exit 1, unclassified"
rm -f "$ORIGIN/hooks/pre-receive"

# A git whose status fails after the push: the script exits 1, never
# git's own.
mkdir -p "$SANDBOX/failbin"
cat >"$SANDBOX/failbin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *' status '*) echo "stub git: status refused" >&2; exit 9 ;;
esac
exec "$SANDBOX/logbin/git" "\$@"
STUB
chmod +x "$SANDBOX/failbin/git"
git -C "$CLONE" fetch -q origin
CASE_PATH="$SANDBOX/failbin" branch_sync push
check "$RC" "1" "unhandled failure: exit 1, not git's 9"
check_contains "$ERR" "failed (exit 9)" "unhandled failure: stderr names its status"

OUT=$(cd "$SANDBOX" && /bin/bash "$SCRIPT" push 2>"$SANDBOX/stderr")
RC=$?
check "$RC" "1" "outside a repository: exit 1"

# --- release ----------------------------------------------------------------
branch_sync release feature
check "$RC" "0" "release: exit 0"
check "$(git -C "$CLONE" branch --show-current)" "" "release: HEAD is detached"
check "$(git -C "$CLONE" rev-parse -q --verify refs/heads/feature || echo gone)" "gone" "release: the local branch is deleted"
check "$(recorded feature)" "none" "release: the recorded tip is deleted"

git -C "$CLONE" checkout -q -b unrecorded
branch_sync release unrecorded
check "$RC" "0" "release with no recorded tip: exit 0"

# --- a branch another worktree holds ----------------------------------------
# A linked worktree of the clone plays the dead agent's, holding `claimed`.
git -C "$SEED" checkout -q main
git -C "$SEED" checkout -q -b claimed
commit_file "$SEED" claimed1.txt "c1" "claimed one" >/dev/null
CLAIMED=$(commit_file "$SEED" claimed2.txt "c2" "claimed two")
git -C "$SEED" push -q origin claimed
git -C "$CLONE" checkout -q --detach
git -C "$CLONE" fetch -q origin
HOLDER="$SANDBOX/holder"
git -C "$CLONE" worktree add -q "$HOLDER" -b claimed refs/remotes/origin/claimed
git -C "$CLONE" update-ref refs/git-branch-sync/claimed "$CLAIMED"

# A process that stays running, its start time as the harness writes it
# — in UTC — with runs of spaces collapsed, and one that has ended. The
# running one is started from a subshell, so it is no job of this
# shell's and killing it prints no job notice.
LIVE=$(
  sleep 600 >/dev/null 2>&1 &
  echo "$!"
)
trap 'kill "$LIVE" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
LIVE_START=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$LIVE" | tr -s ' ')
sleep 0 &
GONE=$!
wait "$GONE"

# claim -- put the holder back on `claimed` at origin's tip, clean, with
# the tip recorded and no lock.
claim() {
  git -C "$HOLDER" rebase --abort 2>/dev/null
  git -C "$HOLDER" checkout -q -B claimed refs/remotes/origin/claimed
  git -C "$HOLDER" clean -q -f -d
  git -C "$CLONE" update-ref refs/git-branch-sync/claimed "$CLAIMED"
  git -C "$CLONE" worktree unlock "$HOLDER" 2>/dev/null
}
lock_holder() { git -C "$CLONE" worktree lock --reason "$1" "$HOLDER"; }
holder_branch() { git -C "$HOLDER" branch --show-current; }
local_claimed() { git -C "$CLONE" rev-parse -q --verify refs/heads/claimed || echo gone; }
canonical() { (cd "$1" && pwd -P); }

# unchanged <label> -- check that a refused reclaim left the claim whole.
unchanged() {
  check "$(holder_branch)" "claimed" "$1: the holder keeps the branch"
  check "$(local_claimed)" "$CLAIMED" "$1: the local branch is kept"
  check "$(recorded claimed)" "$CLAIMED" "$1: the recorded tip is kept"
}

branch_sync checkout claimed
check "$RC" "13" "checkout of a held branch: exit 13"
check_contains "$ERR" "claimed is held by the worktree at" "checkout of a held branch: stderr names the holder"
check_contains "$ERR" "/holder" "checkout of a held branch: stderr carries the holder's path"
check "$(git -C "$CLONE" branch --show-current)" "" "checkout of a held branch: nothing was checked out"
check "$(recorded claimed)" "$CLAIMED" "checkout of a held branch: nothing was recorded"

claim
printf 'dirty\n' >>"$HOLDER/claimed1.txt"
branch_sync reclaim claimed
check "$RC:$OUT" "14:" "reclaim, holder dirty: exit 14"
check_contains "$ERR" "uncommitted changes" "reclaim, holder dirty: stderr names what it found"
check_contains "$ERR" "/holder" "reclaim, holder dirty: stderr names the holder's path"
unchanged "reclaim, holder dirty"
branch_sync reclaim --holder-ended claimed
check "$RC" "14" "reclaim --holder-ended, holder dirty: exit 14"
unchanged "reclaim --holder-ended, holder dirty"
git -C "$HOLDER" checkout -q -- claimed1.txt

claim
commit_file "$HOLDER" unpushed.txt "u" "unpushed" >/dev/null
UNPUSHED=$(git -C "$HOLDER" rev-parse HEAD)
branch_sync reclaim --holder-ended claimed
check "$RC" "14" "reclaim, unpushed commits: exit 14"
check_contains "$ERR" "commits origin/claimed lacks" "reclaim, unpushed commits: stderr names what it found"
check "$(holder_branch):$(local_claimed)" "claimed:$UNPUSHED" "reclaim, unpushed commits: nothing was changed"

claim
git -C "$HOLDER" rebase -q -x false HEAD~1 >/dev/null 2>&1
check "$(holder_branch)" "" "mid-rebase setup: the holder is detached"
branch_sync checkout claimed
check "$RC" "13" "checkout of a branch a worktree is rebasing: exit 13"
branch_sync reclaim --holder-ended claimed
check "$RC" "14" "reclaim, holder mid-rebase: exit 14"
check_contains "$ERR" "a rebase in progress" "reclaim, holder mid-rebase: stderr names what it found"
check "$(local_claimed):$(recorded claimed)" "$CLAIMED:$CLAIMED" "reclaim, holder mid-rebase: nothing was changed"
check "$([ -d "$(git -C "$HOLDER" rev-parse --absolute-git-dir)/rebase-merge" ] && echo yes)" "yes" \
  "reclaim, holder mid-rebase: the rebase is still in progress"

claim
lock_holder "claude agent agent-live (pid $LIVE start $LIVE_START)"
# Run in a zone five hours off UTC, so a local-time comparison would miss.
TZ=Etc/GMT+5 branch_sync reclaim claimed
check "$RC:$OUT" "15:" "reclaim, holder's lock names a running process: exit 15"
check_contains "$ERR" "running process $LIVE" "reclaim, live lock: stderr names the PID"
check_contains "$ERR" "/holder" "reclaim, live lock: stderr names the holder's path"
unchanged "reclaim, live lock"
branch_sync reclaim --holder-ended claimed
check "$RC" "0" "reclaim --holder-ended, live lock: exit 0"
check "$(canonical "$OUT")" "$(canonical "$HOLDER")" "reclaim --holder-ended, live lock: stdout is the holder's path"
check_contains "$(git -C "$CLONE" worktree list --porcelain)" "locked claude agent agent-live" \
  "reclaim --holder-ended, live lock: the lock is kept"

claim
lock_holder "claude agent agent-gone (pid $GONE start $LIVE_START)"
branch_sync reclaim claimed
check "$RC" "0" "reclaim, lock names a PID that is gone: exit 0"

claim
lock_holder "claude agent agent-other (pid $LIVE start Thu Jan  1 00:00:00 1970)"
branch_sync reclaim claimed
check "$RC" "0" "reclaim, lock's start time differs: exit 0"

claim
mkdir -p "$HOLDER/.claude/agent-memory"
printf 'entry\n' >"$HOLDER/.claude/agent-memory/x.md"
branch_sync reclaim claimed
check "$RC" "14" "reclaim, holder dirty only under agent memory, no --exclude: exit 14"
branch_sync reclaim --exclude .claude/agent-memory/ claimed
check "$RC" "0" "reclaim, no lock, dirty only under the excluded path: exit 0"
check "$(canonical "$OUT")" "$(canonical "$HOLDER")" "reclaim: stdout is the holder's path"
check "$(holder_branch)" "" "reclaim: the holder's HEAD is detached"
check "$(local_claimed)" "gone" "reclaim: the local branch is deleted"
check "$(recorded claimed)" "none" "reclaim: the recorded tip is deleted"
check "$([ -d "$HOLDER" ] && echo kept)" "kept" "reclaim: the holder's worktree is kept"
branch_sync checkout claimed
check "$RC:$(git -C "$CLONE" branch --show-current)" "0:claimed" "after reclaim: checkout in another worktree succeeds"

# No worktree holds the branch: a local copy and a record are let go.
git -C "$CLONE" checkout -q --detach
git -C "$CLONE" update-ref refs/git-branch-sync/claimed "$CLAIMED"
branch_sync reclaim claimed
check "$RC:$OUT" "0:" "reclaim, no holder: exit 0, nothing on stdout"
check "$(local_claimed):$(recorded claimed)" "gone:none" "reclaim, no holder: the local branch and record are deleted"

git -C "$CLONE" branch -q claimed "$UNPUSHED"
branch_sync reclaim claimed
check "$RC" "14" "reclaim, no holder, unpushed commits: exit 14"
check_contains "$ERR" "held by no worktree" "reclaim, no holder, unpushed commits: stderr says no worktree holds it"
check "$(local_claimed)" "$UNPUSHED" "reclaim, no holder, unpushed commits: the local branch is kept"

# --- a holder whose directory is gone ---------------------------------------
# The agent's worktree directory was deleted while git still lists it,
# locked, as holding `claimed`: first with a commit origin lacks, then
# with that commit dropped.
git -C "$CLONE" branch -q -D claimed
GONE_HOLDER="$SANDBOX/gone-holder"
git -C "$CLONE" worktree add -q "$GONE_HOLDER" -b claimed refs/remotes/origin/claimed
git -C "$CLONE" worktree lock --reason "claude agent agent-gone (pid $GONE start $LIVE_START)" "$GONE_HOLDER"
git -C "$CLONE" update-ref refs/git-branch-sync/claimed "$CLAIMED"
commit_file "$GONE_HOLDER" lost.txt "lost" "lost" >/dev/null
LOST=$(git -C "$GONE_HOLDER" rev-parse HEAD)
rm -rf "$GONE_HOLDER"
branch_sync checkout claimed
check "$RC" "13" "checkout, holder's directory gone: exit 13"
branch_sync reclaim claimed
check "$RC:$OUT" "14:" "reclaim, holder's directory gone, unpushed commits: exit 14"
check_contains "$ERR" "commits origin/claimed lacks" "reclaim, holder's directory gone: stderr names the commits"
check "$(local_claimed):$(recorded claimed)" "$LOST:$CLAIMED" "reclaim, holder's directory gone, unpushed commits: nothing was changed"
git -C "$CLONE" update-ref refs/heads/claimed "$CLAIMED"
branch_sync reclaim claimed
check "$RC" "0" "reclaim, holder's directory gone: exit 0"
check_contains "$OUT" "/gone-holder" "reclaim, holder's directory gone: stdout is the holder's path"
check "$(local_claimed):$(recorded claimed)" "gone:none" "reclaim, holder's directory gone: the local branch and record are deleted"
check_contains "$(git -C "$CLONE" worktree list --porcelain)" "locked claude agent agent-gone" \
  "reclaim, holder's directory gone: the worktree and its lock are kept"
branch_sync checkout claimed
check "$RC:$(git -C "$CLONE" branch --show-current)" "0:claimed" \
  "after reclaim of a holder whose directory is gone: checkout succeeds"

# --- a worktree whose .git file names a missing gitdir ----------------------
# It holds `broken`; checking out a branch nobody holds walks past it.
git -C "$CLONE" checkout -q --detach
BROKEN="$SANDBOX/broken"
git -C "$CLONE" worktree add -q "$BROKEN" -b broken refs/remotes/origin/main
printf 'gitdir: %s\n' "$SANDBOX/nowhere" >"$BROKEN/.git"
branch_sync checkout feature
check "$RC:$(git -C "$CLONE" branch --show-current)" "0:feature" \
  "checkout past a worktree whose gitdir is missing: exit 0"

# A holder of `claimed` whose .git file names a missing gitdir: first
# with a commit origin lacks, then with that commit dropped.
git -C "$CLONE" checkout -q --detach
git -C "$CLONE" branch -q -D claimed
BROKEN_HOLDER="$SANDBOX/broken-holder"
git -C "$CLONE" worktree add -q "$BROKEN_HOLDER" -b claimed refs/remotes/origin/claimed
git -C "$CLONE" update-ref refs/git-branch-sync/claimed "$CLAIMED"
commit_file "$BROKEN_HOLDER" stranded.txt "stranded" "stranded" >/dev/null
STRANDED=$(git -C "$BROKEN_HOLDER" rev-parse HEAD)
printf 'gitdir: %s\n' "$SANDBOX/nowhere" >"$BROKEN_HOLDER/.git"
branch_sync reclaim claimed
check "$RC:$OUT" "14:" "reclaim, holder's gitdir missing, unpushed commits: exit 14"
check_contains "$ERR" "commits origin/claimed lacks" "reclaim, holder's gitdir missing: stderr names the commits"
check "$(local_claimed):$(recorded claimed)" "$STRANDED:$CLAIMED" \
  "reclaim, holder's gitdir missing, unpushed commits: nothing was changed"
git -C "$CLONE" update-ref refs/heads/claimed "$CLAIMED"
branch_sync reclaim claimed
check "$RC" "0" "reclaim, holder's gitdir missing: exit 0"
check_contains "$OUT" "/broken-holder" "reclaim, holder's gitdir missing: stdout is the holder's path"
check "$(local_claimed):$(recorded claimed)" "gone:none" \
  "reclaim, holder's gitdir missing: the local branch and record are deleted"
check "$([ -d "$BROKEN_HOLDER" ] && echo kept)" "kept" "reclaim, holder's gitdir missing: the holder's directory is kept"
branch_sync checkout claimed
check "$RC:$(git -C "$CLONE" branch --show-current)" "0:claimed" \
  "after reclaim of a holder whose gitdir is missing: checkout succeeds"

# --- a holder inside the clone whose .git is missing ------------------------
# As an agent's worktree sits under .claude/worktrees/ in the primary
# clone, ignored there: with its .git file gone, git run in it resolves
# to the clone, which reclaim must neither probe nor detach.
git -C "$CLONE" checkout -q feature
git -C "$CLONE" branch -q -D claimed
printf '.claude/\n' >>"$CLONE/.git/info/exclude"
NESTED="$CLONE/.claude/worktrees/nested-holder"
git -C "$CLONE" worktree add -q "$NESTED" -b claimed refs/remotes/origin/claimed
git -C "$CLONE" update-ref refs/git-branch-sync/claimed "$CLAIMED"
NESTED_ADMIN=$(git -C "$NESTED" rev-parse --absolute-git-dir)
rm "$NESTED/.git"
branch_sync checkout claimed
check "$RC:$(git -C "$CLONE" branch --show-current)" "13:feature" "checkout, holder's .git missing: exit 13"
branch_sync reclaim claimed
check "$RC" "0" "reclaim, holder's .git missing: exit 0"
check "$(canonical "$OUT")" "$(canonical "$NESTED")" "reclaim, holder's .git missing: stdout is the holder's path"
check "$(git -C "$CLONE" branch --show-current)" "feature" \
  "reclaim, holder's .git missing: the enclosing clone keeps its branch"
check "$(git --git-dir="$NESTED_ADMIN" symbolic-ref -q HEAD || echo detached)" "detached" \
  "reclaim, holder's .git missing: the holder's HEAD is detached"
check "$(local_claimed):$(recorded claimed)" "gone:none" \
  "reclaim, holder's .git missing: the local branch and record are deleted"

# --- holders under each worktree.useRelativePaths setting -------------------
# holder_shapes <true|false> -- with worktree.useRelativePaths set to the
# argument, which decides whether git writes a holder's gitdir file
# relative: an intact holder that is dirty and then mid-rebase, the same
# holder after its directory is deleted, and a holder whose directory is
# gone with no rebase.
holder_shapes() {
  local rel=$1 wt admin lost form want
  git -C "$CLONE" config worktree.useRelativePaths "$rel"
  wt="$SANDBOX/shape-$rel"
  git -C "$CLONE" worktree add -q "$wt" -b claimed refs/remotes/origin/claimed
  git -C "$CLONE" update-ref refs/git-branch-sync/claimed "$CLAIMED"
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  case "$(cat "$admin/gitdir")" in
    /*) form=absolute ;;
    *) form=relative ;;
  esac
  want=absolute
  [ "$rel" = false ] || want=relative
  check "$form" "$want" "relative paths $rel: git writes the gitdir file $want"

  printf 'dirty\n' >>"$wt/claimed1.txt"
  branch_sync reclaim claimed
  check "$RC:$OUT" "14:" "relative paths $rel, holder dirty: exit 14"
  check_contains "$ERR" "uncommitted changes" "relative paths $rel, holder dirty: stderr names what it found"
  check_contains "$ERR" "/shape-$rel" "relative paths $rel, holder dirty: stderr names the holder's path"
  git -C "$wt" checkout -q -- claimed1.txt

  git -C "$wt" rebase -q -x false HEAD~1 >/dev/null 2>&1
  branch_sync reclaim --holder-ended claimed
  check "$RC" "14" "relative paths $rel, holder mid-rebase: exit 14"
  check_contains "$ERR" "a rebase in progress" "relative paths $rel, holder mid-rebase: stderr names what it found"

  rm -rf "$wt"
  branch_sync checkout claimed
  check "$RC" "13" "relative paths $rel, mid-rebase holder's directory gone: checkout exits 13"
  check_contains "$ERR" "/shape-$rel" "relative paths $rel, mid-rebase holder's directory gone: checkout names the holder"
  branch_sync reclaim --holder-ended claimed
  check "$RC:$OUT" "14:" "relative paths $rel, mid-rebase holder's directory gone: reclaim exits 14"
  check_contains "$ERR" "a rebase in progress" \
    "relative paths $rel, mid-rebase holder's directory gone: stderr names the rebase"
  check_contains "$ERR" "/shape-$rel" "relative paths $rel, mid-rebase holder's directory gone: stderr names the holder"
  check "$(local_claimed):$(recorded claimed)" "$CLAIMED:$CLAIMED" \
    "relative paths $rel, mid-rebase holder's directory gone: nothing was changed"
  rm -rf "$admin/rebase-merge"
  branch_sync reclaim claimed
  check "$RC" "0" "relative paths $rel, holder's directory gone after its rebase: exit 0"
  check "$(local_claimed):$(recorded claimed)" "gone:none" \
    "relative paths $rel, holder's directory gone after its rebase: the local branch and record are deleted"

  wt="$SANDBOX/gone-shape-$rel"
  git -C "$CLONE" worktree add -q "$wt" -b claimed refs/remotes/origin/claimed
  git -C "$CLONE" update-ref refs/git-branch-sync/claimed "$CLAIMED"
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  commit_file "$wt" lost.txt "lost" "lost" >/dev/null
  lost=$(git -C "$wt" rev-parse HEAD)
  rm -rf "$wt"
  branch_sync reclaim claimed
  check "$RC:$OUT" "14:" "relative paths $rel, holder's directory gone, unpushed commits: exit 14"
  check_contains "$ERR" "commits origin/claimed lacks" "relative paths $rel, holder's directory gone: stderr names the commits"
  check "$(local_claimed):$(recorded claimed)" "$lost:$CLAIMED" \
    "relative paths $rel, holder's directory gone, unpushed commits: nothing was changed"
  git -C "$CLONE" update-ref refs/heads/claimed "$CLAIMED"
  branch_sync reclaim claimed
  check "$RC" "0" "relative paths $rel, holder's directory gone: exit 0"
  check_contains "$OUT" "/gone-shape-$rel" "relative paths $rel, holder's directory gone: stdout is the holder's path"
  check "$(git --git-dir="$admin" symbolic-ref -q HEAD || echo detached)" "detached" \
    "relative paths $rel, holder's directory gone: the holder's HEAD is detached"
  check "$(local_claimed):$(recorded claimed)" "gone:none" \
    "relative paths $rel, holder's directory gone: the local branch and record are deleted"
}
holder_shapes false
holder_shapes true

echo
# --- no forced push, over every push the run made ---------------------------
# A word that is --force, --mirror, a short-option cluster carrying f, or
# a refspec with a leading +, each of which forces or mirrors;
# --force-with-lease is none of them.
check "$([ -s "$ALL_PUSH_LOG" ] && echo yes)" "yes" "the push log recorded the run's pushes"
FORCED=$(tr ' ' '\n' <"$ALL_PUSH_LOG" | grep -Ex -- '--force(=.*)?|--mirror|-[^-]*f.*|\+.*' || true)
check "$FORCED" "" "no push the run made used --force, -f, --mirror or a + refspec"

if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
