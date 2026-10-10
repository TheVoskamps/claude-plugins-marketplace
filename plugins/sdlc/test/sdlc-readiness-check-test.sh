#!/usr/bin/env bash
#
# sdlc-readiness-check-test.sh -- drive plugins/sdlc/bin/sdlc-readiness-check
# against a scratch repository and a stub issue-view serving a case's
# body: each check key passing and failing, an unkeyed bullet, an
# unknown key, malformed arguments, paths that leave the repo root or
# start with '-', a [no-match] path absent from the tree, a hostile ERE,
# fenced blocks and a wrapped bullet, and issue-view missing from PATH.
# A bullet that would write to the tree if anything ran it leaves a
# marker file, and each case carrying one checks that none appeared.
#
# Needs bash, git and the POSIX utilities. Reaches no network.
#
# Usage: sdlc-readiness-check-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$TEST_DIR/../bin/sdlc-readiness-check"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-readiness-check-test.XXXXXX")"
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

check_lines() {
  local n
  n=$(printf '%s' "$1" | grep -c '')
  check "$n" "$2" "$3"
}

# The scratch repository. Nothing in it is ever run by the check; the
# test script under tests/ leaves a marker if anything does.
REPO="$SANDBOX/repo"
mkdir -p "$REPO/plugins/demo/.claude-plugin" "$REPO/src" "$REPO/tests" "$SANDBOX/outside"
git -C "$REPO" init -q
echo '{"version": "1.0.0"}' >"$REPO/plugins/demo/.claude-plugin/plugin.json"
printf 'keep\neval x\n' >"$REPO/src/a.sh"
printf 'eval y\n' >"$REPO/src/b.sh"
printf 'a;b|c\n' >"$REPO/src/semi.txt"
printf 'touch "%s/ran-test"\n' "$SANDBOX" >"$REPO/tests/t.sh"
chmod +x "$REPO/tests/t.sh"
printf 'eval z\n' >"$SANDBOX/outside/secret"
ln -s ../outside/secret "$REPO/link"
ln -s ../outside "$REPO/ldir"

# The stub issue-view prints the header issue-view prints, then the
# case's body.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/issue-view" <<EOF
#!/bin/sh
printf '#%s Stub    (OPEN)\nhttps://h.example/o/r/issues/%s\n\nLabels:     (none)\n\nBody:\n' "\$1" "\$1"
cat "$SANDBOX/body.md"
EOF
chmod +x "$SANDBOX/bin/issue-view"

# run <body>: runs the check on issue 7 from the repository with the
# stub on PATH, leaving stdout in OUT and the status in RC.
run() {
  printf '%s\n' "$1" >"$SANDBOX/body.md"
  OUT=$(cd "$REPO" && PATH="$SANDBOX/bin:$PATH" "$CHECK" 7 2>"$SANDBOX/err")
  RC=$?
}

# no_marker <label>: checks that no marker a case's bullets would leave
# if run, `ran-test` or `pwned*`, exists anywhere in the sandbox.
no_marker() {
  local found
  found=$(find "$SANDBOX" -name 'ran-test' -o -name 'pwned*')
  check "$found" "" "$1: nothing was executed"
}

FILES_ALL="## Files affected (floor)

- \`plugins/demo/.claude-plugin/plugin.json\` (update)
- \`src/a.sh\` (update)
- \`src/new.sh\` (new)
- \`tests/t.sh\` (update)"

# --- every key passes when its paths are listed -----------------------

run "## Acceptance

### Mechanical

- [exists] src/new.sh
- [executable] src/new.sh
- [test-passes] tests/t.sh
- [max-lines] src/a.sh 1
- [lint-clean] src/a.sh tests/t.sh
- [version-bumped] demo
- [no-match] \\beval\\b in src/a.sh
- [no-match] nothing-matches-this in src/b.sh src/new.sh

### Semantic

- [run] touch pwned

$FILES_ALL"
check "$RC" 0 "all keys pass: exit 0"
check "$OUT" "" "all keys pass: no gap line"
no_marker "all keys pass"

# --- presence keys fail on an unlisted path, without running anything --

run "## Acceptance

### Mechanical

- [exists] src/x.sh
- [executable] src/x.sh
- [test-passes] tests/t.sh
- [max-lines] src/b.sh 0
- [lint-clean] src/a.sh src/b.sh
- [version-bumped] demo

## Files affected (floor)

- \`src/a.sh\` (update)"
check "$RC" 3 "presence: exit 3"
check_lines "$OUT" 6 "presence: one gap line per failing bullet"
check_contains "$OUT" 'Acceptance criteria: Mechanical bullet "- [exists] src/x.sh" names a file the files-affected section does not list: src/x.sh' "presence: [exists] gap quotes the bullet and names the path"
check_contains "$OUT" '"- [executable] src/x.sh"' "presence: [executable] gap"
check_contains "$OUT" '"- [test-passes] tests/t.sh" names a file the files-affected section does not list: tests/t.sh' "presence: [test-passes] gap"
check_contains "$OUT" '"- [max-lines] src/b.sh 0" names a file the files-affected section does not list: src/b.sh' "presence: [max-lines] gap"
check_contains "$OUT" '"- [lint-clean] src/a.sh src/b.sh" names a file the files-affected section does not list: src/b.sh' "presence: [lint-clean] gap names only the unlisted path"
check_contains "$OUT" 'does not list: plugins/demo/.claude-plugin/plugin.json' "presence: [version-bumped] gap names the plugin.json"
no_marker "presence"

# --- [no-match] reports each site not covered by update or delete -----

printf 'eval\nx\neval\n' >"$REPO/src/c.sh"
printf 'eval\n' >"$REPO/src/d.sh"
run "## Acceptance

### Mechanical

- [no-match] eval in src/a.sh src/b.sh
- [no-match] eval in src/c.sh
- [no-match] eval in src/d.sh

## Files affected (floor)

- \`src/a.sh\` (new)
- \`src/./d.sh\` (delete)"
check "$RC" 3 "no-match: exit 3"
check_contains "$OUT" 'No unanswered design decisions: Mechanical bullet "- [no-match] eval in src/a.sh src/b.sh" matches in a file the files-affected section does not list as update or delete: src/a.sh:2, src/b.sh:1' "no-match: a new-tagged and an unlisted file's sites are named by path and line"
check_contains "$OUT" 'src/c.sh:1, src/c.sh:3' "no-match: every site in a file is named"
check_lines "$OUT" 2 "no-match: a delete-tagged file's site is covered"
rm -f "$REPO/src/c.sh" "$REPO/src/d.sh"

# --- [no-match] on a path absent from the tree ----------------------

run "## Acceptance

### Mechanical

- [no-match] eval in src/b.sh src/missing.sh
- [no-match] eval in src/gone.sh

## Files affected (floor)

- \`src/b.sh\` (update)
- \`src/gone.sh\` (update)"
check "$RC" 3 "absent path: exit 3"
check_lines "$OUT" 2 "absent path: one gap per bullet"
check_contains "$OUT" 'Acceptance criteria: Mechanical bullet "- [no-match] eval in src/b.sh src/missing.sh" names a file absent from the tree that the files-affected section does not list as new: src/missing.sh; nothing was run' "absent path: an unlisted absent path is a gap"
check_contains "$OUT" '"- [no-match] eval in src/gone.sh" names a file absent from the tree that the files-affected section does not list as new: src/gone.sh' "absent path: one listed as update is a gap"

# --- an unkeyed bullet and an unknown key are gaps, and never run -----

run "## Acceptance

### Mechanical

- touch $SANDBOX/pwned1
- \`touch $SANDBOX/pwned2\`
- [run] touch $SANDBOX/pwned3
- [Exists] src/a.sh

$FILES_ALL"
check "$RC" 3 "unkeyed: exit 3"
check_lines "$OUT" 4 "unkeyed: one gap per bullet"
check_contains "$OUT" "\"- touch $SANDBOX/pwned1\" opens with no check key; nothing was run" "unkeyed: a bare command is a gap"
check_contains "$OUT" "opens with an unrecognised check key [run]; nothing was run" "unknown key: a gap"
check_contains "$OUT" '"- [Exists] src/a.sh" opens with no check key' "unknown key: keys are lowercase"
no_marker "unkeyed and unknown"

# --- malformed arguments ----------------------------------------------

run "## Acceptance

### Mechanical

- [exists]
- [exists] src/a.sh src/b.sh
- [max-lines] src/a.sh many
- [no-match] eval
- [no-match] in src/a.sh
- [version-bumped] ../demo

$FILES_ALL"
check "$RC" 3 "malformed: exit 3"
check_lines "$OUT" 6 "malformed: one gap per bullet"
check_contains "$OUT" '"- [max-lines] src/a.sh many" is malformed for [max-lines]' "malformed: a non-integer line count"
check_contains "$OUT" '"- [no-match] eval" is malformed' "malformed: [no-match] without 'in'"
check_contains "$OUT" '"- [version-bumped] ../demo" is malformed for [version-bumped]' "malformed: a plugin name that is a path"

# --- paths that leave the repo, start with '-', or are globs ----------

run "## Acceptance

### Mechanical

- [exists] ../outside/secret
- [no-match] eval in src/../../outside/secret
- [no-match] eval in $SANDBOX/outside/secret
- [no-match] eval in -r
- [no-match] eval in src/a.sh --include=x
- [no-match] eval in link
- [no-match] eval in ldir/secret
- [exists] src/*.sh
- [no-match] eval in src

## Files affected (floor)

- \`../outside/secret\` (update)
- \`link\` (update)"
check "$RC" 3 "paths: exit 3"
check_lines "$OUT" 9 "paths: one gap per bullet"
check_contains "$OUT" '"- [exists] ../outside/secret" names a path outside the repo root: ../outside/secret; nothing was checked' "paths: '..' out of the root is refused even when listed"
check_contains "$OUT" '"- [no-match] eval in src/../../outside/secret" names a path outside the repo root' "paths: '..' after a component is refused"
check_contains "$OUT" "names a path outside the repo root: $SANDBOX/outside/secret; nothing was run" "paths: an absolute path is refused"
check_contains "$OUT" "\"- [no-match] eval in -r\" names a path starting with '-': -r; nothing was run" "paths: a leading '-' is refused"
check_contains "$OUT" "names a path starting with '-': --include=x" "paths: an option among the paths is refused"
check_contains "$OUT" '"- [no-match] eval in link" names a symlink' "paths: a symlinked file is refused"
check_contains "$OUT" '"- [no-match] eval in ldir/secret" names a path outside the repo root' "paths: a symlinked directory out of the root is refused"
check_contains "$OUT" '"- [exists] src/*.sh" names a glob' "paths: a glob is refused"
check_contains "$OUT" '"- [no-match] eval in src" names a directory' "paths: a directory is refused"
case "$OUT" in
  *outside/secret:1*) check "leaked" "" "paths: no file outside the repo was read" ;;
  *) check "" "" "paths: no file outside the repo was read" ;;
esac

# --- a hostile ERE is a pattern, never shell text ---------------------

run "## Acceptance

### Mechanical

- [no-match] \$(touch $SANDBOX/pwned4)|\`touch $SANDBOX/pwned5\`|a;b in src/semi.txt
- [no-match] -f/dev/null|x;touch $SANDBOX/pwned6 in src/semi.txt

$FILES_ALL"
check "$RC" 3 "hostile ERE: exit 3"
check_contains "$OUT" 'matches in a file the files-affected section does not list as update or delete: src/semi.txt:1' "hostile ERE: matched by grep -E as a pattern"
check_lines "$OUT" 1 "hostile ERE: an ERE starting with '-' is no option"
no_marker "hostile ERE"

run "## Acceptance

### Mechanical

- [no-match] ( in src/a.sh

$FILES_ALL"
check "$RC" 3 "invalid ERE: exit 3"
check_contains "$OUT" '"- [no-match] ( in src/a.sh" has an ERE grep rejects' "invalid ERE: a gap"

# --- the grammar: fences, wrapped bullets, sections -------------------

run "## Acceptance

### Mechanical

\`\`\`markdown
### Mechanical

- [run] touch $SANDBOX/pwned7
\`\`\`

- [no-match] eval in src/a.sh
  src/b.sh

### Semantic

- touch $SANDBOX/pwned8

## Notes

- [run] touch $SANDBOX/pwned9

$FILES_ALL"
check "$RC" 3 "grammar: exit 3"
check "$OUT" 'No unanswered design decisions: Mechanical bullet "- [no-match] eval in src/a.sh src/b.sh" matches in a file the files-affected section does not list as update or delete: src/b.sh:1' "grammar: a wrapped bullet is joined, and only Mechanical bullets outside a fence are graded"
no_marker "grammar"

run "## Acceptance

### Mechanical

\`\`\`markdown
~~~
- [run] touch $SANDBOX/pwned10
\`\`\`

\`\`\`\`markdown
\`\`\`
- [run] touch $SANDBOX/pwned11
\`\`\`\`

- [no-match] eval in src/b.sh

$FILES_ALL"
check "$RC" 3 "nested fences: exit 3"
check "$OUT" 'No unanswered design decisions: Mechanical bullet "- [no-match] eval in src/b.sh" matches in a file the files-affected section does not list as update or delete: src/b.sh:1' "nested fences: a different or shorter marker does not close a fence"
no_marker "nested fences"

run "## Acceptance

### Semantic

- anything

$FILES_ALL"
check "$RC" 0 "no Mechanical section: exit 0"
check "$OUT" "" "no Mechanical section: no gap line"

# --- invocation -------------------------------------------------------

printf '' >"$SANDBOX/body.md"
OUT=$(cd "$REPO" && PATH="/usr/bin:/bin" "$CHECK" 7 2>"$SANDBOX/err")
RC=$?
check "$RC" 1 "no issue-view: exit 1"
check_contains "$(cat "$SANDBOX/err")" "issue-view is not on PATH" "no issue-view: the message names issue-view"

OUT=$(cd "$REPO" && PATH="$SANDBOX/bin:$PATH" "$CHECK" 2>"$SANDBOX/err")
check "$?" 2 "no argument: exit 2"
OUT=$(cd "$REPO" && PATH="$SANDBOX/bin:$PATH" "$CHECK" 'x;y' 2>"$SANDBOX/err")
check "$?" 2 "a non-numeric argument: exit 2"
OUT=$(cd "$REPO" && PATH="$SANDBOX/bin:$PATH" "$CHECK" '#7' 2>"$SANDBOX/err")
check "$?" 0 "a leading '#' is accepted"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All cases passed."
else
  echo "$FAILURES case(s) failed."
  exit 1
fi
