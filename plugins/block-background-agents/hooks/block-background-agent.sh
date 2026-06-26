#!/bin/sh
# PreToolUse hook for the agent-spawning tool (Agent, aka Task on older
# Claude Code versions). Denies the spawn when run_in_background is true.
#
# Why: a background subagent runs detached from the interactive session, so
# any permission request it raises cannot bubble up to the user. The agent
# then halts silently instead of proceeding. Foreground spawns pass through.
#
# This is an advisory policy guard, not a security boundary, so it fails open:
# malformed or empty stdin yields run_in_background=false -> allow.

stdin="$(cat)"

run_in_background="$(printf '%s' "$stdin" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)"

if [ "$run_in_background" = "true" ]; then
  cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Background agents are blocked by policy. A background subagent runs detached from the interactive session, so any permission request it raises cannot bubble up to you — the agent will halt instead of proceeding. Re-spawn this agent in the foreground (omit `run_in_background` or set it to `false`)."
  }
}
JSON
  exit 0
fi

exit 0
