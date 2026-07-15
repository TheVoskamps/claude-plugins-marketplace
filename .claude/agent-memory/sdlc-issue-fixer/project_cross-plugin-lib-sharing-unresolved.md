---
name: cross-plugin-lib-sharing-unresolved
description: skills/lib/repo-config.md (owned by issues plugin) is not actually readable cross-plugin; sdlc works around it by duplicating a 496-line copy; github-workflow (issue #143 / PR #150) hit the same wall — resolved by dropping the shared-lib dependency entirely, not by duplicating or lib-as-skill
metadata:
  type: project
---

`docs/plugin-authoring-constraints.md` (verified-facts doc, already in
this repo) states plugins are file-sandboxed — a bare `Read` of
`skills/lib/repo-config.md` only resolves within the plugin that
issued the Read. `dependencies` in `plugin.json` only guarantees
install/enable, not file access. The *only* documented cross-plugin
sharing mechanism is "lib-as-skill": turn the shared `.md` into a
`SKILL.md` (`user-invocable: false`) and have consumers **invoke** it
by namespaced name (e.g. `/issues-jira:jira-lib`, which is the one
existing precedent in this repo — see
`plugins/issues-jira/skills/jira-lib/SKILL.md`).

`plugins/issues/skills/lib/repo-config.md` (the repo-config reader
contract; 496 lines) is referenced bare (`skills/lib/repo-config.md`)
by 24+ files inside the `issues` plugin itself, AND by a **hand-synced
duplicate copy** bundled inside `plugins/sdlc/skills/lib/repo-config.md`
(same content, only the self-referential cross-links differ, since
`sdlc` phrases them from its own perspective). That duplicate is how
`sdlc`'s agents (`issue-developer`, `issue-fixer`, `doc-updater`,
`pr-reviewer`) and `orchestrate` currently get a working bare
`Read` — it is NOT relying on the `"dependencies": ["issues"]` edge in
`sdlc`'s plugin.json for file access (that edge does something else:
it guarantees `issues` is installed so `sdlc` can *invoke* its skills,
e.g. `/issues:issue-view`).

**Why this matters going forward:** when a new plugin (issue #143 /
PR #150, `github-workflow`) needed the same repo-config read contract,
three SKILL.md files were written with a bare `skills/lib/repo-config.md`
reference — copying the *wording* pattern ("the reader contract in the
`issues` plugin") without the file actually being reachable. PR review
caught it (Medium finding) and explicitly forbade duplicating the file
into `github-workflow` (rightly — that would be a third copy of the
same 496 lines). The architecturally correct fix per this repo's own
constraints doc is converting `plugins/issues/skills/lib/repo-config.md`
into `plugins/issues/skills/repo-config-lib/SKILL.md` (moving, not
duplicating, mirroring `jira-lib` exactly) and migrating every one of
those 24+ in-plugin bare references plus `sdlc`'s duplicate. That is a
cross-plugin refactor well outside a single `github-workflow` PR's
diff, so I escalated it rather than doing it unilaterally inside
issue-fixer scope. See [[issue-113-graphql-scanner-hardening]] for a
different but related "don't guess at repo-wide restructuring inside a
narrow fix" judgment call.

**How the github-workflow case actually resolved (2026-07, second
fixer pass on PR #150):** the first fixer pass tried adding
`"dependencies": ["issues"]` to `github-workflow`'s plugin.json to
"fix" the bare Read — per constraint 3 above, that does nothing for
file access, so PR review flagged it again (still a Medium). The
second pass's fix was a **third option neither (a) nor (b) below**:
notice that `pr-ready`/`pr-draft`/`pr-link-issue` each only ever
consumed *one field* (`source-control`, for a GitHub-only guard) out
of the full 496-line reader contract. Rather than pulling in the
whole contract by any mechanism, each SKILL.md now does a lightweight
inline read of just that one front-matter line straight from
`.claude/rules/repo-config.md`, with no schema-version requirement, no
abort-catalogue reference, no shared lib at all. Lesson: before
reaching for the shared-lib machinery (duplicate vs. lib-as-skill),
check whether the consumer actually needs the *whole* reader contract
or just one cheap field — if it's one field, inlining it beats every
sharing mechanism.

**How to apply generally:** before writing a new plugin's SKILL.md
that needs `.claude/rules/repo-config.md`, first ask how much of the
contract it actually needs.
- Needs only 1-2 simple front-matter fields (e.g. a GitHub-only
  `source-control` guard) → inline a lightweight direct read, no lib
  reference at all (the github-workflow precedent above).
- Needs the full reader contract (schema-version check, all six
  fields, `github-project:`/`jira:` block resolution) → do NOT assume
  a bare `skills/lib/repo-config.md` reference resolves outside
  `issues` itself or `sdlc` (which carries its own duplicate). Either
  (a) bundle a duplicate copy matching `sdlc`'s existing (debt-laden
  but working) precedent, or (b) if/when the lib-as-skill migration
  lands, invoke `/issues:repo-config-lib` instead. Check which of the
  two is true at the time by grepping for `name: repo-config-lib`
  under `plugins/issues/skills/` — if absent, the migration hasn't
  happened yet and only (a) works.
