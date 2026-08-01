---
name: scrubber-lifecycle-prose-duplication
description: The agent-memory-scrubber's placement/lifecycle rule is restated in every sdlc agent's memory-capture step, so a change to it in orchestrate/SKILL.md leaves four agent files stale.
metadata:
  type: project
---

When a PR changes when/how often `agent-memory-scrubber` runs, the
orchestrate SKILL.md edit is never the whole change: the same rule is
paraphrased in the memory-capture step of `issue-developer.md`,
`issue-fixer.md`, `pr-reviewer.md`, and in doc-updater's own "Agent
memory is not yours to curate" section. PR 211 (#207) shipped touching
only SKILL.md, the scrubber agent, and plugin.json — all four
paraphrases still said "a single pass ... after every other agent has
captured", the exact proxy the PR removed.

**Why:** the rule is load-bearing for each writer agent's decision not
to curate its own memory, so it was inlined per agent rather than
cross-referenced. That duplication is itself a latent defect, but until
it's collapsed, every scrubber-lifecycle change needs the sweep.

**How to apply:** on any scrubber-behavior PR, grep
`plugins/sdlc/agents/` for `agent-memory-scrubber` and update every
paraphrase, not just the diffed files. `plugins/cc-tools/skills/
agent-memory-cleanup/SKILL.md` also names the scrubber, but only for
the fresh-worktree/undo guarantee — placement changes leave it
accurate, and editing it would force a cc-tools version bump.
See [[guardrails-package-comment-sweep]] for the same sweep shape in
Go doc comments.
