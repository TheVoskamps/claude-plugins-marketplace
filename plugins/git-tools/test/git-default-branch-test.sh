#!/usr/bin/env bash
#
# git-default-branch-test.sh -- drive plugins/git-tools/bin/git-default-branch,
# under the bash 3.2 macOS ships, with a stub gh first on PATH and a clone
# of a local bare origin: the GitHub setting winning over the symref, the
# symref fallback when gh fails or names nothing, the failure when
# neither names a branch, the usage error, and a failing command the
# script does not handle.
#
# Needs git on PATH. Reaches no network.
#
# Usage: git-default-branch-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../bin/git-default-branch"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/git-default-branch-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0

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
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
CLONE="$SANDBOX/clone"

git init -q --bare "$ORIGIN"
git init -q -b main "$SEED"
git -C "$SEED" commit -q --allow-empty -m base
git -C "$SEED" push -q "$ORIGIN" main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$CLONE"

# The stub gh prints $SANDBOX/gh.out when it exists, logs its arguments
# to $SANDBOX/gh.args, and exits with the status in $SANDBOX/gh.rc, 0
# when that file is absent.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >"$SANDBOX/gh.args"
[ ! -f "$SANDBOX/gh.out" ] || cat "$SANDBOX/gh.out"
echo "gh: stub error" >&2
exit "\$(cat "$SANDBOX/gh.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$SANDBOX/bin/gh"

# gh_serves <output> <status> -- what the stub gh prints and exits with.
gh_serves() {
  printf '%s' "$1" >"$SANDBOX/gh.out"
  echo "$2" >"$SANDBOX/gh.rc"
}

# run [<dir> [<arg>]] -- run the script from <dir>, $CLONE by default,
# passing <arg> when given, with the stub gh first on PATH; leaves OUT,
# ERR, RC.
run() {
  OUT=$(cd "${1:-$CLONE}" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$SCRIPT" ${2+"$2"} 2>"$SANDBOX/stderr")
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
}

check "$([ -x "$SCRIPT" ] && echo yes)" "yes" "git-default-branch is executable"

# --- gh names the branch ----------------------------------------------------
gh_serves "trunk
" 0
run
check "$RC:$OUT" "0:trunk" "gh: the GitHub setting wins over origin/HEAD"
check "$(cat "$SANDBOX/gh.args")" "repo view --json defaultBranchRef --jq .defaultBranchRef.name // empty" \
  "gh: asks for defaultBranchRef"
check "$ERR" "" "gh: nothing on stderr"

# --- the symref fallback ----------------------------------------------------
gh_serves "" 1
run
check "$RC:$OUT" "0:main" "gh fails: origin/HEAD names the branch"
check "$ERR" "" "gh fails: gh's own error is dropped"

gh_serves "" 0
run
check "$RC:$OUT" "0:main" "gh names nothing: origin/HEAD names the branch"

# --- neither names a branch -------------------------------------------------
git -C "$CLONE" remote set-head origin -d
gh_serves "" 1
run
check "$RC:$OUT" "1:" "neither: exit 1, nothing on stdout"
check_contains "$ERR" "neither \`gh repo view\` nor refs/remotes/origin/HEAD names a default branch" \
  "neither: stderr names both sources"

run "$SANDBOX"
check "$RC:$OUT" "1:" "outside a repository, gh failing: exit 1"

gh_serves "trunk
" 0
run "$SANDBOX"
check "$RC:$OUT" "0:trunk" "outside a repository: gh alone names the branch"

# --- usage ------------------------------------------------------------------
rm -f "$SANDBOX/gh.args"
run "$CLONE" extra
check "$RC:$OUT" "2:" "usage: an argument exits 2 with nothing on stdout"
check_contains "$ERR" "\`extra\` is not an argument" "usage: stderr names the argument"
check "$([ -f "$SANDBOX/gh.args" ] && echo ran)" "" "usage: gh did not run"

# --- a failing command the script does not handle ---------------------------
OUT=$(cd "$CLONE" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$SCRIPT" >&- 2>"$SANDBOX/stderr")
RC=$?
check "$RC" "1" "unhandled failure: a failing printf exits 1"
check_contains "$(cat "$SANDBOX/stderr")" "\`printf '%s\n' \"\$name\"\` failed" \
  "unhandled failure: stderr names the command"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
