# block-background-agents

A single-purpose policy guardrail: a `PreToolUse` hook that **denies
background agent spawns**.

## What it does

When the main session spawns a subagent with `run_in_background: true`,
the hook denies the call and returns a reason telling the model to spawn
the agent in the foreground instead. Foreground spawns
(`run_in_background` absent or `false`) pass through untouched.

## Why

A background subagent runs detached from the interactive session, which
means **any permission request it raises cannot bubble up to the user**.
When such an agent hits an ask-list command (or any prompt-gated action),
the prompt has nowhere to surface, so the agent silently stalls — it
neither proceeds nor reports a clear, actionable reason.

This is the same failure class documented for `SendMessage`-resumption in
`~/.claude/rules/foreground-vs-background.md`, but here the trigger is the
*initial* background spawn rather than resumption.

This plugin is deliberately separate from the compiled `guardrails`
permission-gate so it stays a small, auditable shell hook.

## How it works

`hooks/hooks.json` registers a `PreToolUse` hook matched to the
agent-spawning tool:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Agent|Task",
        "hooks": [
          { "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/block-background-agent.sh",
            "timeout": 10 }
        ]
      }
    ]
  }
}
```

`hooks/block-background-agent.sh` (POSIX `sh` + `jq`) reads the hook
stdin JSON, extracts `tool_input.run_in_background`, and — when it is
`true` — emits a structured `permissionDecision: deny` with an
explanatory reason. Otherwise it exits 0 with no output (allow).

A hook `matcher` filters by **tool name only**, not by arguments, so the
matcher catches *every* agent spawn and the hook body distinguishes
foreground from background by reading the background flag from stdin.

The hook fails open: malformed or empty stdin yields
`run_in_background = false` → allow. This is an advisory policy guard,
not a security boundary.

## Tool-name caveat

The runtime `tool_name` for agent spawns is **`Agent`** (renamed from
`Task` in Claude Code v2.1.63 — see GitHub issue
[anthropics/claude-code#29677](https://github.com/anthropics/claude-code/issues/29677)).
The matcher uses `Agent|Task` so the hook fires on both current and older
Claude Code versions.
