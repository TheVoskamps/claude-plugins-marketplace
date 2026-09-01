---
name: cc-watchlist
description: Check status of the Claude Code feature requests and bugs listed in your cc-tools config. Reports which tracked issues are open and which have shipped (with closure date). Use when asked about progress on tracked Claude Code issues, or when starting a session and wanting to know what's new.
allowed-tools: Bash(gh issue view:*), Read, Skill
argument-hint: [extra-issue-numbers]
---

# Claude Code Watchlist

The issues this skill reports on are the user's, not this file's: they
live in `topics:` in
`${XDG_CONFIG_HOME:-$HOME/.config}/cc-tools/config.yml`, which the user
edits by hand. Nothing here names an issue number, and adding or
dropping one never means editing a plugin file.

## Execution rules

Every Bash command MUST be single-token: no `&&`, no `||`, no `;`, no
`|`, no `>` / `2>`. Compound forms hit known parser gaps in the
permissions harness and prompt even with matching `Bash(cmd:*)` allow
rules. That rules out shell parameter expansion for the config path too — resolve
`XDG_CONFIG_HOME`'s value by reading the environment yourself and pass
the absolute path.

Read the config with `Read`, never `cat` or `grep` from Bash: the
guardrails carve-out that makes `~/.config` reachable at all covers the
file-tool track only.

## Steps

1. **Read the config.** This skill pins `schema-version: 1`.

   - **Absent** — invoke `/cc-tools:cc-seed-config`, which creates it
     from the shipped starter topics. Use the topics it returns, and
     say in the report that the config was seeded and at which path.
   - **Unreadable** (a denied read on a machine whose
     `~/.config/guardrails/config.yml` does not list `cc-tools/**`, or
     any other failure that is not absence) — invoke
     `/cc-tools:cc-seed-config --table-only`, report that the config
     could not be read and quote the error, and run on the starter
     topics. Nothing is written; this skill never writes.
   - **Malformed, or `schema-version` absent** — report the path and
     stop. A hand-edited file that broke is not a file to guess at.
   - **`schema-version` below 1** — stop, naming both the version found
     and the version pinned.
   - **`schema-version` above 1** — proceed on the keys documented here
     and ignore the rest.

2. **Take the issue numbers** — every `issues:` entry of every topic,
   in file order. A topic with no `issues:` is search-only, belongs to
   `/cc-tools:cc-whats-new`, and contributes nothing here: no rows and
   no heading.

   If `$ARGUMENTS` contains additional issue numbers (space-separated),
   report them for this run under a final `## Extra (this run)` group.
   They belong to no topic and are never written to the config.

3. **For each issue number**, one Bash call:

   ```bash
   gh issue view <num> --repo anthropics/claude-code --json number,title,state,stateReason,closedAt
   ```

4. **Classify** each result into one bucket:
   - `OPEN` (or `CLOSED` + `reopened`) → **Open**.
   - `CLOSED` + `completed` → **Shipped**. Take the first 10 characters
     of `closedAt` (the `YYYY-MM-DD`) as the closure date.
   - `CLOSED` + `not_planned` → **Won't ship** (footer only).
   - `CLOSED` + `duplicate` → **Cleanup** (footer only).

## Report format

Use this structure exactly, one group per topic that has issues, in
file order. No PR references, no progress narration, no extra
commentary.

```text
## <topic name>

Open:
- #<num> — <title>
- #<num> — <title>

Shipped:
- #<num> (closed YYYY-MM-DD) — <title>

Summary: N open, M shipped.
```

The heading is the topic's `name` verbatim and carries no `A.` / `B.`
/ `C.` prefix. File order already sequences the groups, and a letter
would silently renumber every group below any topic the user adds or
removes. Issue numbers passed in `$ARGUMENTS` get one further group,
`## Extra (this run)`, last and in the same shape.

After the groups, if and only if non-empty:

```text
Cleanup (consider removing from watch list):
- #<num> closed as duplicate

Won't ship:
- #<num> closed as not_planned
```

Omit any subheading whose list is empty. Don't write "none" or "no
shipped issues" — just leave the heading out.

## Notes

- Don't speculate about issue progress beyond what `gh` reports.
- If `gh` fails, report the error verbatim and stop.
- A compound-command matcher report labeled `platform:windows` by its
  reporter is still platform-agnostic underneath; treat fixes as
  relevant to macOS/Linux too.
