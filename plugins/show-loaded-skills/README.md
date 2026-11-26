# show-loaded-skills

A single-purpose observability hook pair: `UserPromptExpansion` and
`PreToolUse` (matcher `Skill`) hooks that **surface a one-line message for
every skill loaded**, covering both ways a skill can load — a user-typed
command and a model-initiated invocation.

## What it does

Claude Code loads a skill in two distinct ways:

- **Typed command**: you type `/my-skill`. The plugin's
  `UserPromptExpansion` hook reports this path.
- **Model invocation**: Claude decides to call a skill through the `Skill`
  tool. The plugin's `PreToolUse` hook, with matcher `Skill`, reports
  this path.

Normally both loads are invisible unless you run with `--verbose`. This
plugin makes each visible in a normal session by printing a short
`Skill loaded: <name> (<how>)` message for every firing, on either path.

## Why

Knowing which skill just loaded — and whether you typed it or Claude
chose it — is useful for debugging "why is Claude doing X" questions and
for building trust that the right skill actually ran. Sibling plugin
`show-loaded-rules` covers the analogous question for CLAUDE.md / rules
files; this plugin covers skills.

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
falling back to `tool_input.name`), and emits the analogous message:

```text
Skill loaded: review-pr (model-invoked)
```

Both hooks are **display-only**: each emits `systemMessage` and nothing
else.

### Malformed / empty stdin

If stdin is empty or not valid JSON, each script falls back to
`(unknown skill)` rather than erroring out — this hook is purely
observational, so a best-effort message beats a hard failure.

## Scope

This plugin only covers skill-loading visibility. Rules/instruction-file
loading is a separate concern, covered by
`show-loaded-rules`.
