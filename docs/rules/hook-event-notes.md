# Hook event notes (verified)

**Who reads this and when:** any agent writing or changing a hook in
this marketplace, or asserting how the harness treats one. Read it
before the hook's contract is designed.

Durable, doc-verified notes on how individual Claude Code hook
**events** behave, discovered while building this marketplace's hook
plugins. Confirmed against the official hooks docs
(<https://code.claude.com/docs/en/hooks>) — line/section cites are
pointers to the version read while building this marketplace; treat
them as pointers, re-verify if a doc revision moves them.

To re-verify, fetch the page's Markdown source rather than scraping
the rendered HTML: `curl -sL https://code.claude.com/docs/en/hooks.md`
returns the whole page as greppable text. Save it under the harness
scratchpad and grep the file: reading one back from bare `/tmp` is
refused by the permission gate, and the page is large enough that
dumping it into the transcript wastes the read.

That fetch is also how a claim about harness behavior gets settled in
the first place. Prose anywhere in this repo saying "Claude Code does
X" with a hook field — which `permissionDecision` values it accepts,
which events honor which field — is checked against the fetched page
before it stands. Softening such a sentence into a hedge is not the
alternative to checking it; the check is one command, and what comes
back belongs in this file.

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
- **No text it returns reaches the user.** The hooks docs say Claude
  Code discards this event's JSON output fields, `systemMessage` and
  `continue` among them, and plain stdout goes to the debug log as on
  most events. The one field still acted on is `terminalSequence` — a
  bell, window title or desktop notification, written only in an
  interactive session — so a hook here can notify but cannot print a
  line in the transcript.
- **Fires once per file loaded**, not just once per session. It fires
  both at session start and on lazy loads during the session, with
  `load_reason` one of `session_start`, `nested_traversal`,
  `path_glob_match`, `include`, or `compact`. A hook must not assume
  `session_start` is the only reason it will see.

First met while building the `show-loaded-rules` plugin (see
[`plugins/show-loaded-rules/README.md`](../../plugins/show-loaded-rules/README.md)).

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
  `additionalContext`-style hooks), not shown to the user.

First demonstrated by the `show-loaded-skills` plugin (see
[`plugins/show-loaded-skills/README.md`](../../plugins/show-loaded-skills/README.md)).

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
  is, same as `UserPromptExpansion`.
- **Decision control is `hookSpecificOutput.permissionDecision`**
  (`allow` / `deny` / `ask`), optionally paired with
  `hookSpecificOutput.updatedInput` to rewrite the tool call. A
  display-only hook must omit `hookSpecificOutput` entirely to leave
  the normal permission flow untouched — emitting the key at all,
  even with an `allow` decision, inserts the hook into permission
  resolution.

First demonstrated by the `show-loaded-skills` plugin (see
[`plugins/show-loaded-skills/README.md`](../../plugins/show-loaded-skills/README.md)).

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
[`plugins/show-agent-calls/README.md`](../../plugins/show-agent-calls/README.md)).

## `PreToolUse` (the decision channel, any matcher)

- **A hook abstains on one call by emitting the envelope with no
  `permissionDecision` field** —
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse"}}`. The hook
  states no position and the normal permission pipeline resolves the
  call. This is the spelling for a hook that adjudicates *some* calls
  and must stay out of the way on the rest, where the display-only
  advice above (omit `hookSpecificOutput` entirely) does not fit
  because the hook still emits an envelope on its deciding calls.
- **`permissionDecision: "defer"` is not that abstention.** The hooks
  docs give the literal `defer` semantics of its own, under *Defer a
  tool call for later*: it pauses the tool call for an integration
  that runs `claude -p` as a subprocess and reads its JSON output. The
  tool does not execute, the process exits with
  `stop_reason: "tool_deferred"` and the pending call preserved in the
  transcript, and only a `claude -p --resume <session-id>` from that
  calling process makes it run. Nothing resumes a subagent, so the
  tool use ends with no result and the harness tears the agent session
  down. From Claude Code 2.1.232 — whose background-by-default change
  for non-teammate agent spawns put every subagent on that path — a
  hook emitting the literal kills agent runs within a few requests.
  Never emit it as a synonym for "no opinion".
- **The documented conditions scoping when `defer` bites** are why a
  hook can emit the literal for a long time before anything dies.
  Claude Code honors the value only in non-interactive mode (`-p`); an
  interactive session logs a warning and ignores the hook result. And
  it applies only when the turn makes a single tool call — a turn
  issuing several at once ignores the `defer` with a warning and runs
  them through the normal permission flow. So the same hook binary can
  be harmless in the session a human is typing into and fatal in every
  headless agent it spawns.
- **Exit 0 with empty stdout is neither of those**, and a wrapper
  script may not be able to tell it from a broken hook binary:
  `guardrails`' `hooks.json` treats it as an unrunnable gate and fails
  closed. A hook fronted by such a wrapper must abstain with the
  field-absent envelope rather than by writing nothing.

Discovered by the `guardrails` permission-gate (issue #271); the
reasoning and the tests that pin it are in
[`plugins/guardrails/hooks/permission-gate/README.md`](../../plugins/guardrails/hooks/permission-gate/README.md).

## `SessionStart`

- **`systemMessage` reaches the user.** The hooks docs show
  `systemMessage` to the user on every event whose section does not say
  it discards or redirects the field, and the `SessionStart` section
  says neither; it names a `systemMessage` as the way to report to the
  user before the first request.
- **Plain stdout goes to Claude, not the user.** `SessionStart` is one
  of the events that adds plain-text stdout to Claude's context. A hook
  that wants the user to see a line prints it as the one
  `{"systemMessage": "..."}` object and nothing else: stdout counts as
  JSON output only when it is a single object with nothing around it
  but whitespace.
- **A `--settings` file is already in force when the hook runs.**
  `--settings` is a launch-time layer of the settings stack, and the
  docs' way to turn every hook off for one run is
  `--settings '{"disableAllHooks": true}'`, which works only if that
  layer is read before the first hook fires. So a `SessionStart` hook cannot
  change the settings of the session it runs in: a file it writes for
  `--settings` to load takes effect at the next launch.
- **Exit status 2 does not block.** The session proceeds, and the
  stderr shows as a `<hook name> hook error` notice Claude does not see.

First demonstrated by the `cc-tools` cr deploy hook,
`plugins/cc-tools/hooks/cr-deploy.sh`.
