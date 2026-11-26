# show-loaded-rules

A single-purpose observability hook: an `InstructionsLoaded` hook that
**surfaces a one-line message for every CLAUDE.md / `.claude/rules/*.md`
file loaded into context**.

## What it does

Normally the loading of instruction files (`CLAUDE.md`,
`.claude/rules/*.md`) is invisible unless you run with `--verbose`.
This plugin makes each load visible in a normal session by printing a
short `Rules loaded: <path> (<reason>)` message for every file as it
loads.

## Why

Knowing exactly which rules files are in context — and why they loaded
— is useful for debugging "why is Claude doing X" questions and for
building trust that the right project/user rules are actually active.
`InstructionsLoaded` is the only hook event that observes this, so a
tiny dedicated hook is the simplest way to expose it.

## How it works

`hooks/hooks.json` registers an `InstructionsLoaded` hook with no
matcher:

```json
{
  "hooks": {
    "InstructionsLoaded": [
      {
        "hooks": [
          { "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/show-loaded-rule.sh",
            "timeout": 10 }
        ]
      }
    ]
  }
}
```

`hooks/show-loaded-rule.sh` (POSIX `sh` + `jq`) reads the hook stdin
JSON, extracts `file_path` and `load_reason`, and emits a
`systemMessage` JSON field with a one-line summary:

```text
Rules loaded: /path/to/CLAUDE.md (session_start)
```

### Malformed / empty stdin

If stdin is empty or not valid JSON, the script falls back to
`(unknown file)` / `(unknown)` rather than erroring out — this hook is
purely observational, so a best-effort message beats a hard failure.

## Scope

This plugin only covers rules/instruction files (`InstructionsLoaded`).
Skill-loading visibility is a separate concern, covered by
`show-loaded-skills`.
