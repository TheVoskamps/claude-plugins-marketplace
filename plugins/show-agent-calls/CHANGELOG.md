# show-agent-calls changelog

## 0.1.1 — 2026-09-11

Documentation and code comments only: links and pointers to files
outside the plugin were removed. Behavior is unchanged.

## 0.1.0 — 2026-07-23

Adds a display-only `PreToolUse` hook that shows every subagent spawn
without `--verbose`.

Each spawn prints the agent type, model, key parameters and the full,
untruncated prompt. Missing or malformed fields fall back to
placeholders, and the hook makes no permission decision, so it runs
alongside other hooks on the same event without interfering.
