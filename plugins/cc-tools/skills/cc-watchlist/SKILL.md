---
name: cc-watchlist
description: Check status of Claude Code feature requests and bugs being tracked. Reports which tracked issues are open and which have shipped (with closure date). Use when asked about progress on tracked Claude Code issues, or when starting a session and wanting to know what's new.
allowed-tools: Bash(gh issue view:*)
argument-hint: [extra-issue-numbers]
---

# Claude Code Watchlist

## A. Session display / CLI flags

| # | Topic | Last known state |
|---|---|---|
| 40393 | `--color`/`--title` CLI flags | Open |

## B. Compound bash parsing & permissions harness

| # | Topic | Last known state |
|---|---|---|
| 16561 | Parse compound bash commands; match each component against permissions (canonical umbrella) | Open |
| 46363 | Skill or setting to skip permission prompts for esoteric/low-risk commands | Open |
| 31523 | Permission UX: compound blocking, rule accumulation, undiscoverable `Bash(*)` fix | Open |
| 28240 | `cd` permission prompt regression on compound statements (Windows-reported, platform-agnostic matcher) | Open |
| 52822 | PreToolUse `permissionDecision: "allow"` doesn't suppress native prompt in interactive mode (v2.1.119 regression) | Open |
| 4368 | Enhance PreToolUse hooks with `updatedInput` field to rewrite tool inputs | Open |
| 4719 | Expose active permission mode to PreToolUse hook | Open |
| 27661 | Subagents (Task tool) should inherit parent session hooks/permissions | Open |
| 54898 | Per-agent permission control gap (deny main agent, allow subagent) | Open |

## C. `isolation: worktree` subagent isolation

| # | Topic | Last known state |
|---|---|---|
| 62547 | Subagents silently write outside worktree via absolute `file_path` (Edit/Write hit primary clone, not worktree) | Open |
| 52958 | Subagent `isolation: worktree` leaks cwd into parent checkout mid-session, destroying untracked files | Open |
| 47548 | `isolation: worktree` switches parent worktree's branch instead of creating isolated worktree | Open |

If `$ARGUMENTS` contains additional issue numbers (space-separated), append them to the list for this run.

## Execution rules

Every Bash command MUST be single-token: no `&&`, no `||`, no `;`, no `|`, no `>` / `2>`. Compound forms hit the parser issues we're tracking (#16561 et al.) and prompt even with matching `Bash(cmd:*)` allow rules.

## Steps

1. **For each issue number**, one Bash call:
   ```
   gh issue view <num> --repo anthropics/claude-code --json number,title,state,stateReason,closedAt
   ```

2. **Classify** each result into one bucket:
   - `OPEN` (or `CLOSED` + `reopened`) → **Open**.
   - `CLOSED` + `completed` → **Shipped**. Take the first 10 characters of `closedAt` (the `YYYY-MM-DD`) as the closure date.
   - `CLOSED` + `not_planned` → **Won't ship** (footer only).
   - `CLOSED` + `duplicate` → **Cleanup** (footer only).

## Report format

Use this structure exactly. No PR references, no progress narration, no extra commentary.

```
## A. Session display / CLI flags

Open:
- #<num> — <title>
- #<num> — <title>

Shipped:
- #<num> (closed YYYY-MM-DD) — <title>

Summary: N open, M shipped.

## B. Compound bash parsing & permissions harness

Open:
- ...

Shipped:
- ...

Summary: N open, M shipped.

## C. `isolation: worktree` subagent isolation

Open:
- ...

Shipped:
- ...

Summary: N open, M shipped.
```

After both sections, if and only if non-empty:

```
Cleanup (consider removing from watch list):
- #<num> closed as duplicate

Won't ship:
- #<num> closed as not_planned
```

Omit any subheading whose list is empty. Don't write "none" or "no shipped issues" — just leave the heading out.

## Notes

- Don't speculate about issue progress beyond what `gh` reports.
- If `gh` fails, report the error verbatim and stop.
- #28240 is labeled `platform:windows` by the reporter but the underlying compound-command matcher is platform-agnostic; treat fixes as relevant to macOS/Linux too.
