#!/bin/sh
# PreToolUse hook (matcher: Agent|Task): surfaces the agent type, key
# parameters, and the full prompt every time the model spawns a subagent,
# so the user can see what was delegated without running --verbose.
#
# Event/matcher choice (see docs/hook-event-notes.md for the full write-up):
# the purpose-built SubagentStart event carries only agent_id and
# agent_type per the official hooks docs (https://code.claude.com/docs/en/hooks)
# - not the prompt, description, model, or spawn parameters - so it cannot
# satisfy "with what parameters and what prompt". The spawn parameters live
# only in the tool call's tool_input, which is visible on PreToolUse. The
# repo's block-background-agents plugin already registers PreToolUse with
# matcher Agent|Task and demonstrably fires and reads
# tool_input.run_in_background, proving this event+matcher matches the spawn
# tool on the current Claude Code version. Matching both Agent and Task is
# harmless if only one name is live.
#
# The official docs do not publish a field-by-field schema for the spawn
# tool's tool_input. tool_input.run_in_background is the only
# doc/empirically-confirmed field (via block-background-agents); the other
# field names read below (subagent_type, agentType, description, model,
# isolation, prompt) are inferred from the Agent tool's own parameter
# schema, exactly the same doc-gap inference show-loaded-skills already
# documents for tool_input.skill. Update this comment and
# docs/hook-event-notes.md together if a future run observes the actual
# field names (e.g. via --debug transcript output).
#
# This hook is display-only: PreToolUse supports hookSpecificOutput with
# permissionDecision (allow/deny/ask) and updatedInput, but this plugin must
# never touch the permission flow - block-background-agents fires on the
# same event/matcher and this hook must not disturb it. The script only
# ever emits systemMessage and always exits 0 without hookSpecificOutput.
#
# Malformed / empty stdin: jq failures fall back to placeholders so the
# hook still emits a (less specific) message instead of erroring out. This
# is purely observational, so failing loud would add noise for no benefit.

stdin="$(cat)"

subagent_type="$(printf '%s' "$stdin" | jq -r '.tool_input.subagent_type // .tool_input.agentType // "(unknown agent)"' 2>/dev/null)"
[ -z "$subagent_type" ] && subagent_type="(unknown agent)"

description="$(printf '%s' "$stdin" | jq -r '.tool_input.description // empty' 2>/dev/null)"

model="$(printf '%s' "$stdin" | jq -r '.tool_input.model // "(default model)"' 2>/dev/null)"
[ -z "$model" ] && model="(default model)"

run_in_background="$(printf '%s' "$stdin" | jq -r '.tool_input.run_in_background // empty' 2>/dev/null)"

isolation="$(printf '%s' "$stdin" | jq -r '.tool_input.isolation // empty' 2>/dev/null)"

prompt="$(printf '%s' "$stdin" | jq -r '.tool_input.prompt // "(no prompt)"' 2>/dev/null)"
[ -z "$prompt" ] && prompt="(no prompt)"

message="Agent spawned: ${subagent_type} (model: ${model})"

[ -n "$description" ] && message="${message}
Description: ${description}"

[ -n "$run_in_background" ] && message="${message}
Background: ${run_in_background}"

[ -n "$isolation" ] && message="${message}
Isolation: ${isolation}"

message="${message}

Prompt:
${prompt}"

jq -n --arg msg "$message" '{systemMessage: $msg}' 2>/dev/null

exit 0
