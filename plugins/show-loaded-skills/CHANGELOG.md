# show-loaded-skills changelog

## 0.1.1 — 2026-09-11

Documentation and code comments only: links and pointers to files
outside the plugin were removed. Behavior is unchanged.

## 0.1.0 — 2026-07-11

Adds hooks that show a one-line message each time a skill loads, and how
it loaded.

- A command you type prints `Skill loaded: <name> (typed command)`.
- A skill the model invokes prints
  `Skill loaded: <name> (model-invoked)`.

Both hooks are display-only: they never block a skill or touch the
permission flow. On empty or malformed stdin they report
`(unknown skill)` rather than failing.
