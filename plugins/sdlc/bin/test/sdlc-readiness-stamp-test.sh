#!/usr/bin/env bash
#
# sdlc-readiness-stamp-test.sh -- drive plugins/sdlc/bin/sdlc-readiness-stamp
# against a scratch clone of a local bare origin, a stub issue-view serving
# a case's blocked-by rows and body, and a stub issue-comment keeping the
# one marker comment in a file: `check` with no stamp, `match` on an
# unchanged origin and on one whose change touches no listed file, `diff`
# on a change to a listed file and on a rename from and onto one, `full`
# for a changed body, a changed blocked-by edge, a changed sdlc version,
# an unreadable stamp, a stamped commit origin no longer carries and a
# Jira tracker; a blocked-by reference spelled another way still matching;
# `write` composing the stamp from the files-affected section and --file,
# and editing it in place; and `write` refusing, with nothing written, a
# dirty tree, an untracked file, a HEAD origin lacks, a --commit that is
# not HEAD, an unknown --commit and a Jira tracker; and the usage errors.
#
# Needs bash, git, jq, the POSIX utilities and
# plugins/git-tools/bin/git-default-branch in the same checkout. Reaches no
# network.
#
# Usage: sdlc-readiness-stamp-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$TEST_DIR/../sdlc-readiness-stamp"
DEFAULT_BRANCH="$(cd "$TEST_DIR/../../../git-tools/bin" && pwd)/git-default-branch"
VERSION=$(jq -r .version "$TEST_DIR/../../.claude-plugin/plugin.json")
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-readiness-stamp-test.XXXXXX")"
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
# text contains the substring.
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

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# The origin, the clone the script runs in, and a second clone that moves
# origin's main.
ORIGIN="$SANDBOX/origin.git"
REPO="$SANDBOX/repo"
PUSHER="$SANDBOX/pusher"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$PUSHER" 2>/dev/null
mkdir -p "$PUSHER/src"
printf 'a\n' >"$PUSHER/src/a.sh"
printf 'b\n' >"$PUSHER/src/b.sh"
printf 'other\n' >"$PUSHER/other.txt"
git -C "$PUSHER" add -A
git -C "$PUSHER" commit -q -m base
git -C "$PUSHER" push -q origin HEAD:main
git clone -q "$ORIGIN" "$REPO"

# push_change <message> <git command>...: run the command in the pusher,
# commit everything and push it to origin's main.
push_change() {
  local msg=$1
  shift
  git -C "$PUSHER" "$@"
  git -C "$PUSHER" add -A
  git -C "$PUSHER" commit -q -m "$msg"
  git -C "$PUSHER" push -q origin HEAD:main
}

# The stubs: issue-view prints the title, URL, the rows in `rows` and the
# body in `body.md`; issue-comment reads and writes the marker comment in
# `comment`, logging each write to `writes`; gh fails, so
# git-default-branch falls back to origin's HEAD symref.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/issue-view" <<EOF
#!/bin/sh
printf '#%s Stub    (OPEN)\nhttps://github.com/Acme/Widgets/issues/%s\n\nLabels:     (none)\n\n' "\$1" "\$1"
cat "$SANDBOX/rows"
printf '\nBody:\n'
cat "$SANDBOX/body.md"
EOF
cat >"$SANDBOX/bin/issue-comment" <<EOF
#!/bin/sh
if [ "\$2" = --read ]; then
  [ ! -f "$SANDBOX/comment" ] || cat "$SANDBOX/comment"
  exit 0
fi
cp "\$3" "$SANDBOX/comment"
echo write >>"$SANDBOX/writes"
echo "Commented on issue #\$1."
EOF
printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/bin/gh"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$DEFAULT_BRANCH" >"$SANDBOX/bin/git-default-branch"
chmod +x "$SANDBOX/bin/"*

# serve <blocked-by line>...: the `Blocked by:` rows the stub prints.
serve() {
  printf 'Blocked by:\n' >"$SANDBOX/rows"
  if [ "$#" -eq 0 ]; then printf '  (none)\n' >>"$SANDBOX/rows"; else printf '  - %s\n' "$@" >>"$SANDBOX/rows"; fi
}

BODY="## Summary

Do the thing.

\`\`\`markdown
## Files affected (floor)

- \`fenced/ignored.sh\` (new)
\`\`\`

## Files affected (floor)

- \`src/a.sh\` (update)
- \`src/new.sh\` (new)"
printf '%s\n' "$BODY" >"$SANDBOX/body.md"
serve '#5 Blocker' 'other/repo#6 Elsewhere'

# run <arg>...: run the script from the clone with the stubs on PATH,
# leaving stdout in OUT, stderr in the sandbox's `err` and the status
# in RC.
run() {
  OUT=$(cd "$REPO" && PATH="$SANDBOX/bin:$PATH" "$STAMP" "$@" 2>"$SANDBOX/err")
  RC=$?
}

# writes: how many times the stub issue-comment wrote the stamp.
writes() {
  if [ -f "$SANDBOX/writes" ]; then grep -c '' "$SANDBOX/writes"; else echo 0; fi
}

# sync: bring the clone's main to origin's.
sync() {
  git -C "$REPO" pull -q --ff-only origin main
}

# --- usage ------------------------------------------------------------

run
check "$RC" 2 "usage: no arguments"
run check
check "$RC" 2 "usage: check with no issue"
run check 7 extra
check "$RC" 2 "usage: check takes one issue"
run check x7
check "$RC" 2 "usage: not an issue number"
run write 7
check "$RC" 2 "usage: write needs --commit"
run write 7 --commit
check "$RC" 2 "usage: --commit needs a value"
run write 7 --commit abc --bogus x
check "$RC" 2 "usage: unknown write argument"
run frob 7
check "$RC" 2 "usage: unknown mode"

# --- check before any stamp --------------------------------------------

run check 7
check "$RC:$OUT" "0:full the issue carries no stamp" "check: no stamp is full"

# --- write ------------------------------------------------------------

HEAD0=$(git -C "$REPO" rev-parse HEAD)
run write '#7' --commit "$HEAD0" --file other.txt --file ./src/a.sh
check "$RC" 0 "write: a clean tree at origin's tip writes the stamp"
check "$(writes)" 1 "write: one write"
STORED=$(cat "$SANDBOX/comment")
check "$(printf '%s\n' "$STORED" | head -n 1)" "## Orchestrate readiness" "write: the stamp opens with the marker"
FENCE='```'
check "$(printf '%s\n' "$STORED" | sed -n "/^${FENCE}yaml\$/,/^${FENCE}\$/p" | sed -n '4,9p')" "sdlc-version: $VERSION
files:
  - other.txt
  - src/a.sh
  - src/new.sh
$FENCE" "write: the version, and the files sorted and unique, a fenced section's path left out"
check "$(printf '%s\n' "$STORED" | grep '^commit: ')" "commit: $HEAD0" "write: the commit"
[[ $(printf '%s\n' "$STORED" | grep '^hash: ') =~ ^hash:\ [0-9a-f]{64}$ ]] && H=ok || H=bad
check "$H" ok "write: the hash is 64 hex digits"

run check 7
check "$RC:$OUT" "0:match" "check: an unchanged origin matches"

serve 'github.com/acme/widgets#5 Blocker' 'Other/Repo#6 Elsewhere'
run check 7
check "$OUT" "match" "check: a blocked-by reference spelled another way still matches"
serve '#5 Blocker' 'other/repo#6 Elsewhere'

# --- the diff from the stamped commit ------------------------------------

push_change "touch an unlisted file" rm -q src/b.sh
run check 7
check "$OUT" "match" "check: a diff touching no listed file matches"

push_change "touch a listed file" mv src/a.sh src/a2.sh
HEAD1=$(git -C "$PUSHER" rev-parse HEAD)
run check 7
check "$RC:$OUT" "0:diff $HEAD0..$HEAD1
touched src/a.sh
kept other.txt
kept src/new.sh" "check: a rename from a listed file is diff, naming it touched and the rest kept"

push_change "rename onto a listed path" mv other.txt src/new.sh
sync
HEAD2=$(git -C "$REPO" rev-parse HEAD)
run write 7 --commit "$HEAD2" --file other.txt
check "$RC:$(writes)" "0:2" "write: a second write"
check "$(grep -c '^## Orchestrate readiness$' "$SANDBOX/comment")" 1 "write: the stamp is replaced, not appended to"
check "$(grep '^commit: ' "$SANDBOX/comment")" "commit: $HEAD2" "write: the new commit"
push_change "rename onto a listed path" mv src/a2.sh src/a.sh
HEAD3=$(git -C "$PUSHER" rev-parse HEAD)
run check 7
check "$OUT" "diff $HEAD2..$HEAD3
touched src/a.sh
kept other.txt
kept src/new.sh" "check: a rename onto a listed path is diff"

# --- full -------------------------------------------------------------

sync
HEAD4=$(git -C "$REPO" rev-parse HEAD)
run write 7 --commit "$HEAD4"
check "$RC" 0 "write: a stamp at the new tip"
run check 7
check "$OUT" "match" "check: matches at the new tip"

printf '%s\nOne more line.\n' "$BODY" >"$SANDBOX/body.md"
run check 7
check "$RC:$OUT" "0:full the body or a blocked-by edge changed since the stamp" "check: a changed body is full"
printf '%s\n' "$BODY" >"$SANDBOX/body.md"

serve '#5 Blocker'
run check 7
check "$OUT" "full the body or a blocked-by edge changed since the stamp" "check: a removed blocked-by edge is full"
serve '#5 Blocker' 'other/repo#6 Elsewhere' '#9 New blocker'
run check 7
check "$OUT" "full the body or a blocked-by edge changed since the stamp" "check: an added blocked-by edge is full"
serve '#5 Blocker' 'other/repo#6 Elsewhere'
run check 7
check "$OUT" "match" "check: the original edges match again"

cp "$SANDBOX/comment" "$SANDBOX/comment.good"
sed 's/^sdlc-version: .*/sdlc-version: 0.0.1/' "$SANDBOX/comment.good" >"$SANDBOX/comment"
run check 7
check "$OUT" "full the stamp was graded by sdlc 0.0.1, not $VERSION" "check: another sdlc version is full"

sed '/^commit: /d' "$SANDBOX/comment.good" >"$SANDBOX/comment"
run check 7
check "$OUT" "full the stamp is unreadable" "check: a stamp with no commit is unreadable"
sed 's/^hash: .*/hash: nothex/' "$SANDBOX/comment.good" >"$SANDBOX/comment"
run check 7
check "$OUT" "full the stamp is unreadable" "check: a malformed hash is unreadable"
printf '## Orchestrate readiness\n\nno block here\n' >"$SANDBOX/comment"
run check 7
check "$OUT" "full the stamp is unreadable" "check: a stamp with no yaml block is unreadable"
cp "$SANDBOX/comment.good" "$SANDBOX/comment"

# Origin's main rewritten to a history without the stamped commit.
git -C "$PUSHER" checkout -q --orphan rewritten
git -C "$PUSHER" commit -q -m "rewritten history"
git -C "$PUSHER" push -q -f origin rewritten:main
run check 7
check "$RC:$OUT" "0:full the stamped commit $HEAD4 is not an ancestor of origin/main" \
  "check: a stamped commit origin no longer carries is full"

# --- write refusals -----------------------------------------------------

git -C "$REPO" fetch -q origin
git -C "$REPO" reset -q --hard origin/main
TIP=$(git -C "$REPO" rev-parse HEAD)
before=$(writes)
printf 'dirty\n' >>"$REPO/src/new.sh"
run write 7 --commit "$TIP"
check "$RC:$OUT" "3:refused: the working tree has uncommitted changes or untracked files; no stamp was written" \
  "write: a modified file refuses"
git -C "$REPO" checkout -q -- .
printf 'new\n' >"$REPO/untracked.txt"
run write 7 --commit "$TIP"
check "$RC" 3 "write: an untracked file refuses"
rm "$REPO/untracked.txt"

printf 'local\n' >"$REPO/local.txt"
git -C "$REPO" add local.txt
git -C "$REPO" commit -q -m local
LOCAL=$(git -C "$REPO" rev-parse HEAD)
run write 7 --commit "$LOCAL"
check "$RC" 3 "write: a HEAD origin lacks refuses"
check_contains "$OUT" "are not one commit" "write: the refusal names the three commits"
run write 7 --commit "$TIP"
check "$RC" 3 "write: a --commit that is not HEAD refuses"
git -C "$REPO" reset -q --hard "$TIP"
run write 7 --commit 0123456789abcdef0123456789abcdef01234567
check "$RC:$OUT" "3:refused: --commit 0123456789abcdef0123456789abcdef01234567 names no commit in this clone; no stamp was written" \
  "write: an unknown --commit refuses"
check "$(writes)" "$before" "write: no refusal wrote anything"

run write 7 --commit "$TIP"
check "$RC" 0 "write: the clean tip writes again"

# --- Jira ----------------------------------------------------------------

mkdir -p "$REPO/.issues"
printf -- '---\nschema-version: 7\nissues: jira\n---\n' >"$REPO/.issues/repo-config.md"
run check 7
check "$RC:$OUT" "0:full the tracker is Jira, which carries no stamp" "Jira: check is full"
before=$(writes)
run write 7 --commit "$TIP"
check "$RC:$OUT" "3:refused: the tracker is Jira, which carries no stamp; no stamp was written" "Jira: write refuses"
check "$(writes)" "$before" "Jira: nothing written"
rm -r "$REPO/.issues"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all cases passed"
  exit 0
fi
echo "$FAILURES failure(s)"
exit 1
