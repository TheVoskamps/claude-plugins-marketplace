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
more notes (e.g. issue #116 will add `UserPromptExpansion` and
`PreToolUse`-matcher-`Skill` notes).

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
