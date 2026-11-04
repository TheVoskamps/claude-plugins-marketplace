# show-loaded-rules changelog

## 0.1.1 — 2026-09-11

Documentation only: the README now states the event's firing and load
reasons itself instead of linking outside the plugin. Behavior is
unchanged.

## 0.1.0 — 2026-07-11

Adds an `InstructionsLoaded` hook that emits a one-line message for each
`CLAUDE.md` or `.claude/rules/*.md` file loaded into context.

The message reads `Rules loaded: <path> (<reason>)`, and covers loads at
session start and lazy loads during the session. The hook only observes:
it cannot block or alter a load. On empty or malformed stdin it reports
`(unknown file)` and `(unknown)` rather than failing.
