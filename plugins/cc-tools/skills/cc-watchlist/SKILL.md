---
name: cc-watchlist
description: Check status of the Claude Code feature requests and bugs listed in your cc-tools topics config. Reports which tracked issues are open and which have shipped (with closure date). Use when asked about progress on tracked Claude Code issues, or when starting a session and wanting to know what's new.
allowed-tools: Bash(gh issue view:*), Read, Skill
argument-hint: [extra-issue-numbers]
---

# Claude Code Watchlist

The tracked set is the user's, not this skill's. Read
`skills/lib/cc-topics-config.md` for the config path, the `topics:`
schema, and what to do when the file is absent, unreadable, or carries
a `schema-version` this skill cannot serve. That contract is the only
statement of them; this skill does not restate them and never writes
the file.

This skill's pin is `schema-version: 1`.

## Execution rules

Every Bash command MUST be single-token: no `&&`, no `||`, no `;`, no
`|`, no `>` / `2>`. Compound forms hit the parser issues this
watchlist tracks and prompt even with matching `Bash(cmd:*)` allow
rules.

## Steps

1. **Read the topics config** per the contract above. The topics it
   yields, in file order, are the groups of this run's report; a topic
   with no `issues:` is search-only and contributes no rows here.

2. **For each issue number**, one Bash call:

   ```bash
   gh issue view <num> --repo anthropics/claude-code --json number,title,state,stateReason,closedAt
   ```

3. **Classify** each result into one bucket:
   - `OPEN` (or `CLOSED` + `reopened`) → **Open**.
   - `CLOSED` + `completed` → **Shipped**. Take the first 10 characters
     of `closedAt` (the `YYYY-MM-DD`) as the closure date.
   - `CLOSED` + `not_planned` → **Won't ship** (footer only).
   - `CLOSED` + `duplicate` → **Cleanup** (footer only).

If `$ARGUMENTS` contains additional issue numbers (space-separated),
fetch and classify them too and report them under a trailing
`## Extra issues (this run)` group. They belong to no topic and are not
written to the config — adding one durably is a hand edit to
`topics:`.

## Report format

Use this structure exactly, one group per configured topic, headed by
the topic's `name` verbatim and in file order. No PR references, no
progress narration, no extra commentary.

```text
## <topic name>

Open:
- #<num> — <title>
- #<num> — <title>

Shipped:
- #<num> (closed YYYY-MM-DD) — <title>

Summary: N open, M shipped.

## <next topic name>

Open:
- ...

Summary: N open, M shipped.
```

After the groups, if and only if non-empty:

```text
Cleanup (consider removing from watch list):
- #<num> closed as duplicate

Won't ship:
- #<num> closed as not_planned
```

Omit any subheading whose list is empty. Don't write "none" or "no
shipped issues" — just leave the heading out.

The headings carry the topic name alone: no `A.` / `B.` / `C.` prefix,
no numbering. File order already carries the sequencing, and a letter
would silently renumber every group below any topic the user adds or
removes.

## Notes

- Say in the report when the config was seeded this run, and where, or
  when it was unreadable and the starter topics were used instead.
- Don't speculate about issue progress beyond what `gh` reports.
- If `gh` fails, report the error verbatim and stop.
- #28240 is labeled `platform:windows` by the reporter but the
  underlying compound-command matcher is platform-agnostic; treat fixes
  as relevant to macOS/Linux too.
