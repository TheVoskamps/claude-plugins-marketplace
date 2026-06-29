#!/bin/sh
# PreToolUse hook for the agent-spawning tool (Agent, aka Task on older
# Claude Code versions). Denies the spawn unless run_in_background is
# explicitly false.
#
# Why: a background subagent runs detached from the interactive session, so
# any permission request it raises cannot bubble up to the user. The agent
# then halts silently instead of proceeding. The hook can only see one field
# (tool_input.run_in_background), and explicit `false` is the single input
# state with no observed background counterexample. So the predicate requires
# that exact value: every caller must declare run_in_background=false to spawn
# in the foreground. Absent / null / true / any other value is denied.
#
# This is an advisory policy guard, not a security boundary. It fails CLOSED:
# malformed or empty stdin cannot yield an explicit `false`, so it is denied.
# Failing closed matches the require-explicit-false spirit — an unparseable or
# silent input is exactly the "caller said nothing" case the inversion denies.
# The cost of a false deny is a cheap re-spawn with an explicit flag.

stdin="$(cat)"

run_in_background="$(printf '%s' "$stdin" | jq -r '.tool_input.run_in_background' 2>/dev/null)"

if [ "$run_in_background" = "false" ]; then
  exit 0
fi

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Background agents are blocked by policy. A background subagent runs detached from the interactive session, so any permission request it raises cannot bubble up to you — the agent will halt instead of proceeding. This guard requires every spawn to declare foreground intent explicitly: re-spawn this agent with `run_in_background: false`. An absent, null, or `true` value (or malformed input) is denied."
  }
}
JSON

exit 0
