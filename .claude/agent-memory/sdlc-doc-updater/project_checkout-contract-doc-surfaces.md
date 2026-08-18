---
name: checkout-contract-doc-surfaces
description: When an sdlc agent's checkout/cleanup contract changes (attached branch checkout -> detached origin/<branch>), the stale prose is in OTHER agents' cleanup examples and in orchestrate's doc-updater section, never in the changed file
metadata:
  type: project
---

A round that changes **how** an sdlc agent checks the PR branch out —
`git checkout <branch>` → `git checkout --detach origin/<branch>`, so
the agent claims no branch and its end-of-run cleanup collapses to
nothing — updates its own file and its own skill correctly. Two
surfaces a file-scoped sweep never reaches:

- **`plugins/sdlc/skills/orchestrate/SKILL.md` → "After each
  issue-developer or issue-fixer"** carries a paragraph about who
  checks the branch out and why the next subagent can. It opened
  "Both run in fresh worktrees and check out the PR branch", where
  "both" had silently become doc-updater plus a *main-session skill*
  that runs in no worktree at all.
- **Sibling agents' End-of-run cleanup sections name an example
  successor.** `doc-updater.md` said "so subsequent subagents (e.g. a
  `theorem-generator` or an `issue-fixer`) can check out the same
  branch" — the generator no longer checks out any branch, so the
  example is the false half of a true sentence.

The generalizable rule, now in
`docs/plugin-authoring-constraints.md` → "Fanning out parallel
agents": a fan-out agent MUST detach, because every `isolation:
worktree` worktree shares one ref store and a branch is checkable out
in one at a time (`fatal: '<branch>' is already used by worktree at
'…'`, exit 128). Agents that commit — `issue-developer`,
`issue-fixer`, `doc-updater`, `agent-memory-scrubber` — still attach.

**Why:** the changed agent's file is where the author looks; the
claims that break live in files that merely *mention* it as a
successor or a member of a "both"/"each" quantifier.

**How to apply:** on any checkout/cleanup-contract change, grep
`plugins/sdlc/` for `branch claim`, `checkout --detach`, `branch -D`
and `check out the same branch`, and read the whole sentence — decide
per hit which agents are still in the quantifier. See
[[no-blanket-predicate-over-a-list]].
