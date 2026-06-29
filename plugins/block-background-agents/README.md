# block-background-agents

A single-purpose policy guardrail: a `PreToolUse` hook that **denies any
agent spawn that does not explicitly request the foreground**.

## What it does

The hook allows a subagent spawn **only** when `run_in_background` is
explicitly `false`. Every other input state — `run_in_background` absent,
`null`, `true`, any other value, or malformed/empty stdin — is denied,
and the deny reason tells the model to re-spawn with an explicit
`run_in_background: false`.

This is a deliberate inversion of the older "deny only when `true`"
predicate. That version defaulted to *allow* whenever the field was
absent, which could not distinguish "the caller deliberately asked for
the foreground" from "the caller said nothing and the call backgrounded
anyway." Explicit `false` is the one input state with no observed
background counterexample, so requiring it is the strongest guard the
hook's single field (`tool_input.run_in_background`) can support.

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
stdin JSON and extracts `tool_input.run_in_background`. When that value
is exactly `false` it exits 0 with no output (allow); for every other
value it emits a structured `permissionDecision: deny` with an
explanatory reason.

A hook `matcher` filters by **tool name only**, not by arguments, so the
matcher catches *every* agent spawn and the hook body distinguishes the
explicit-foreground case from everything else by reading the background
flag from stdin.

### Malformed / empty stdin: the hook fails CLOSED

This is the deliberate counterpart to the require-explicit-`false`
predicate. Earlier versions of this hook failed *open* — malformed or
empty stdin was coerced to `run_in_background = false` and allowed. Under
the inverted predicate that would defeat the point: an unparseable or
silent input is exactly the "caller said nothing" case the inversion is
meant to deny.

So when stdin is empty or not valid JSON, `jq` produces no `false` value
and the spawn is **denied**. The cost of a false deny is cheap — the
model re-spawns with an explicit `run_in_background: false` — whereas a
false *allow* reintroduces the silent-stall failure this plugin exists to
prevent.

This remains an advisory policy guard, not a security boundary.

## Tool-name caveat

The runtime `tool_name` for agent spawns is **`Agent`** (renamed from
`Task` in Claude Code v2.1.63 — see GitHub issue
[anthropics/claude-code#29677](https://github.com/anthropics/claude-code/issues/29677)).
The matcher uses `Agent|Task` so the hook fires on both current and older
Claude Code versions.
