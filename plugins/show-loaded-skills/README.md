# show-loaded-skills

A single-purpose observability hook pair: `UserPromptExpansion` and
`PreToolUse` (matcher `Skill`) hooks that **surface a one-line message for
every skill loaded**, covering both ways a skill can load — a user-typed
command and a model-initiated invocation.

## What it does

Claude Code loads a skill in two distinct ways:

- **Typed command**: you type `/my-skill` and it expands into a prompt
  before Claude sees it. `UserPromptExpansion` fires for this path.
- **Model invocation**: Claude decides to call a skill through the `Skill`
  tool. `PreToolUse` with matcher `Skill` fires for this path.

Normally both loads are invisible unless you run with `--verbose`. This
plugin makes each visible in a normal session by printing a short
`Skill loaded: <name> (<how>)` message for every firing, on either path.

## Why

Knowing which skill just loaded — and whether you typed it or Claude
chose it — is useful for debugging "why is Claude doing X" questions and
for building trust that the right skill actually ran. Sibling plugin
[`show-loaded-rules`](../show-loaded-rules/README.md) covers the analogous
question for CLAUDE.md / rules files via `InstructionsLoaded`; this
plugin covers skills specifically, since `InstructionsLoaded` does not
fire for skill loads.

## How it works

`hooks/hooks.json` registers two hooks:

```json
{
  "hooks": {
    "UserPromptExpansion": [
      {
        "hooks": [
          { "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/show-loaded-skill-command.sh",
            "timeout": 10 }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Skill",
        "hooks": [
          { "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/show-loaded-skill-tool.sh",
            "timeout": 10 }
        ]
      }
    ]
  }
}
```

`hooks/show-loaded-skill-command.sh` (POSIX `sh` + `jq`) reads the
`UserPromptExpansion` stdin JSON, extracts `command_name`, and emits a
`systemMessage` JSON field:

```text
Skill loaded: review-pr (typed command)
```

`hooks/show-loaded-skill-tool.sh` reads the `PreToolUse` stdin JSON,
extracts the skill identifier from `tool_input` (`tool_input.skill`,
falling back to `tool_input.name` — see the in-script comment; the
official hooks docs don't publish a field-by-field schema for the
`Skill` tool's `tool_input`, so this was inferred from the `Skill` tool's
own parameter schema, which names the identifier `skill`), and emits the
analogous message:

```text
Skill loaded: review-pr (model-invoked)
```

Both hooks are **display-only**:

- `UserPromptExpansion` supports a top-level `decision: "block"` to stop
  the expansion. This plugin never emits `decision` — it must never block
  a skill invocation.
- `PreToolUse` supports `hookSpecificOutput.permissionDecision`
  (allow/deny/ask) and `updatedInput`. This plugin never emits
  `hookSpecificOutput` — it must leave the normal permission flow
  completely untouched and only surface a message.

Only the `systemMessage` JSON stdout field reaches the user for these
events (plain stdout on `UserPromptExpansion` feeds Claude's context, not
the user's UI; plain stdout on `PreToolUse` isn't surfaced to either). See
[`docs/hook-event-notes.md`](../../docs/hook-event-notes.md) for the full
verified notes on both events.

### Malformed / empty stdin

If stdin is empty or not valid JSON, each script falls back to
`(unknown skill)` rather than erroring out — this hook is purely
observational, so a best-effort message beats a hard failure.

## Scope

This plugin only covers skill-loading visibility. Rules/instruction-file
loading is a separate concern, covered by
[`show-loaded-rules`](../show-loaded-rules/README.md).
