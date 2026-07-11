#!/bin/sh
# UserPromptExpansion hook: surfaces a one-line message every time a
# user-typed command (e.g. /my-skill) expands into a prompt, so the user
# can see which skill loaded via this path without running --verbose.
#
# UserPromptExpansion input carries command_name, command_args, and
# expanded_prompt in addition to the common fields (session_id, prompt_id,
# transcript_path, cwd, hook_event_name). See
# https://code.claude.com/docs/en/hooks - "UserPromptExpansion input".
#
# This hook is display-only: UserPromptExpansion supports a top-level
# decision: "block" to stop the expansion, but this plugin must never
# block a skill invocation, so the script never emits `decision`.
#
# Malformed / empty stdin: jq failures fall back to a placeholder so the
# hook still emits a (less specific) message instead of erroring out. This
# is purely observational, so failing loud would add noise for no benefit.

stdin="$(cat)"

command_name="$(printf '%s' "$stdin" | jq -r '.command_name // "(unknown skill)"' 2>/dev/null)"

[ -z "$command_name" ] && command_name="(unknown skill)"

message="Skill loaded: ${command_name} (typed command)"

jq -n --arg msg "$message" '{systemMessage: $msg}' 2>/dev/null

exit 0
