---
name: agent-memory-scrubber-split-off-curation
description: doc-updater no longer curates .claude/agent-memory/ — a dedicated agent-memory-scrubber agent (cc-tools:agent-memory-cleanup) now owns that pass, spawned once after the review loop settles
metadata:
  type: project
---

As of PR #185 (issue #184), curating `.claude/agent-memory/` is no
longer part of doc-updater's job. A new `agent-memory-scrubber` agent
(`plugins/sdlc/agents/agent-memory-scrubber.md`) runs the
`cc-tools:agent-memory-cleanup` skill in one pass after the PR's review
loop settles — after every writer (`issue-developer`, `issue-fixer`,
`doc-updater`, `pr-reviewer`) has captured its own raw memory onto the
branch — and before `/github-prs:pr-ready`. See
`plugins/sdlc/skills/orchestrate/SKILL.md` → "After the review loop
settles: curate the PR's agent memory".

**Why:** doc-updater ran before `pr-reviewer`, so its curation pass
always missed `pr-reviewer`'s own capture — a known one-PR lag the old
design accepted. Moving curation to a single agent spawned last closes
that gap in the same PR.

**How to apply:** a doc-updater run must not enumerate, judge, prune,
or edit `.claude/agent-memory/` entries — not even ones visibly stale
or redundant. Leave every raw capture (including your own) in place;
`agent-memory-scrubber` is the only agent that touches that directory
destructively. This applies even when this file's own PR is the one
introducing the split — a self-referential PR's diff is the current
source of truth for what doc-updater does, not a stale system-prompt
copy of the pre-PR agent definition.
