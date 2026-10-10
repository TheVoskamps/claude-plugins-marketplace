#!/usr/bin/env bash
#
# git-branch-sync-test.sh -- drive plugins/git-tools/bin/git-branch-sync,
# under the bash 3.2 macOS ships, against a local bare origin, a seed
# checkout that plays everyone else pushing to it, and a clone the
# script runs in.
#
# Needs git on PATH. Reaches no network.
#
# Usage: git-branch-sync-test.sh    (exit 0 when every case passes)

# `run continue ...` passes `continue` as the subcommand, not the builtin.
# shellcheck disable=SC2105

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../bin/git-branch-sync"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/git-branch-sync-test.XXXXXX")"
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
if [ "\$1" = push ]; then printf '%s\n' "\$*" >>"$PUSH_LOG"; fi
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

# run <args...> -- run git-branch-sync from $CLONE through the logging
# git, with an editor that leaves a marker if anything opens it; leaves
# OUT, ERR, RC.
run() {
  OUT=$(cd "$CLONE" && PATH="${CASE_PATH:+$CASE_PATH:}$SANDBOX/logbin:$PATH" \
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

check "$([ -x "$SCRIPT" ] && echo yes)" "yes" "git-branch-sync is executable"

# --- usage ------------------------------------------------------------------
for args in "" "bogus" "checkout" "checkout a b" "rebase" "continue" "abort x" "push x" "release"; do
  # shellcheck disable=SC2086
  run $args
  check "$RC:$OUT" "2:" "usage: \`$args\` exits 2 with nothing on stdout"
done

# --- checkout ---------------------------------------------------------------
run checkout feature
check "$RC" "0" "checkout: a branch with no local copy exits 0"
check "$(git -C "$CLONE" branch --show-current)" "feature" "checkout: the branch is checked out"
check "$(clone_head)" "$A" "checkout: at origin's tip"

B=$(commit_file "$SEED" b.txt "b" "feature B")
git -C "$SEED" push -q origin feature
run checkout feature
check "$RC" "0" "checkout: a local branch behind origin exits 0"
check "$(clone_head)" "$B" "checkout: fast-forwarded to origin's tip"

LOCAL=$(commit_file "$CLONE" local.txt "local" "local only")
run checkout feature
check "$RC:$(clone_head)" "0:$LOCAL" "checkout: a local branch ahead of origin is kept as it is"
git -C "$CLONE" reset -q --hard "$B"

run checkout nope
check "$RC" "1" "checkout: a branch origin lacks exits 1"
check_contains "$ERR" "origin/nope does not exist after the fetch" "checkout: stderr names the missing ref"

# Diverge: the clone commits, the seed pushes something else.
DIVERGED=$(commit_file "$CLONE" mine.txt "mine" "mine")
C=$(commit_file "$SEED" c.txt "c" "feature C")
git -C "$SEED" push -q origin feature
git -C "$CLONE" checkout -q --detach
run checkout feature
check "$RC" "4" "checkout: a diverged local branch exits 4"
check "$(git -C "$CLONE" rev-parse refs/heads/feature)" "$DIVERGED" "checkout: the diverged branch is not reset"
check "$(git -C "$CLONE" branch --show-current)" "" "checkout: nothing was checked out"
git -C "$CLONE" branch -q -f feature "$C"
run checkout feature
check "$RC:$(clone_head)" "0:$C" "checkout: back in step with origin"

# --- rebase and push, clean -------------------------------------------------
git -C "$SEED" checkout -q main
U1=$(commit_file "$SEED" upstream.txt "u1" "upstream one")
git -C "$SEED" push -q origin main
: >"$PUSH_LOG"
run rebase main
check "$RC" "0" "clean rebase: exit 0"
check "$OUT" "" "clean rebase: nothing on stdout"
check "$(git -C "$CLONE" merge-base --is-ancestor "$U1" HEAD && echo on-base)" "on-base" "clean rebase: the branch sits on origin/main"
check "$(git -C "$CLONE" branch --show-current)" "feature" "clean rebase: the branch is still checked out"

run push
check "$RC" "0" "push after a rebase: exit 0"
check "$(origin_tip feature)" "$(clone_head)" "push after a rebase: origin holds the rebased head"
check_contains "$(last_push)" "--force-with-lease=refs/heads/feature:$C" \
  "push after a rebase: the lease names the fetched remote tip"

: >"$PUSH_LOG"
run push
check "$RC" "0" "push with nothing new: exit 0 after verifying"
check_lacks "$(last_push)" "--force-with-lease" "push with nothing new: a plain push"

D=$(commit_file "$CLONE" d.txt "d" "feature D")
run push
check "$RC:$(origin_tip feature)" "0:$D" "push of a new commit: exit 0, origin holds it"
check_lacks "$(last_push)" "--force-with-lease" "push of a new commit: a plain push"

git -C "$CLONE" reset -q --hard HEAD~1
: >"$PUSH_LOG"
run push
check "$RC" "11" "push behind origin: exit 11"
check_contains "$ERR" "is behind origin/feature ($D); nothing was pushed" "push behind origin: stderr names the remote tip"
check "$(cat "$PUSH_LOG")" "" "push behind origin: no push was run"
check "$(origin_tip feature)" "$D" "push behind origin: origin keeps its tip"
git -C "$CLONE" reset -q --hard "$D"

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
run checkout feature

run rebase main
check "$RC" "3" "stopped rebase: exit 3"
check "$OUT" "other.txt
shared.txt" "stopped rebase: stdout is the conflicted paths, one per line, and nothing else"
check "$(in_rebase)" "yes" "stopped rebase: the rebase is in progress"

printf 'resolved shared\n' >"$CLONE/shared.txt"
run continue shared.txt
check "$RC:$OUT" "5:" "continue with another conflicted path left unstaged: exit 5"
check_contains "$ERR" "other.txt" "continue refused: stderr names the unresolved path"
check "$(in_rebase)" "yes" "continue refused: the rebase is still in progress"

printf 'resolved other\n' >"$CLONE/other.txt"
run continue other.txt
check "$RC" "3" "continue: the next stop exits 3"
check "$OUT" "base.txt" "continue: stdout is the next stop's conflicted path"
check "$(git -C "$CLONE" log -1 --format='%an <%ae>|%s' HEAD)" "Author <author@example.com>|feature E" \
  "continue: the stopped commit keeps its author and message"

printf 'resolved base\n' >"$CLONE/base.txt"
run continue base.txt
check "$RC:$OUT" "0:" "continue: the last stop finishes the rebase, exit 0"
check "$(in_rebase)" "no" "continue: no rebase is left in progress"
check "$(git -C "$CLONE" log -1 --format='%an|%s' HEAD)" "Author|feature F" \
  "continue: the last commit keeps its author and message"
check "$(git -C "$CLONE" branch --show-current)" "feature" "continue: the branch is checked out again"
check "$([ -e "$SANDBOX/editor-opened" ] && echo opened || echo never)" "never" "continue: no editor was opened"
run push
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
run checkout feature
PRE_REBASE=$(clone_head)
run rebase main
check "$RC" "3" "abort: the rebase stopped"
run abort
check "$RC" "0" "abort: exit 0"
check "$(clone_head)" "$PRE_REBASE" "abort: the branch is at its pre-rebase tip"
check "$(git -C "$CLONE" branch --show-current)" "feature" "abort: the branch is checked out again"
check "$(in_rebase)" "no" "abort: no rebase is left in progress"

run abort
check "$RC" "6" "abort with no rebase in progress: exit 6"
run continue shared.txt
check "$RC" "6" "continue with no rebase in progress: exit 6"

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
run checkout skipper
run rebase main
check "$RC:$OUT" "3:other.txt" "skip: the rebase stopped on other.txt"
printf 'main skip\n' >"$CLONE/other.txt"
run continue other.txt
check "$RC:$OUT" "0:" "skip: continue with an emptying resolution exits 0"
check "$(in_rebase)" "no" "skip: no rebase is left in progress"
check "$(clone_head)" "$MAIN_TIP" "skip: the emptied commit is dropped, the branch is at origin/main"
check "$(git -C "$CLONE" branch --show-current)" "skipper" "skip: the branch is checked out again"
check "$([ -e "$SANDBOX/editor-opened" ] && echo opened || echo never)" "never" "skip: no editor was opened"
run checkout feature
check "$RC" "0" "skip: back on feature"

# --- detached HEAD ----------------------------------------------------------
git -C "$CLONE" checkout -q --detach
run rebase main
check "$RC" "7" "rebase on a detached HEAD: exit 7"
run push
check "$RC" "7" "push on a detached HEAD: exit 7"
git -C "$CLONE" checkout -q feature

# --- push failures ----------------------------------------------------------
# The remote moves between the script's fetch and its push: a git whose
# push lets the seed push first.
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
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$SANDBOX/racebin/git"

commit_file "$CLONE" plain.txt "plain" "plain push" >/dev/null
CASE_PATH="$SANDBOX/racebin" run push
check "$RC" "8" "plain push, remote moved since the fetch: exit 8"

git -C "$CLONE" fetch -q origin
git -C "$CLONE" reset -q --hard origin/feature
git -C "$CLONE" commit -q --amend -m "rewritten"
CASE_PATH="$SANDBOX/racebin" run push
check "$RC" "8" "lease push, remote moved since the fetch: exit 8"
check_lacks "$(cat "$PUSH_LOG")" "--force " "push never uses --force"
check_lacks "$(cat "$PUSH_LOG")" "--mirror" "push never uses --mirror"

git -C "$CLONE" fetch -q origin
git -C "$CLONE" reset -q --hard origin/feature

printf 'dirty\n' >>"$CLONE/base.txt"
run push
check "$RC" "10" "push verification, a dirty tree: exit 10"
git -C "$CLONE" checkout -q -- base.txt

# The remote accepts the push, then moves the branch somewhere else.
OTHER=$(git -C "$CLONE" rev-parse HEAD~1)
cat >"$ORIGIN/hooks/post-receive" <<HOOK
#!/usr/bin/env bash
git update-ref refs/heads/feature $OTHER
HOOK
chmod +x "$ORIGIN/hooks/post-receive"
commit_file "$CLONE" moved.txt "moved" "moved after push" >/dev/null
run push
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
run push
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
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$SANDBOX/failbin/git"
git -C "$CLONE" fetch -q origin
CASE_PATH="$SANDBOX/failbin" run push
check "$RC" "1" "unhandled failure: exit 1, not git's 9"
check_contains "$ERR" "failed (exit 9)" "unhandled failure: stderr names its status"

OUT=$(cd "$SANDBOX" && /bin/bash "$SCRIPT" push 2>"$SANDBOX/stderr")
RC=$?
check "$RC" "1" "outside a repository: exit 1"

# --- release ----------------------------------------------------------------
run release feature
check "$RC" "0" "release: exit 0"
check "$(git -C "$CLONE" branch --show-current)" "" "release: HEAD is detached"
check "$(git -C "$CLONE" rev-parse -q --verify refs/heads/feature || echo gone)" "gone" "release: the local branch is deleted"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
