#!/usr/bin/env bash
#
# git-range-test.sh -- drive plugins/git-tools/bin/git-range, under the
# bash 3.2 macOS ships, against a local bare origin and a clone of it,
# including a rebase that advances the base under the branch.
#
# Needs git on PATH. Reaches no network.
#
# Usage: git-range-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../bin/git-range"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/git-range-test.XXXXXX")"
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

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
CLONE="$SANDBOX/clone"
REAL_GIT=$(command -v git)

# commit_file <file> <content> <message> -- commit one file's new
# content in the seed, and print the new commit's SHA.
commit_file() {
  printf '%s\n' "$2" >"$SEED/$1"
  git -C "$SEED" add "$1"
  git -C "$SEED" commit -q -m "$3"
  git -C "$SEED" rev-parse HEAD
}

git init -q --bare "$ORIGIN"
git init -q -b main "$SEED"
git -C "$SEED" remote add origin "$ORIGIN"
FORK=$(commit_file base.txt base "base")
git -C "$SEED" checkout -q -b feature
A=$(commit_file a.txt "a one" "feature A")
B=$(commit_file shared.txt "feature line" "feature B")
OLD_HEAD=$B
git -C "$SEED" push -q origin main feature
git clone -q "$ORIGIN" "$CLONE"

# run <args...> -- run git-range from $CLONE; leaves OUT, ERR, RC.
run() {
  OUT=$(cd "$CLONE" && PATH="${CASE_PATH:+$CASE_PATH:}$PATH" /bin/bash "$SCRIPT" "$@" 2>"$SANDBOX/stderr")
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
}

tab=$(printf '\t')

check "$([ -x "$SCRIPT" ] && echo yes)" "yes" "git-range is executable"

# --- the whole branch ------------------------------------------------------
run --base main --head-ref feature --head "$OLD_HEAD"
check "$RC" "0" "whole branch: exit 0"
check "$OUT" "merge-base${tab}$FORK
commit${tab}$B
commit${tab}$A" "whole branch: the merge base, then every commit of the branch"

# --- a fetch is part of the call -------------------------------------------
git -C "$SEED" checkout -q feature
C=$(commit_file c.txt "c" "feature C")
git -C "$SEED" push -q origin feature
run --base main --head-ref feature --head "$C" --prev-head "$OLD_HEAD"
check "$RC" "0" "fetch: a head pushed after the clone is fetched and accepted"
check "$OUT" "merge-base${tab}$FORK
commit${tab}$C" "fetch: only the commit since --prev-head"

# --- the head moved ---------------------------------------------------------
run --base main --head-ref feature --head "$OLD_HEAD"
check "$RC" "3" "head mismatch: exit 3"
check "$OUT" "" "head mismatch: nothing on stdout"
check_contains "$ERR" "origin/feature is at $C, not at --head $OLD_HEAD" "head mismatch: stderr names both SHAs"

# --- a rebase that advances the base ----------------------------------------
# main gains two commits, one of them touching the line feature B
# changed, so the rebase keeps A's patch and rewrites B's.
git -C "$SEED" checkout -q main
U1=$(commit_file upstream.txt "u1" "upstream one")
U2=$(commit_file shared.txt "main line" "upstream two")
git -C "$SEED" checkout -q feature
git -C "$SEED" rebase -q main >/dev/null 2>&1
printf 'feature line\n' >"$SEED/shared.txt"
git -C "$SEED" add shared.txt
GIT_EDITOR=true git -C "$SEED" rebase --continue >/dev/null 2>&1
REBASED=$(git -C "$SEED" rev-parse HEAD)
NEW_A=$(git -C "$SEED" rev-parse HEAD~2)
NEW_B=$(git -C "$SEED" rev-parse HEAD~1)
git -C "$SEED" push -q -f origin main feature
run --base main --head-ref feature --head "$REBASED" --prev-head "$C"
check "$RC" "0" "rebase advancing the base: exit 0"
check "$OUT" "merge-base${tab}$U2
commit${tab}$NEW_B" "rebase advancing the base: only the commit whose patch changed"
check "$([ "$NEW_A" != "$A" ] && echo rewritten)" "rewritten" \
  "rebase advancing the base: A was rewritten too, and its unchanged patch keeps it out"
case "$OUT" in
  *"$U1"* | *"commit${tab}$U2"*) check "upstream commit listed" "none" "rebase advancing the base: no commit the base gained" ;;
  *) check "none" "none" "rebase advancing the base: no commit the base gained" ;;
esac

run --base main --head-ref feature --head "$REBASED"
check "$OUT" "merge-base${tab}$U2
commit${tab}$REBASED
commit${tab}$NEW_B
commit${tab}$NEW_A" "rebase advancing the base: without --prev-head, the whole rebased branch"

# --- a clean rebase is an empty delta ---------------------------------------
git -C "$SEED" checkout -q main
U3=$(commit_file elsewhere.txt "u3" "upstream three")
git -C "$SEED" checkout -q feature
git -C "$SEED" rebase -q main >/dev/null 2>&1
CLEAN=$(git -C "$SEED" rev-parse HEAD)
git -C "$SEED" push -q -f origin main feature
run --base main --head-ref feature --head "$CLEAN" --prev-head "$REBASED"
check "$RC" "0" "clean rebase: exit 0"
check "$OUT" "merge-base${tab}$U3" "clean rebase: the merge base and no commit"

# --- failures ---------------------------------------------------------------
run --base main --head-ref feature --head "$CLEAN" --prev-head 0123456789012345678901234567890123456789
check "$RC" "1" "unknown --prev-head: exit 1"
check_contains "$ERR" "--prev-head 0123456789012345678901234567890123456789 is not a commit in this repository" \
  "unknown --prev-head: stderr says so"

run --base nope --head-ref feature --head "$CLEAN"
check "$RC:$OUT" "1:" "missing base: exit 1, nothing on stdout"
check_contains "$ERR" "origin/nope does not exist after the fetch" "missing base: stderr names the ref"

run --base main --head-ref nope --head "$CLEAN"
check "$RC:$OUT" "1:" "missing head ref: exit 1, nothing on stdout"

# A git whose rev-list fails: a command the script does not handle exits
# 1 naming it, never with git's own status.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *' rev-list '*) echo "stub git: rev-list refused" >&2; exit 9 ;;
esac
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$SANDBOX/bin/git"
CASE_PATH="$SANDBOX/bin" run --base main --head-ref feature --head "$CLEAN"
check "$RC" "1" "unhandled failure: exit 1, not git's 9"
check_contains "$ERR" "git rev-list --right-only --cherry-pick" "unhandled failure: stderr names the failed command"
check_contains "$ERR" "failed (exit 9)" "unhandled failure: stderr names its status"
check "$OUT" "" "unhandled failure: nothing on stdout"

OUT=$(cd "$SANDBOX" && /bin/bash "$SCRIPT" --base main --head-ref feature --head "$CLEAN" 2>"$SANDBOX/stderr")
RC=$?
check "$RC" "1" "outside a repository: exit 1"

# --- usage ------------------------------------------------------------------
for args in "--head-ref feature --head $CLEAN" "--base main --head $CLEAN" "--base main --head-ref feature" \
  "--base main --head-ref feature --head abc123" "--base main --head-ref feature --head $CLEAN --prev-head HEAD" \
  "--base main --head-ref feature --head $CLEAN --bogus x" "--base"; do
  # shellcheck disable=SC2086 # each case is a word list
  run $args
  check "$RC:$OUT" "2:" "usage: \`$args\` exits 2 with nothing on stdout"
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
