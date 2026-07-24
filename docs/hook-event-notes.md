# Hook event notes (verified)

Durable, doc-verified notes on how individual Claude Code hook
**events** behave, discovered while building this marketplace's hook
plugins. Confirmed against the official hooks docs
(<https://code.claude.com/docs/en/hooks>) — line/section cites are
pointers to the version read while building this marketplace; treat
them as pointers, re-verify if a doc revision moves them.

This is a lessons-learned log, organized **per hook event**, distinct
from [`plugin-authoring-constraints.md`](./plugin-authoring-constraints.md),
which documents the plugin *packaging* system (sandboxing, namespacing,
dependencies, compaction caps, `bin/` PATH). An event's runtime
behavior is true for any `settings.json` hook registered for that
event, with or without a plugin involved — so it belongs here, not
there. Append a new `##` section per event as future plugins uncover
more notes.

## `InstructionsLoaded`

- **Observe-only: no decision control, exit code ignored.** The hook
  cannot block or alter a load regardless of what it returns.
- **Only the `systemMessage` JSON stdout field reaches the user** —
  not bare/plain stdout (e.g. a bare `echo`). A hook that wants to
  surface a message must emit `{"systemMessage": "..."}` on stdout.
- **Fires once per file loaded**, not just once per session. It fires
  both at session start and on lazy loads during the session, with
  `load_reason` one of `session_start`, `nested_traversal`,
  `path_glob_match`, `include`, or `compact`. A hook must not assume
  `session_start` is the only reason it will see.

First demonstrated by the `show-loaded-rules` plugin (see
[`plugins/show-loaded-rules/README.md`](../plugins/show-loaded-rules/README.md)).

## `UserPromptExpansion`

- **Fires when a user-typed command (e.g. `/my-skill`) expands into a
  prompt, before it reaches Claude.** It does not fire for a
  model-initiated skill invocation — that path is `PreToolUse` with
  matcher `Skill` (see below).
- **Input carries `command_name`, `command_args`, and `expanded_prompt`**
  in addition to the common fields (`session_id`, `prompt_id`,
  `transcript_path`, `cwd`, `hook_event_name`). `command_name` is the
  skill/command name being invoked; `command_args` is an array of
  argument strings; `expanded_prompt` is the full text that will be
  sent to Claude if not blocked.
- **Can block via a top-level `decision: "block"`** (with a `reason`
  string shown to the user) — unlike `PreToolUse`, this is a top-level
  field, not nested under `hookSpecificOutput`.
- **`systemMessage` is the reliable display channel.** Plain stdout on
  this event is injected into Claude's context (useful for
  `additionalContext`-style hooks), not shown to the user — the same
  distinction seen on `InstructionsLoaded` above, but for a different
  reason (this event's plain stdout has a *different* consumer, not no
  consumer).

First demonstrated by the `show-loaded-skills` plugin (see
[`plugins/show-loaded-skills/README.md`](../plugins/show-loaded-skills/README.md)).

## `PreToolUse` (matcher `Skill`)

- **Fires when the model invokes a skill via the Skill tool** —
  the counterpart to `UserPromptExpansion` for typed commands. Matcher
  value `Skill` matches only the Skill tool, same as any other exact
  tool-name matcher.
- **The official hooks docs do not publish a field-by-field schema for
  the `Skill` tool's `tool_input`** (unlike `Bash`'s documented
  `tool_input.command`). The Skill tool's own parameter schema (as
  presented to the model) names the skill identifier `skill` and its
  optional argument string `args`, so `tool_input.skill` is the best
  available inference; `tool_input.name` is an untested fallback. If a
  future run observes the actual field name (e.g. via `--debug`
  transcript output), correct this note and the
  `show-loaded-skills` scripts together.
- **`systemMessage` reaches the user on `PreToolUse` too** — this is
  broader than the plain-stdout restriction: plain/bare stdout is not
  shown to the user on this event, but the `systemMessage` JSON field
  is, same as `InstructionsLoaded` and `UserPromptExpansion`.
- **Decision control is `hookSpecificOutput.permissionDecision`**
  (`allow` / `deny` / `ask`), optionally paired with
  `hookSpecificOutput.updatedInput` to rewrite the tool call. A
  display-only hook must omit `hookSpecificOutput` entirely to leave
  the normal permission flow untouched — emitting the key at all,
  even with an `allow` decision, inserts the hook into permission
  resolution.

First demonstrated by the `show-loaded-skills` plugin (see
[`plugins/show-loaded-skills/README.md`](../plugins/show-loaded-skills/README.md)).

## `PreToolUse` (matcher `Agent|Task`)

- **Fires when the model spawns a subagent** — matches the
  subagent-spawn tool, evidenced by the existing
  `block-background-agents` plugin, which registers this exact
  event+matcher and demonstrably fires and reads
  `tool_input.run_in_background` to deny background spawns. Matching
  both `Agent` and `Task` is harmless if only one name is live on a
  given Claude Code build.
- **The official hooks docs do not publish a field-by-field schema for
  the spawn tool's `tool_input`.** `tool_input.run_in_background` is
  the only doc/empirically-confirmed field (via
  `block-background-agents`). The remaining fields
  (`subagent_type`, `prompt`, `model`, `description`, `isolation`) are
  **inferred** from the Agent tool's own parameter schema, the same
  doc-gap inference already applied to `tool_input.skill` on
  `PreToolUse (matcher Skill)` above. If a future run observes the
  actual field names (e.g. via `--debug` transcript output), correct
  this note and the `show-agent-calls` script together.
- **`SubagentStart` was considered and rejected** for surfacing spawn
  details: per the official hooks docs it carries only `agent_id` and
  `agent_type` — not the prompt, description, model, or spawn
  parameters, so it cannot answer "with what parameters and what
  prompt".
- **`systemMessage` reaches the user on `PreToolUse`**, same as the
  `Skill`-matcher case above. Decision control is
  `hookSpecificOutput.permissionDecision`; a display-only hook must
  omit `hookSpecificOutput` entirely to leave the normal permission
  flow untouched — this matters doubly here because
  `block-background-agents` already hooks the same event+matcher for
  decision control, so a display-only hook on this matcher must not
  interfere with it.

First demonstrated by the `show-agent-calls` plugin (see
[`plugins/show-agent-calls/README.md`](../plugins/show-agent-calls/README.md)).
