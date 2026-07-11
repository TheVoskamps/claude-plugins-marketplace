#!/bin/sh
# PreToolUse hook (matcher: Skill): surfaces a one-line message every time
# the model invokes a skill via the Skill tool, so the user can see which
# skill loaded via this path without running --verbose.
#
# The official hooks docs (https://code.claude.com/docs/en/hooks) document
# PreToolUse's common tool_input shape but do not publish a field-by-field
# schema for the Skill tool specifically. The Skill tool's own parameter
# schema names its skill identifier "skill" and its optional arguments
# "args", so tool_input.skill is tried first; tool_input.name is tried as
# a fallback in case a future/older Claude Code build uses that key
# instead. Update this list if the docs later publish the authoritative
# field name (tracked in docs/hook-event-notes.md).
#
# This hook is display-only: PreToolUse supports hookSpecificOutput with
# permissionDecision (allow/deny/ask) and updatedInput, but this plugin
# must never touch the permission flow, so the script only ever emits
# systemMessage and always exits 0 without a permissionDecision.
#
# Malformed / empty stdin: jq failures fall back to a placeholder so the
# hook still emits a (less specific) message instead of erroring out. This
# is purely observational, so failing loud would add noise for no benefit.

stdin="$(cat)"

skill_name="$(printf '%s' "$stdin" | jq -r '.tool_input.skill // .tool_input.name // "(unknown skill)"' 2>/dev/null)"

[ -z "$skill_name" ] && skill_name="(unknown skill)"

message="Skill loaded: ${skill_name} (model-invoked)"

jq -n --arg msg "$message" '{systemMessage: $msg}' 2>/dev/null

exit 0
