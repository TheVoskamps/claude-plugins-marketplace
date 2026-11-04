# block-background-agents changelog

## 0.2.0 — 2026-06-29

The hook now allows an agent spawn only when `run_in_background` is
explicitly `false`.

- Every other input is denied: the field absent, `null`, `true`, any
  other value, or empty or malformed stdin. A spawn that says nothing
  no longer goes through, because it could still end up in the
  background.
- The deny reason tells the model to re-spawn with an explicit
  `run_in_background: false`, so a false deny costs one re-spawn.
- The hook now fails closed. It used to allow a spawn when stdin was
  empty or unparseable.

Delisted from the marketplace on 2026-09-22, with no change to the
plugin or its version. Enabling this plugin stops all agent use, so the
marketplace no longer offers it. Its files stay in the repository
unchanged.

## 0.1.0 — 2026-06-26

Adds a `PreToolUse` hook that denies background agent spawns.

A background subagent runs detached from the session, so a permission
prompt it raises cannot reach you and the agent silently stalls. The
hook denies a spawn when `run_in_background` is `true`, and allows
anything else, including empty or malformed stdin. It is an advisory
guard, not a security boundary. It matches both the `Agent` and `Task`
tool names, so it covers older Claude Code versions too.
