# Agent memory inbox contract (`skills/lib/agent-memory-inbox.md`)

This file is the single source of truth for **where** the agent-memory
inbox lives and **how** it is laid out. It is reference prose, not an
executable script. `/cc-tools:agent-memory-inbox-capture` (the writer)
and `/cc-tools:agent-memory-inbox-cleanup` (the curator) both read this
contract; neither restates the path.

## Why an inbox exists

An agent that declares `memory: project` under `isolation: worktree`
gets `.claude/agent-memory/<plugin>-<agent>/` resolved inside its own
throwaway worktree. That directory is removed with the worktree, so
what a run writes there persists nothing: it is a per-run intake
queue, not memory. Whether the surrounding `.claude/agent-memory/`
tree starts empty depends on the repo — one that gitignores the tree
checks nothing out, one that commits it checks out every agent's
committed entries — so a reader scopes itself to its own
`<plugin>-<agent>/` directory rather than to the tree.

Durable lore has exactly one home — `CLAUDE.md` and `/docs/*.md` — and
the inbox is the hand-off that carries a run's lessons from the agent
that learned them to the agent that writes them there.

Nothing is committed to a repository at any point in that hand-off, and
the inbox itself lives outside every repository.

## The path

```text
<scratchpad>/agent-memory-inbox/<branch>/<plugin>-<agent>/<entry>.md
```

- **`<scratchpad>`** — the harness's per-session scratchpad directory,
  named in the invoking agent's own context. A subagent's scratchpad is
  the parent session's: the path is identical for every agent in the
  session, which is what lets one agent read what another wrote. Use
  the path the context gives you verbatim; never hand-build a lookalike
  path elsewhere.
- **`agent-memory-inbox/`** — the fixed directory name under it.
- **`<branch>`** — the branch the run's work is on, read with
  `git branch --show-current`. Read it **before** any detach: an agent
  that detaches HEAD for end-of-run cleanup gets an empty string
  afterwards.
- **`<plugin>-<agent>/`** — the same subdirectory name the memory tree
  uses, preserved verbatim, so the curator can attribute each entry to
  the agent that wrote it.
- **`<entry>.md`** — one file per memory entry, copied byte for byte.

## What the inbox does not hold

The writing agent's own `MEMORY.md` index is never copied, and the
inbox keeps no index of its own. An index exists so a future reader can
find an entry worth loading; nothing loads the inbox back, so an index
there would be a second thing to keep in step with no reader to serve.

## Lifetime

The inbox is session-ephemeral. The harness owns the scratchpad's
lifetime: nothing gitignores the inbox, nothing sweeps it, and a
session that ends before the curator runs loses that session's
uncurated entries. That loss is accepted — the alternative is a durable
inbox inside a repository, which the isolation checker refuses to let a
worktree agent write to and which every concurrent session would share.
