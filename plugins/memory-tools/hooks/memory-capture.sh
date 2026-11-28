#!/usr/bin/env bash
#
# memory-capture.sh -- PostToolUse hook (matcher: Write|Edit): record a
# successful write into a memory directory as one YAML file under
# ${XDG_STATE_HOME:-$HOME/.local/state}/memory-tools/<host>/<owner>/<repo>/,
# named <stamp>-<tool-use-id>.yml, <stamp> being the UTC capture time as
# YYYYMMDDTHHMMSSZ, and rendered by memory-record.jq beside this script.
# The memory directories, with <config> being
# CLAUDE_CONFIG_DIR when set and non-empty and ~/.claude otherwise:
#
#   agent-user     <config>/agent-memory/<agent>/
#   auto           <config>/projects/<project>/memory/, or autoMemoryDirectory
#   agent-local    <dir>/.claude/agent-memory-local/<agent>/
#   agent-project  <dir>/.claude/agent-memory/<agent>/
#
# They are matched in that order, so a file under ~/.claude/agent-memory/
# is agent-user although it also has the agent-project shape, with <dir>
# being the home directory.
#
# <host>/<owner>/<repo> comes from the origin remote of the directory
# holding the file for the agent-project and agent-local kinds, and of the
# hook's cwd for the other two; with no parseable origin nothing is
# recorded. A failed call, whose tool_response is a string, is not
# recorded either.
#
# The hook only observes: it prints nothing, emits no hookSpecificOutput,
# and exits 0 on every input, malformed JSON included, so a failure to
# record loses the entry and nothing else. Runs under the bash 3.2 macOS
# ships.
set -u

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

# field <jq-path> -- print the string at <jq-path> in the hook input, or
# nothing when it is absent, not a string, or the input is not JSON.
field() {
  printf '%s' "$input" | jq -j "$1 | strings" 2>/dev/null
}

[ "$(printf '%s' "$input" | jq -r '.tool_response | type' 2>/dev/null)" = object ] || exit 0

tool=$(field .tool_name)
file_path=$(field .tool_input.file_path)
cwd=$(field .cwd)
session_id=$(field .session_id)
tool_use_id=$(field .tool_use_id)

case $tool in Write | Edit) ;; *) exit 0 ;; esac
case $file_path in /*) ;; *) exit 0 ;; esac
case $cwd in /*) ;; *) exit 0 ;; esac
# The id becomes part of a file name.
case $tool_use_id in '' | *[!A-Za-z0-9_-]*) exit 0 ;; esac

config=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}
config=${config%/}

# auto_memory_directory -- print the autoMemoryDirectory the first of the
# local, project and user settings files sets, a leading ~ expanded and a
# trailing slash dropped, or nothing when none sets it.
auto_memory_directory() {
  local settings value
  for settings in "$cwd/.claude/settings.local.json" "$cwd/.claude/settings.json" "$config/settings.json"; do
    [ -f "$settings" ] || continue
    value=$(jq -j '.autoMemoryDirectory | strings' "$settings" 2>/dev/null)
    [ -n "$value" ] || continue
    case $value in
      \~) value=${HOME:-} ;;
      \~/*) value=${HOME:-}/${value#\~/} ;;
    esac
    printf '%s' "${value%/}"
    return
  done
}

auto_dir=$(auto_memory_directory)
file_dir=$(dirname "$file_path")

kind=
case $file_path in
  "$config"/agent-memory/?*/?*) kind=agent-user ;;
  "$config"/projects/?*/memory/?*) kind=auto ;;
esac
if [ -z "$kind" ] && [ -n "$auto_dir" ]; then
  case $file_path in "$auto_dir"/?*) kind=auto ;; esac
fi
if [ -z "$kind" ]; then
  case $file_path in
    */.claude/agent-memory-local/?*/?*) kind=agent-local ;;
    */.claude/agent-memory/?*/?*) kind=agent-project ;;
    *) exit 0 ;;
  esac
fi

case $kind in
  agent-local | agent-project) repo_dir=$file_dir ;;
  *) repo_dir=$cwd ;;
esac
url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null) || exit 0

# Reduce the URL to a host and a path for the https://, ssh:// and
# scp-like user@host:path forms, dropping a user, a port and a trailing
# .git.
case $url in
  *://*)
    rest=${url#*://}
    host=${rest%%/*}
    path=${rest#*/}
    [ "$path" != "$rest" ] || exit 0
    ;;
  *:*)
    host=${url%%:*}
    path=${url#*:}
    ;;
  *) exit 0 ;;
esac
host=${host##*@}
host=${host%%:*}
path=${path%/}
path=${path%.git}
case $path in */*) ;; *) exit 0 ;; esac
repo=${path##*/}
owner=${path%/*}
owner=${owner##*/}
for part in "$host" "$owner" "$repo"; do
  case $part in '' | . | .. | *[!A-Za-z0-9._-]*) exit 0 ;; esac
done

branch=$(git -C "$file_dir" branch --show-current 2>/dev/null)

stamp=$(date -u +%Y%m%dT%H%M%SZ)
captured_at="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z"

state_dir="${XDG_STATE_HOME:-${HOME:-}/.local/state}/memory-tools/$host/$owner/$repo"
case $state_dir in /*) ;; *) exit 0 ;; esac
mkdir -p "$state_dir" 2>/dev/null || exit 0
tmp=$(mktemp "$state_dir/.record.XXXXXX" 2>/dev/null) || exit 0
content=$tmp.content

# A Write carries the whole file; an Edit's result is read back from disk.
if [ "$tool" = Write ]; then
  printf '%s' "$input" | jq -j '.tool_input.content | strings' >"$content" 2>/dev/null
  wrote=$?
else
  cat "$file_path" >"$content" 2>/dev/null
  wrote=$?
fi

[ "$wrote" -eq 0 ] &&
  jq -n -j \
    --arg kind "$kind" \
    --arg source_path "$file_path" \
    --arg tool "$tool" \
    --arg session_id "$session_id" \
    --arg branch "$branch" \
    --arg captured_at "$captured_at" \
    --rawfile content "$content" \
    -f "$(dirname "${BASH_SOURCE[0]}")/memory-record.jq" >"$tmp" 2>/dev/null &&
  mv -f "$tmp" "$state_dir/$stamp-$tool_use_id.yml" 2>/dev/null
# After a successful mv the temporary file is already gone.
rm -f "$tmp" "$content"
exit 0
