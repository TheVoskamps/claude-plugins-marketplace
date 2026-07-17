---
name: gh-plugin-retired-into-git-tools
description: the standalone `gh` plugin (single skill, branch-create) was retired by issue #166 / PR #167; the skill moved into git-tools as git-branch-create, invoked as /git-tools:git-branch-create — grep for stale gh:branch-create / plugins/gh references when touching related docs
metadata:
  type: project
---

# gh plugin retired into git-tools

Issue #166 (PR #167) deleted the standalone `gh` plugin
(`plugins/gh/`) entirely. Its one skill, `branch-create`
(`/gh:branch-create`), moved into `git-tools` and was renamed
`git-branch-create` (`/git-tools:git-branch-create`) to disambiguate
from `git-tools`'s other skills once bundled together. `sdlc`'s
dependency list and every reference in `issue-developer.md` and
`orchestrate/SKILL.md` were repointed in the same PR. Version bumps:
`git-tools` 0.1.0 -> 0.2.0, `sdlc` 0.5.0 -> 0.6.0.

**Why this matters going forward:** older memory entries (see
[[project_sdlc-repo-config-split]] and, in `sdlc-issue-fixer`'s
memory, [[project_cross-plugin-lib-sharing-resolved-for-real-config-needs]])
were written when the skill was still `gh:branch-create` in a
standalone `gh` plugin — both were patched in this same PR to note
the rename rather than going stale silently. If a future run turns up
another `gh:branch-create`, `/gh:branch-create`, or `plugins/gh`
reference anywhere (docs, memory, code comments), it is stale and
should be repointed to `git-tools:git-branch-create` /
`plugins/git-tools`, not treated as still-valid.

`docs/plugin-migration-plan.md` was NOT touched by this PR — it
never referenced the retired `gh` plugin (its `gh-*` mentions are
unrelated `gh-create-app` / `gh-repo-setup-*` skills that live in
`github-setup`), consistent with [[project_plugin-docs-locality]]'s
rule to leave that file alone.
