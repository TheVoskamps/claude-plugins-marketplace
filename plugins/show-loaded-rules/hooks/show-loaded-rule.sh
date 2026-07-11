#!/bin/sh
# InstructionsLoaded hook: surfaces a one-line message for every CLAUDE.md /
# .claude/rules/*.md file loaded into context, so the user can see which
# rules files are in play without running --verbose.
#
# InstructionsLoaded is observe-only (no decision control, exit code is
# ignored) and fires once per file loaded, both at session start and on
# lazy loads during the session (nested traversal, glob match, include,
# compaction). Plain stdout is not surfaced to the user for this event —
# only the `systemMessage` field in the JSON hook output is, so that is
# the only way to make the loaded file visible in normal (non-verbose)
# mode.
#
# Malformed / empty stdin: jq failures fall back to empty strings so the
# hook still emits a (less specific) message instead of erroring out. This
# is purely observational, so failing loud would add noise for no benefit.

stdin="$(cat)"

file_path="$(printf '%s' "$stdin" | jq -r '.file_path // "(unknown file)"' 2>/dev/null)"
load_reason="$(printf '%s' "$stdin" | jq -r '.load_reason // "unknown"' 2>/dev/null)"

[ -z "$file_path" ] && file_path="(unknown file)"
[ -z "$load_reason" ] && load_reason="unknown"

message="Rules loaded: ${file_path} (${load_reason})"

jq -n --arg msg "$message" '{systemMessage: $msg}' 2>/dev/null

exit 0
