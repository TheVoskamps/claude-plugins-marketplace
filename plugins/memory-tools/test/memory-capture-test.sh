#!/usr/bin/env bash
#
# memory-capture-test.sh -- replay synthetic PostToolUse events against
# plugins/memory-tools/hooks/memory-capture.sh in a sandbox of git repos
# and config directories, and check which calls leave a record, where, and
# what it holds. Needs jq and mikefarah yq on PATH.
#
# Usage: memory-capture-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$TEST_DIR/../hooks/memory-capture.sh"
FAILURES=0

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/memory-capture-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

HOME_DIR="$SANDBOX/home"
STATE="$SANDBOX/state"
CFG="$SANDBOX/cfg"
REPO="$SANDBOX/repo"
NO_ORIGIN="$SANDBOX/no-origin"
RECORDS="$STATE/memory-tools/github.com/o/r"
mkdir -p "$HOME_DIR/.claude" "$CFG" "$REPO/.claude" "$NO_ORIGIN"

git -C "$REPO" init -q -b work
git -C "$REPO" remote add origin git@github.com:o/r.git
git -C "$NO_ORIGIN" init -q -b work

pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1"
  shift
  local line
  for line in "$@"; do echo "      $line"; done
  FAILURES=$((FAILURES + 1))
}

# event <tool> <file-path> <cwd> [<content>] -- print a PostToolUse event
# for a successful call. A Write carries <content>, and writes it to
# <file-path> first, as the tool has by the time the hook runs.
event() {
  if [ "$1" = Write ]; then
    mkdir -p "${2%/*}"
    printf '%s' "${4-}" >"$2"
  fi
  jq -n -c --arg tool "$1" --arg path "$2" --arg cwd "$3" --arg content "${4-}" '{
    session_id: "s-1", cwd: $cwd, hook_event_name: "PostToolUse", tool_name: $tool,
    tool_input: (if $tool == "Write" then {file_path: $path, content: $content}
      else {file_path: $path, old_string: "a", new_string: "b"} end),
    tool_response: {filePath: $path}, tool_use_id: "toolu_01"
  }'
}

# run_hook <label> <stdin> [<env-argument>…] -- run the hook on <stdin>
# with HOME and XDG_STATE_HOME pointed into the sandbox and
# CLAUDE_CONFIG_DIR unset, then the env arguments, and check it exits 0
# with no output. The state directory is emptied first.
run_hook() {
  local label=$1 stdin=$2 out status
  shift 2
  rm -rf "$STATE"
  out=$(printf '%s' "$stdin" | env -u CLAUDE_CONFIG_DIR HOME="$HOME_DIR" XDG_STATE_HOME="$STATE" "$@" "$HOOK" 2>&1)
  status=$?
  if [ "$status" -ne 0 ] || [ -n "$out" ]; then
    fail "$label: exits 0 with no output" "status: $status" "output: $out"
  fi
}

# record_files -- print every file under the state directory, one per line.
record_files() {
  [ -d "$STATE" ] || return 0
  find "$STATE" -type f | sort
}

# expect_record <label> <kind> <source-path> <tool> <branch> <content> --
# check that the last run left exactly one record, in the o/r directory and
# named <stamp>-toolu_01.yml, <stamp> being the capture time as
# YYYYMMDDTHHMMSSZ, holding every key in order, and that
# its content reads back from YAML as <content>.
expect_record() {
  local label=$1 kind=$2 source=$3 tool=$4 branch=$5 content=$6 files name stamp captured expected actual read_back
  files=$(record_files)
  name=${files##*/}
  if [ "$files" != "$RECORDS/$name" ]; then
    fail "$label" "expected one record under $RECORDS" "found: ${files:-none}"
    return
  fi
  if ! [[ $name =~ ^([0-9]{8}T[0-9]{6}Z)-toolu_01\.yml$ ]]; then
    fail "$label" "record name: $name"
    return
  fi
  stamp=${BASH_REMATCH[1]}
  captured="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z"
  expected=$(jq -n -r --arg kind "$kind" --arg source "$source" --arg tool "$tool" --arg branch "$branch" \
    --arg captured "$captured" --arg content "$content" \
    '[$kind, $source, $tool, "s-1", $branch, $captured, $content] | @json')
  actual=$(yq -o json -I 0 '[.kind, ."source-path", .tool, ."session-id", .branch, ."captured-at", .content]' "$files" 2>&1)
  # yq and jq escape DEL, U+2028 and U+2029 differently, so the read-back
  # is re-encoded by jq before the two are compared.
  actual=$(printf '%s' "$actual" | jq -c . 2>/dev/null || printf '%s' "$actual")
  read_back=$(yq -o json -I 0 'keys' "$files" 2>&1)
  if [ "$read_back" != '["kind","source-path","tool","session-id","branch","captured-at","content"]' ]; then
    fail "$label" "keys: $read_back"
  elif [ "$actual" != "$expected" ]; then
    fail "$label" "expected: $expected" "actual:   $actual"
  else
    pass "$label"
  fi
}

# expect_none <label> -- check that the last run left no record.
expect_none() {
  local files
  files=$(record_files)
  if [ -n "$files" ]; then
    fail "$1" "expected no record" "found: $files"
  else
    pass "$1"
  fi
}

# --- each kind ----------------------------------------------------------------

path="$REPO/.claude/agent-memory/issue-developer/MEMORY.md"
run_hook "agent-project" "$(event Write "$path" "$REPO" $'# Memory\n- one\n')"
expect_record "agent-project: a Write under <dir>/.claude/agent-memory/<agent>/" \
  agent-project "$path" Write work $'# Memory\n- one\n'

path="$REPO/.claude/agent-memory-local/style-checker/notes.md"
run_hook "agent-local" "$(event Write "$path" "$REPO" $'local\n')"
expect_record "agent-local: a Write under <dir>/.claude/agent-memory-local/<agent>/" \
  agent-local "$path" Write work $'local\n'

path="$HOME_DIR/.claude/agent-memory/docs-writer/MEMORY.md"
run_hook "agent-user" "$(event Write "$path" "$REPO" $'user\n')"
expect_record "agent-user: a Write under ~/.claude/agent-memory/<agent>/, repo from cwd" \
  agent-user "$path" Write "" $'user\n'

path="$HOME_DIR/.claude/projects/-repo/memory/MEMORY.md"
run_hook "auto" "$(event Write "$path" "$REPO" $'auto\n')"
expect_record "auto: a Write under ~/.claude/projects/<project>/memory/, repo from cwd" \
  auto "$path" Write "" $'auto\n'

# --- CLAUDE_CONFIG_DIR ---------------------------------------------------------

path="$CFG/agent-memory/docs-writer/MEMORY.md"
run_hook "agent-user under CLAUDE_CONFIG_DIR" "$(event Write "$path" "$REPO" $'cfg user\n')" CLAUDE_CONFIG_DIR="$CFG"
expect_record "agent-user: matched under a CLAUDE_CONFIG_DIR other than ~/.claude" \
  agent-user "$path" Write "" $'cfg user\n'

path="$CFG/projects/-repo/memory/MEMORY.md"
run_hook "auto under CLAUDE_CONFIG_DIR" "$(event Write "$path" "$REPO" $'cfg auto\n')" CLAUDE_CONFIG_DIR="$CFG"
expect_record "auto: matched under a CLAUDE_CONFIG_DIR other than ~/.claude" \
  auto "$path" Write "" $'cfg auto\n'

path="$HOME_DIR/.claude/projects/-repo/memory/MEMORY.md"
run_hook "auto under ~/.claude with CLAUDE_CONFIG_DIR set" "$(event Write "$path" "$REPO" x)" CLAUDE_CONFIG_DIR="$CFG"
expect_none "auto: ~/.claude/projects is no memory directory once CLAUDE_CONFIG_DIR names another"

# --- autoMemoryDirectory --------------------------------------------------------

LOCAL_SETTINGS="$REPO/.claude/settings.local.json"
PROJECT_SETTINGS="$REPO/.claude/settings.json"
USER_SETTINGS="$HOME_DIR/.claude/settings.json"

# settings <local-dir> <project-dir> <user-dir> -- set autoMemoryDirectory
# in the local, project and user settings files; an empty value leaves
# that file without the key.
settings() {
  local file value i=0
  for file in "$LOCAL_SETTINGS" "$PROJECT_SETTINGS" "$USER_SETTINGS"; do
    i=$((i + 1))
    value=${!i}
    if [ -n "$value" ]; then
      jq -n --arg dir "$value" '{autoMemoryDirectory: $dir}' >"$file"
    else
      echo '{"model": "opus"}' >"$file"
    fi
  done
}

settings "$SANDBOX/mem-local" "" ""
path="$SANDBOX/mem-local/a.md"
run_hook "autoMemoryDirectory in settings.local.json" "$(event Write "$path" "$REPO" $'l\n')"
expect_record "auto: under an autoMemoryDirectory set in <cwd>/.claude/settings.local.json" \
  auto "$path" Write "" $'l\n'

settings "" "$SANDBOX/mem-project/" ""
path="$SANDBOX/mem-project/a.md"
run_hook "autoMemoryDirectory in settings.json" "$(event Write "$path" "$REPO" $'p\n')"
expect_record "auto: under an autoMemoryDirectory set in <cwd>/.claude/settings.json, trailing slash and all" \
  auto "$path" Write "" $'p\n'

settings "" "" \~/mem-user
path="$HOME_DIR/mem-user/a.md"
run_hook "autoMemoryDirectory in the user settings" "$(event Write "$path" "$REPO" $'u\n')"
expect_record "auto: under an autoMemoryDirectory set in <config>/settings.json, ~ expanded" \
  auto "$path" Write "" $'u\n'

settings "$SANDBOX/mem-local" "$SANDBOX/mem-project" \~/mem-user
path="$SANDBOX/mem-local/a.md"
run_hook "local beats project and user" "$(event Write "$path" "$REPO" $'l\n')"
expect_record "auto: settings.local.json wins over settings.json and the user settings" \
  auto "$path" Write "" $'l\n'
run_hook "project loses to local" "$(event Write "$SANDBOX/mem-project/a.md" "$REPO" x)"
expect_none "auto: the directory settings.json names is ignored when settings.local.json names another"
run_hook "user loses to local" "$(event Write "$HOME_DIR/mem-user/a.md" "$REPO" x)"
expect_none "auto: the directory the user settings name is ignored when settings.local.json names another"

settings "" "$SANDBOX/mem-project" \~/mem-user
path="$SANDBOX/mem-project/a.md"
run_hook "project beats user" "$(event Write "$path" "$REPO" $'p\n')"
expect_record "auto: settings.json wins over the user settings" auto "$path" Write "" $'p\n'
run_hook "user loses to project" "$(event Write "$HOME_DIR/mem-user/a.md" "$REPO" x)"
expect_none "auto: the directory the user settings name is ignored when settings.json names another"

rm -f "$LOCAL_SETTINGS" "$PROJECT_SETTINGS" "$USER_SETTINGS"

# --- Edit ------------------------------------------------------------------------

path="$REPO/.claude/agent-memory/issue-fixer/MEMORY.md"
mkdir -p "${path%/*}"
printf 'after the edit\n' >"$path"
run_hook "Edit" "$(event Edit "$path" "$REPO")"
expect_record "Edit: the record holds the file's content read after the edit" \
  agent-project "$path" Edit work $'after the edit\n'

# --- content the block scalar has to carry exactly ---------------------------------

path="$REPO/.claude/agent-memory/issue-developer/MEMORY.md"
for content in "no trailing newline" $'two trailing\n\n' $'  leading spaces\nthen none\n' \
  $'\n\nleading blank lines\n' $'\n' $'key: value # not a comment\n' "" \
  $'crlf\r\nline\r\n' $'bell\a and escape\e\n' $'del\x7f\n' $'next line\xc2\x85here\n' \
  $'line\xe2\x80\xa8separator\n' $'paragraph\xe2\x80\xa9separator\n' $'c1\xc2\x9acontrol\n'; do
  run_hook "content $(jq -n -c --arg c "$content" '$c')" "$(event Write "$path" "$REPO" "$content")"
  expect_record "content $(jq -n -c --arg c "$content" '$c') reads back unchanged" \
    agent-project "$path" Write work "$content"
done

# --- branch names YAML would read as something other than a string -----------------

for branch in 0x1F 0o17 0b101 1_000 1e3 +1 2026-11-27 yes Null; do
  git -C "$REPO" symbolic-ref HEAD "refs/heads/$branch"
  run_hook "branch $branch" "$(event Write "$path" "$REPO" $'b\n')"
  expect_record "branch $branch reads back as a string" agent-project "$path" Write "$branch" $'b\n'
done
git -C "$REPO" symbolic-ref HEAD refs/heads/work

# --- calls that leave no record ---------------------------------------------------

run_hook "outside" "$(event Write "$REPO/src/notes.md" "$REPO" x)"
expect_none "no record: a Write outside every memory directory"

failed=$(event Write "$REPO/.claude/agent-memory/issue-developer/MEMORY.md" "$REPO" x |
  jq -c '.tool_response = "Error writing file"')
run_hook "failed" "$failed"
expect_none "no record: a failed call, whose tool_response is a string"

run_hook "no origin, agent-project" "$(event Write "$NO_ORIGIN/.claude/agent-memory/x/MEMORY.md" "$NO_ORIGIN" x)"
expect_none "no record: an agent-project Write in a repo with no origin remote"

run_hook "no origin, auto" "$(event Write "$HOME_DIR/.claude/projects/-no-origin/memory/MEMORY.md" "$NO_ORIGIN" x)"
expect_none "no record: an auto Write whose cwd has no origin remote"

run_hook "malformed" '{"tool_name": "Write", '
expect_none "no record: malformed JSON"

run_hook "empty" ''
expect_none "no record: empty input"

run_hook "Read" "$(event Write "$REPO/.claude/agent-memory/x/MEMORY.md" "$REPO" x | jq -c '.tool_name = "Read"')"
expect_none "no record: a tool other than Write or Edit"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
