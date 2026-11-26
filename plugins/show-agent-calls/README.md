# show-agent-calls

A single-purpose observability hook: a `PreToolUse` hook (matcher
`Agent|Task`) that **surfaces the agent type, parameters, and the full
prompt** every time the model spawns a subagent.

## What it does

In a normal (non-`--verbose`) session, spawning a subagent — an
`Explore`, `Plan`, `general-purpose`, or `sdlc:*` agent — is invisible
beyond "an agent ran". This plugin prints a multi-line message on every
spawn:

```text
Agent spawned: Explore (model: sonnet)
Description: find X

Prompt:
line one
line two
line three
```

The prompt is shown **in full, verbatim** — not truncated to a first
line. That is a deliberate departure from the one-line style of the
sibling plugins below: the full delegated prompt is exactly the
interesting part for "why did that subagent do X" trust and debugging
questions.

## Why

Sibling observability plugins cover adjacent surfaces but not this one:

- `show-loaded-rules` surfaces
  CLAUDE.md / `.claude/rules/*.md` loads via `InstructionsLoaded`.
- `show-loaded-skills` surfaces
  skill loads via `UserPromptExpansion` and `PreToolUse(Skill)`.

Neither fires for a subagent spawn, so this plugin fills that gap.

### Why not `SubagentStart`?

The purpose-built `SubagentStart` event was considered and rejected.
Per the official hooks docs (<https://code.claude.com/docs/en/hooks>)
it carries only `agent_id` and `agent_type` — not the prompt,
description, model, or spawn parameters. It cannot satisfy "with what
parameters and what prompt", which is the whole point of this plugin.

### Why `PreToolUse` with matcher `Agent|Task`

The spawn parameters live only in the tool call's `tool_input`, which
is visible on `PreToolUse`. The matcher names both `Agent` and `Task`
so the hook fires whichever name the spawn tool carries on a given
Claude Code build.

## How it works

`hooks/hooks.json` registers one hook:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Agent|Task",
        "hooks": [
          { "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/show-agent-call.sh",
            "timeout": 10 }
        ]
      }
    ]
  }
}
```

`hooks/show-agent-call.sh` (POSIX `sh` + `jq`) reads the `PreToolUse`
stdin JSON and extracts, each with a fallback so a wrong/absent field
never breaks the hook:

- `subagent_type` (fallback `tool_input.agentType`, then
  `(unknown agent)`)
- `description` (fallback empty — omitted from the message when empty)
- `model` (fallback `(default model)`)
- `run_in_background` (fallback empty — omitted when empty)
- `isolation` (fallback empty — omitted when empty)
- `prompt` — the full value, verbatim, no truncation (fallback
  `(no prompt)`)

It then emits a single `systemMessage` JSON field containing a header
line, the optional detail lines, and the full prompt under a `Prompt:`
heading.

### Display-only guarantee

This hook is **display-only**: `PreToolUse` supports
`hookSpecificOutput.permissionDecision` (allow/deny/ask) and
`updatedInput`, but this plugin never emits `hookSpecificOutput` — only
`systemMessage`. This matters because `block-background-agents`
registers a hook on the exact same event and matcher; since this
plugin never touches the permission-decision channel, the two compose
without interference regardless of registration order.

### Malformed / empty stdin

If stdin is empty or not valid JSON, the script falls back to the
placeholders above (`(unknown agent)`, `(default model)`,
`(no prompt)`) rather than erroring out, and always exits `0`. This
hook is purely observational, so a best-effort message beats a hard
failure.

## Scope

This plugin only covers subagent-spawn visibility. Skill loads and
rules/instruction-file loads are separate concerns, covered by
`show-loaded-skills` and `show-loaded-rules` respectively.
