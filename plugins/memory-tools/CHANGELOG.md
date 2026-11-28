# memory-tools changelog

## 0.1.0 — 2026-11-27

The plugin is new. It keeps a copy of every memory Claude Code writes,
outside any repository, and grades those copies without changing
anything.

- A `PostToolUse` hook records each successful `Write` or `Edit` into a
  memory directory: an agent's project, local or user memory, and the
  main session's auto memory, an `autoMemoryDirectory` set in a
  settings file included. It follows `CLAUDE_CONFIG_DIR`.
- Each recorded call is one YAML file under
  `${XDG_STATE_HOME:-$HOME/.local/state}/memory-tools/<host>/<owner>/<repo>/`,
  filed by the repository's `origin`, so a memory written in a worktree
  outlives it. A record holds the memory's kind, its path, the tool,
  the session, the branch, the capture time and the file's whole text
  after the call.
- The hook only observes. It prints nothing, never blocks a tool call
  and exits 0 on every input. A write with no `origin` to file it under
  is not recorded.
- `/memory-tools:memory-grade [<checkout-path>]` grades the latest
  record of each memory captured for a checkout's repository as delete,
  durable or no code home. A delete comes with the check that shows it;
  the other two come with the file the memory would land in and the
  constraint as it would be written there. The skill writes, deletes
  and commits nothing.

It needs `jq` and `git` on `PATH`, and memory turned on in Claude Code.
