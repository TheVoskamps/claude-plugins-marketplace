---
name: sdlc-agent-baseline-docs-locality
description: sdlc agents' model tier, tools list, permissionMode/frontmatter-support, and foreground enforcement are documented only in orchestrate/SKILL.md + the agent frontmatter; top-level README and /docs describe agents by roster, not model or tool grants.
metadata:
  type: project
---

# sdlc agent baseline docs locality

The sdlc agents' shared frontmatter baseline — which model each agent
runs (`sonnet` for issue-developer/issue-fixer/doc-updater, `opus` for
pr-reviewer), each agent's `tools:` grant list, whether a
`permissionMode` frontmatter key is even supported, and how foreground
execution is enforced — is documented in exactly two places:
`plugins/sdlc/skills/orchestrate/SKILL.md` (the "hardened baseline"
paragraph near the top and the "Token Efficiency" section near the
bottom, model-tier only) and the individual agent `.md` frontmatter.

Confirmed again on PR #121 (issue #120, 2026-07-11): removing the
unsupported `permissionMode` key and pruning stale tool names
(`LS`, `TodoRead`, `TodoWrite`, `MultiEdit`) from all four agents'
`tools:` lists required no README/doc changes — the PR's own edit to
the "hardened baseline" paragraph in orchestrate/SKILL.md was the only
doc surface, and it was already complete in the PR diff. A `grep` for
`MultiEdit` also hit `plugins/guardrails/hooks/permission-gate/README.md`,
but that reference describes the Go hook's own PreToolUse tool-name
regex (a global Claude Code tool category), not the sdlc agents'
per-agent `tools:` grants — out of scope, different subject entirely,
do not touch it for sdlc agent-frontmatter changes.

**Why:** The top-level `README.md` describes sdlc only as a roster
("the developer/fixer/reviewer/doc agents"); `docs/plugin-migration-plan.md`
lists the four agents by name as a topology/structure plan. Neither
mentions model tier or the (now-removed) `background: false` frontmatter
key. The `block-background-agents` README documents its own hook's
`run_in_background: false` spawn-time flag — a different thing from the
inert agent-frontmatter `background:` key — and is unaffected by sdlc
agent-model changes.

**How to apply:** When a PR changes the sdlc agents' model tier or the
foreground-enforcement mechanism, the doc updates live in
orchestrate/SKILL.md and the agent frontmatter, and a well-formed PR
already contains them. Do not ripple such a change into the top-level
README or /docs — they document agents by role, not by model. Parallels
[[project_github-setup-docs-locality]] (behavior documented in one
SKILL.md; other docs reference by name only).

The memory-capture→curate flow (raw `.claude/agent-memory/` commits
from each writer agent at end-of-run, curated afterwards by
`agent-memory-scrubber`) is an internal agent mechanism of exactly this
kind. On the PR that introduced it, its own edits to `orchestrate/SKILL.md` and
all four agent `.md` files were already complete and consistent;
`plugins/sdlc/README.md` doesn't exist and `docs/plugin-migration-plan.md`
is historical/out of scope per [[project_plugin-docs-locality]] — no
top-level README or /docs ripple was needed. Also: each agent's
`.claude/agent-memory/sdlc-<agent>/` directory is genuinely separate
(each agent frontmatter has its own `memory: project` scope, and only
reads its own directory) — a lesson learned independently by two agent
roles (e.g. the heredoc-commit-sandbox-gate gotcha, present near-
identically in both `sdlc-issue-developer` and `sdlc-issue-fixer`) is
NOT a cross-directory duplicate to merge away; each agent needs its own
copy since it never reads the other's directory.
