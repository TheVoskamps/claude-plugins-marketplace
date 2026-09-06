---
name: cc-suggest-topics
description: Propose cc-tools topics derived from this machine's global Claude configuration — settings, installed plugins, always-loaded rules — shown against what the topics config already tracks, and append only the candidates the user accepts. Use when the tracked topics look narrower than what this machine actually exercises.
allowed-tools: Read, Write, Skill
---

# Suggest topics from this machine's Claude configuration

`cc-watchlist` and `cc-whats-new` act on the topics the user curated
and infer none from anywhere. What that split loses is a harness
surface this machine exercises that the user never thought to track.
This skill recovers it, and holds no authority of its own: it reads the
machine, proposes, and appends only what the user accepts.

## Invocation

```text
/cc-tools:cc-suggest-topics
```

No arguments.

## Topics config

Read `skills/lib/cc-topics-config.md` for the config path, the
`topics:` schema, and what to do when the file is absent, unreadable,
or carries a `schema-version` this skill cannot serve — including the
exception this skill holds on the unreadable outcome. That contract is
the only statement of them.

This skill's pin is `schema-version: 1`.

## What it reads

The machine's **global** Claude configuration, and only that:

- `~/.claude/settings.json` and `~/.claude/settings.local.json`
- `~/.claude/plugins/installed_plugins.json`, for each installed
  plugin and its version, and
  `~/.claude/plugins/known_marketplaces.json`, for the marketplaces
  they came from
- `~/.claude/CLAUDE.md`, for always-loaded rules that name a harness
  feature

`~/.claude.json` is not one of them: it is a sibling of `~/.claude/`
rather than a path under it, so the `guardrails` permission gate denies
a `Read` of it as an outside-the-repository escape wherever that gate
is installed.

The repo-local `.claude/settings.json` and `settings.local.json` are
**not** read. `config.yml` is machine-wide, so a candidate derived from
a repo-local setting has nowhere repo-local to be written, and reading
one would push a single repo's topics onto every other repo. Issue #375
adds the repo-local layer; this skill gains the repo-local rung when
that lands, and not before.

A file that is absent contributes no candidates and is not an error. A
file whose `Read` denies is reported with the tool's error verbatim,
and the run continues on the files that did read — say which files
went unread, so a thin candidate list is not read as a thin machine.

A **candidate topic** is any harness surface those files exercise: a
model id, a permission mode, `alwaysThinkingEnabled` and its
neighbours, each hook event wired up, each MCP server, each installed
plugin's name and the marketplace it came from, each env var, each
statusline or output-style setting.

Record the file and the key each candidate came from and show both in
the report. That is what lets the user tell a claim about their own
configuration from a topic this skill invented.

## What it writes

`config.yml`'s `topics:`, and nothing else. An accepted candidate is
appended as a name-only entry — no `issues:`. What that shape means
for the readers is in `skills/lib/cc-topics-config.md`.

## Nothing is written without an answer

Show the current `topics:` in full, then every candidate with its
provenance. Then take the candidates one at a time:

- **A candidate that overlaps a tracked topic under different
  wording** — "hook events" against a tracked "hooks", say. Propose the
  combined or broader term, naming the tracked topic, the candidate,
  and the single replacement name you would write. On yes, rewrite that
  topic's `name` to the broader term and carry its `issues:` over
  untouched. On no, offer the candidate as its own
  separate topic, which takes its own yes.
- **A candidate that overlaps nothing** — offer it as a new topic
  directly.

A topic `name` goes verbatim into the `gh search issues` query
`cc-whats-new` runs, so rewriting one changes what that skill finds
from then on. That is why a merge is proposed rather than applied: no
`topics:` entry is added, renamed, or removed without an answer.

An accepted candidate is an edit to a file the user owns — preserve
every other key and every other topic exactly as they stand. Declining
every candidate leaves `config.yml` byte-identical to what this run
read — a seed the run itself wrote included.

## Report format

```text
<config seeded notice, naming the path>

## Tracked now

- <topic name> — <its `issues:`, or "search-only" when it has none>

## Candidates

- <candidate name> — <file>, <key>

## Files not read

- <path> — <tool error, verbatim>
```

Omit any section whose list is empty, and leave the seeded notice out
entirely when the config was read as it stood. The proposals themselves
are asked after this report, one at a time, per the section above.
