---
name: sdlc-repo-config-split
description: sdlc no longer reads .claude/rules/repo-config.md's full six-field contract directly; branch/PR mechanics moved into gh:branch-create and github-prs:pr-create, each doing its own inline 2-field parse (issue #143 / PR #150)
metadata:
  type: project
---

# sdlc repo-config split

As of issue #143 (PR #150), `plugins/sdlc/skills/lib/repo-config.md`
(the duplicated 496-line reader-contract copy) was deleted, and the
four `sdlc` agents plus `orchestrate/SKILL.md` no longer resolve the
full six-field repo-config contract themselves:

- `issue-developer` delegates branch creation to `/gh:branch-create`
  and PR creation to `/github-prs:pr-create` — both read their own 1-2
  needed fields (`default-issue-source-branch` +
  `issue-branch-naming-prefix`, and `default-pr-target-branch` +
  `issue-link-prefix`, respectively) via a lightweight inline parse,
  not the full reader contract.
- `doc-updater` and `issue-fixer` fetch PR diffs via
  `/github-prs:pr-diff`, which reads no repo-config at all
  (GitHub-only by construction, nothing to branch on).
- `pr-reviewer` still inline-parses one real field
  (`issue-link-prefix`, for recognizing `References:` trailers) and
  posts reviews via `/github-prs:pr-review-submit` (also no
  repo-config).
- `orchestrate/SKILL.md` itself now only reads `issue-link-prefix` and
  the optional `github-project:`/Jira `status` slot — not the other
  five fields, which moved into the two `skills:`-invoked skills above.

**Why this matters for future doc-updater runs:** if a future PR
touches `sdlc` agent frontmatter, `orchestrate/SKILL.md`, `gh`, or
`github-prs`, do not assume an agent or the orchestrator reads the full
repo-config contract — check its `skills:` frontmatter and "Read
global rules first" section first. See
[[project_cross-plugin-lib-sharing-resolved-for-real-config-needs]] and
[[project_cross-plugin-lib-sharing-unresolved]] (both in
`sdlc-issue-fixer`'s memory) for the full architectural rationale
(plugins are file-sandboxed; a bare cross-plugin `Read` of
`skills/lib/repo-config.md` silently does not resolve).
