#!/usr/bin/env bash
#
# sdlc-readiness-check-test.sh -- drive plugins/sdlc/bin/sdlc-readiness-check
# against a scratch repository and a stub issue-view serving a case's
# body: each check key passing and failing, an unkeyed bullet, an
# unknown key, malformed arguments, paths that leave the repo root,
# start with '-', or name a glob, a directory, a FIFO or the root
# itself, symlinks that stay inside the root and symlinks that lead out
# of it, a [no-match] path absent from the tree, a hostile ERE,
# fenced blocks and a wrapped bullet, every malformed line under
# `### Mechanical`, a failing bullet under each of the two acceptance
# sections and one under an ungraded `## Acceptance`, a body with
# neither acceptance section and sections with no bullet, and
# issue-view missing from PATH.
# A bullet that would write into the sandbox if anything ran it leaves a
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

# check_lines <text> <count> <label>: checks that the text holds exactly
# count lines, with or without a trailing newline; an empty text holds
# none.
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
ln -s src/b.sh "$REPO/inlink"
ln -s src "$REPO/indir"
mkfifo "$REPO/fifo"

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

# A bullet with no text is `-` and a trailing space, spelled `-$SP` so
# no editor strips the space.
SP=' '

FILES_ALL="## Files affected (floor)

- \`plugins/demo/.claude-plugin/plugin.json\` (update)
- \`src/a.sh\` (update)
- \`src/new.sh\` (new)
- \`tests/t.sh\` (update)"

# --- every key passes when its paths are listed -----------------------

run "## Code and instruction Markdown acceptance

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

run "## Code and instruction Markdown acceptance

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
run "## Code and instruction Markdown acceptance

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

run "## Code and instruction Markdown acceptance

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

run "## Code and instruction Markdown acceptance

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

run "## Code and instruction Markdown acceptance

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

run "## Code and instruction Markdown acceptance

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
- [no-match] eval in fifo
- [exists] .

## Files affected (floor)

- \`../outside/secret\` (update)
- \`link\` (update)
- \`fifo\` (update)"
check "$RC" 3 "paths: exit 3"
check_lines "$OUT" 11 "paths: one gap per bullet"
check_contains "$OUT" '"- [exists] ../outside/secret" names a path outside the repo root: ../outside/secret; nothing was checked' "paths: '..' out of the root is refused even when listed"
check_contains "$OUT" '"- [no-match] eval in src/../../outside/secret" names a path outside the repo root' "paths: '..' after a component is refused"
check_contains "$OUT" "names a path outside the repo root: $SANDBOX/outside/secret; nothing was run" "paths: an absolute path is refused"
check_contains "$OUT" "\"- [no-match] eval in -r\" names a path starting with '-': -r; nothing was run" "paths: a leading '-' is refused"
check_contains "$OUT" "names a path starting with '-': --include=x" "paths: an option among the paths is refused"
check_contains "$OUT" '"- [no-match] eval in link" names a path outside the repo root: link; nothing was run' "paths: a symlink to a file out of the root is refused even when listed"
check_contains "$OUT" '"- [no-match] eval in ldir/secret" names a path outside the repo root' "paths: a symlinked directory out of the root is refused"
check_contains "$OUT" '"- [exists] src/*.sh" names a glob' "paths: a glob is refused"
check_contains "$OUT" '"- [no-match] eval in src" names a directory' "paths: a directory is refused"
check_contains "$OUT" '"- [no-match] eval in fifo" names neither a regular file nor a directory: fifo; nothing was run' "paths: a FIFO is refused even when listed"
check_contains "$OUT" '"- [exists] ." names the repo root, not a path in it: .; nothing was checked' "paths: the repo root is refused"
case "$OUT" in
  *outside/secret:1*) check "leaked" "" "paths: no file outside the repo was read" ;;
  *) check "" "" "paths: no file outside the repo was read" ;;
esac

# --- a symlink resolving inside the root is checked like any path ---

run "## Code and instruction Markdown acceptance

### Mechanical

- [no-match] eval in inlink
- [no-match] eval in indir/b.sh
- [exists] inlink

## Files affected (floor)

- \`inlink\` (new)"
check "$RC" 3 "in-root symlinks: exit 3"
check_lines "$OUT" 2 "in-root symlinks: one gap per failing bullet"
check_contains "$OUT" '"- [no-match] eval in inlink" matches in a file the files-affected section does not list as update or delete: inlink:1' "in-root symlinks: a symlinked file is grepped"
check_contains "$OUT" '"- [no-match] eval in indir/b.sh" matches in a file the files-affected section does not list as update or delete: indir/b.sh:1' "in-root symlinks: a file under a symlinked directory is grepped"

# --- a hostile ERE is a pattern, never shell text ---------------------

run "## Code and instruction Markdown acceptance

### Mechanical

- [no-match] \$(touch $SANDBOX/pwned4)|\`touch $SANDBOX/pwned5\`|a;b in src/semi.txt
- [no-match] -f/dev/null|x;touch $SANDBOX/pwned6 in src/semi.txt

$FILES_ALL"
check "$RC" 3 "hostile ERE: exit 3"
check_contains "$OUT" 'matches in a file the files-affected section does not list as update or delete: src/semi.txt:1' "hostile ERE: matched by grep -E as a pattern"
check_lines "$OUT" 1 "hostile ERE: an ERE starting with '-' is no option"
no_marker "hostile ERE"

run "## Code and instruction Markdown acceptance

### Mechanical

- [no-match] ( in src/a.sh

$FILES_ALL"
check "$RC" 3 "invalid ERE: exit 3"
check_contains "$OUT" '"- [no-match] ( in src/a.sh" has an ERE grep rejects' "invalid ERE: a gap"

# --- the grammar: fences, wrapped bullets, sections -------------------

run "## Code and instruction Markdown acceptance

### Semantic

\`\`\`markdown
## Code and instruction Markdown acceptance

### Mechanical

- [run] touch $SANDBOX/pwned7
\`\`\`

- touch $SANDBOX/pwned8

### Mechanical

- [no-match] eval in src/a.sh
  src/b.sh

## Notes

- [run] touch $SANDBOX/pwned9

$FILES_ALL"
check "$RC" 3 "grammar: exit 3"
check "$OUT" 'No unanswered design decisions: Mechanical bullet "- [no-match] eval in src/a.sh src/b.sh" matches in a file the files-affected section does not list as update or delete: src/b.sh:1' "grammar: a wrapped bullet is joined, and only Mechanical bullets outside a fence are graded"
no_marker "grammar"

run "## Code and instruction Markdown acceptance

### Semantic

\`\`\`markdown
~~~
### Mechanical
- [run] touch $SANDBOX/pwned10
\`\`\`

\`\`\`\`markdown
\`\`\`
### Mechanical
- [run] touch $SANDBOX/pwned11
\`\`\`\`

- anything

### Mechanical

- [no-match] eval in src/b.sh

$FILES_ALL"
check "$RC" 3 "nested fences: exit 3"
check "$OUT" 'No unanswered design decisions: Mechanical bullet "- [no-match] eval in src/b.sh" matches in a file the files-affected section does not list as update or delete: src/b.sh:1' "nested fences: a different or shorter marker does not close a fence"
no_marker "nested fences"

# --- every line under Mechanical is a bullet or its continuation ------

run "## Code and instruction Markdown acceptance

### Mechanical

  [exists] src/indented-first.sh
- [exists] src/a.sh
  continued
* [exists] src/star.sh
-[exists] src/nospace.sh
1. [exists] src/numbered.sh
-
-$SP
Prose about touch $SANDBOX/pwned13.

  [exists] src/indented-after-blank.sh
#### Deeper
\`\`\`
- [run] touch $SANDBOX/pwned14
\`\`\`

$FILES_ALL"
check "$RC" 3 "malformed lines: exit 3"
check_lines "$OUT" 11 "malformed lines: one gap per malformed line, none for a well-formed bullet"
check_contains "$OUT" 'Acceptance criteria: Mechanical line "  [exists] src/indented-first.sh" is not a "- " bullet or an indented continuation of one; nothing was run' "malformed lines: an indented line before any bullet"
check_contains "$OUT" '"- [exists] src/a.sh continued" is malformed for [exists]' "malformed lines: an indented line after a bullet continues it"
check_contains "$OUT" 'Mechanical line "* [exists] src/star.sh" is not a "- " bullet' "malformed lines: a '*' bullet"
check_contains "$OUT" 'Mechanical line "-[exists] src/nospace.sh" is not a "- " bullet' "malformed lines: '-' with no space"
check_contains "$OUT" 'Mechanical line "1. [exists] src/numbered.sh" is not a "- " bullet' "malformed lines: a numbered item"
check_contains "$OUT" 'Mechanical line "-" is not a "- " bullet' "malformed lines: a bare '-'"
check_contains "$OUT" 'Mechanical line "- " is not a "- " bullet' "malformed lines: a '- ' with no text is not a bullet"
check_contains "$OUT" "Mechanical line \"Prose about touch $SANDBOX/pwned13.\" is not a \"- \" bullet" "malformed lines: a prose line"
check_contains "$OUT" 'Mechanical line "  [exists] src/indented-after-blank.sh" is not a "- " bullet' "malformed lines: an indented line after a blank line continues nothing"
check_contains "$OUT" 'Mechanical line "#### Deeper" is not a "- " bullet' "malformed lines: a deeper heading"
check_contains "$OUT" 'Mechanical line "```" is not a "- " bullet' "malformed lines: a fence opening under Mechanical, its content unread"
no_marker "malformed lines"

# --- a section with only Semantic bullets has no Mechanical line ------

run "## Code and instruction Markdown acceptance

### Semantic

- anything

$FILES_ALL"
check "$RC" 0 "no Mechanical section: exit 0"
check "$OUT" "" "no Mechanical section: no gap line"

# --- both acceptance sections are graded, and `## Acceptance` is not ---

run "## Code and instruction Markdown acceptance

### Mechanical

- [exists] src/code.sh

## Documentation acceptance

### Mechanical

- [exists] docs/guide.md

## Acceptance

### Mechanical

- [run] touch $SANDBOX/pwned12
- [exists] src/retired.sh

$FILES_ALL"
check "$RC" 3 "sections: exit 3"
check_lines "$OUT" 2 "sections: one gap per failing bullet of the two sections, none for ## Acceptance"
check_contains "$OUT" '"- [exists] src/code.sh" names a file the files-affected section does not list: src/code.sh' "sections: a failing bullet under the code section is graded"
check_contains "$OUT" '"- [exists] docs/guide.md" names a file the files-affected section does not list: docs/guide.md' "sections: a failing bullet under the documentation section is graded"
no_marker "sections"

run "## Documentation acceptance

### Mechanical

- [no-match] eval in src/b.sh

$FILES_ALL"
check "$RC" 3 "documentation section alone: exit 3"
check "$OUT" 'No unanswered design decisions: Mechanical bullet "- [no-match] eval in src/b.sh" matches in a file the files-affected section does not list as update or delete: src/b.sh:1' "documentation section alone: its [no-match] bullet is executed like the code section's"

# --- section presence -------------------------------------------------

run "## Documentation acceptance

### Semantic

- the guide names the new flag

$FILES_ALL"
check "$RC" 0 "documentation-only body: exit 0"
check "$OUT" "" "documentation-only body: no gap line"

run "## Acceptance

### Mechanical

- [exists] src/a.sh

$FILES_ALL"
check "$RC" 3 "neither section: exit 3"
check "$OUT" 'Acceptance criteria: the body carries neither "## Code and instruction Markdown acceptance" nor "## Documentation acceptance"' "neither section: one gap naming both headings"

run "## Code and instruction Markdown acceptance

### Notes

- not a criterion

## Documentation acceptance

### Mechanical

### Semantic

-$SP

$FILES_ALL"
check "$RC" 3 "sections with no bullet: exit 3"
check_lines "$OUT" 2 "sections with no bullet: one gap per section with no bullet"
check_contains "$OUT" 'Acceptance criteria: "## Code and instruction Markdown acceptance" carries no bullet under "### Mechanical" or "### Semantic"' "sections with no bullet: a bullet under another sub-heading does not count"
check_contains "$OUT" 'Acceptance criteria: "## Documentation acceptance" carries no bullet under "### Mechanical" or "### Semantic"' "sections with no bullet: a bullet with no text does not count"

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
# An empty body is itself a gap, so this case serves a body that passes,
# leaving the '#' as the one thing exit 0 can rest on.
printf '## Documentation acceptance\n\n### Semantic\n\n- anything\n' >"$SANDBOX/body.md"
OUT=$(cd "$REPO" && PATH="$SANDBOX/bin:$PATH" "$CHECK" '#7' 2>"$SANDBOX/err")
check "$?" 0 "a leading '#' is accepted"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All cases passed."
else
  echo "$FAILURES case(s) failed."
  exit 1
fi
