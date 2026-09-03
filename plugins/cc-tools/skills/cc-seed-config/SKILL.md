---
name: cc-seed-config
description: "Seed the cc-tools topics config from the shipped starter set of Claude Code topics, or hand that starter set back without writing. Invoked by /cc-tools:cc-watchlist and /cc-tools:cc-whats-new when the config is absent or unreadable; not a user verb."
user-invocable: false
allowed-tools: Read, Write
---

You are running the `/cc-tools:cc-seed-config` skill. You own the
shipped starter set of Claude Code topics and the write that turns it
into the user's own config file. Nothing else in this plugin carries a
copy of either: two skills independently seeding one file is the
duplication this skill exists to prevent.

Read `skills/lib/cc-topics-config.md` for the config path, the
`topics:` schema, and the read rules your callers apply. That contract
is the only statement of them; this skill does not restate them.

## Invocation

```text
/cc-tools:cc-seed-config [--table-only]
```

- **No argument** — write the file and report where. Your caller found
  it absent.
- **`--table-only`** — hand the starter topics back and write nothing.
  Your caller could not read the file and needs topics to proceed on;
  a denied read is not evidence that the file is missing, so seeding
  there would clobber a config you cannot see.

The file already existing is not a case you handle: a caller that can
read it does not invoke you. If the write finds one, stop and report
it rather than overwriting.

## The starter set

Every issue below is in `anthropics/claude-code`. The right-hand
column is for whoever maintains this list — the file you write carries
the numbers only.

| Topic | Issues | Subject |
| --- | --- | --- |
| Session display / CLI flags | 40393 | `--color`/`--title` CLI flags |
| Compound bash parsing & permissions harness | 16561, 46363, 31523, 28240, 52822, 4368, 4719, 27661, 54898 | Parsing compound bash against permission rules, and the PreToolUse surface around it — `updatedInput`, the active permission mode, subagent inheritance, per-agent control. 28240 is Windows-reported but the matcher it names is platform-agnostic, which is why it sits here |
| `isolation: worktree` subagent isolation | 62547, 52958, 47548 | Worktree-isolated subagents writing into the primary clone, leaking cwd, or switching the parent's branch |

Keep the issue order within a topic: it is the order the user reads
them in, and the first number in each is the umbrella the rest hang
off.

## Writing the file

Write exactly this, with the topics above expanded, at the path
`skills/lib/cc-topics-config.md` gives:

```yaml
# Topics tracked by the cc-tools plugin.
schema-version: 1
topics:
  - name: Session display / CLI flags
    issues: [40393]
```

One comment, saying which plugin owns the file, and nothing else — no
schema restatement, no rationale, no history. The skills own the
schema, and a comment here is a second copy to keep in step.

The `Write` tool creates missing parent directories, so do not run
`mkdir`.

## Output

One block, naming which mode ran:

```text
## cc-tools config seeded

Path:   <absolute path written>
Topics: <N> (<M> issues)
```

or, for `--table-only`:

```text
## cc-tools starter topics (nothing written)

- <name> — <issue numbers, or "search-only">
```

Hand the topics themselves back to the caller in both modes; the
caller reports on them and never re-reads this file for them.
