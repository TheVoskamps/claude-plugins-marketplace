---
name: cross-plugin-lib-sharing-resolved-for-real-config-needs
description: plugins are file-sandboxed, so a bare cross-plugin Read of skills/lib/repo-config.md cannot resolve; a skill needing 1-2 real repo-config fields inlines its own parse, a GitHub-only wrapper needs no repo-config at all, and only a full-contract reader justifies the shared lib
metadata:
  type: project
---

# Cross-plugin lib sharing, resolved for real config needs

The "vacuous guard" resolution (zero repo-config coupling) applies to
`pr-ready`/`pr-draft`/`pr-link-issue`/`pr-diff`/`pr-review-submit` —
GitHub-only `gh` wrappers with no other backend to branch on. That
leaves the other case: a skill that needs *real*, per-repo-varying
config values, not a backend guard.

`git-tools:git-branch-create` (needs
`default-issue-source-branch` + `issue-branch-naming-prefix`) and
`github-prs:pr-create` (needs
`default-pr-target-branch` + `issue-link-prefix`) are exactly that
case — two fields each, both genuinely vary per repo, neither is a
vacuous GitHub-only guard. The checkpoint commit these skills first
landed in (PR #150, before this fix) wrote their "Repo-config"
sections as if they followed the `issues` plugin's full reader
contract (`skills/lib/repo-config.md`, schema-version 6, the whole
abort catalogue) via a bare cross-plugin reference. That reference
cannot resolve: `docs/plugin-authoring-constraints.md` → "Plugins are
file-sandboxed" confirms a bare `Read` from one plugin's skill cannot
reach a file living in another plugin's directory, `dependencies` in
`plugin.json` doesn't grant file access either.

**The fix applied:** both skills now do a lightweight **inline** parse
of just their own 1-2 needed front-matter lines directly from
`.claude/rules/repo-config.md`, with a single one-line abort message
matching the full contract's "File missing" wording (for consistency)
but no schema-version check, no abort catalogue, no lib reference at
all. This is the same "does the consumer need 1-2 fields or the whole
contract" question the ladder at the end of this entry asks, applied to
the real-fields case rather than the vacuous-guard one. Both the
skill's own SKILL.md and its plugin's README.md needed the fix — the
README had independently
drifted to also claim `pr-diff`/`pr-review-submit` read repo-config
"internally", which was already false before this pass (verified by
reading both SKILL.md files: they read no repo-config at all).

**How to apply generally:** before writing a new plugin's SKILL.md that
needs `.claude/rules/repo-config.md`, ask how much of the contract it
actually needs, in this order:

- The skill wraps a backend-specific CLI/API that has no other backend
  it could target (e.g. `gh pr ...` for a GitHub-only PR wrapper) →
  it needs **nothing**. Skip repo-config entirely; a guard that can
  never fire is dead prose, not a guard. Ask this vacuous-guard
  question BEFORE reaching for inlining.
- It needs only 1-2 simple front-matter fields for a genuine
  multi-backend branch (e.g. choosing between `gh` and
  `aws codecommit`) → inline a lightweight direct read, no lib
  reference at all.
- It needs the full reader contract (schema-version check, all six
  fields, `github-project:`/`jira:` block resolution) → a bare
  `skills/lib/repo-config.md` reference does NOT resolve outside the
  plugin that issued the Read. Either bundle a duplicate copy, or, if
  the lib-as-skill migration has landed, invoke the lib skill by
  namespaced name. Check which by grepping for `name: repo-config-lib`
  under `plugins/issues/skills/` — if absent, only the duplicate
  works. The one existing lib-as-skill precedent in this repo is
  `plugins/issues-jira/skills/jira-lib/SKILL.md`
  (`user-invocable: false`, invoked as `/issues-jira:jira-lib`).

Don't duplicate the 496-line lib into a new plugin for a small need
(churn, drift risk); reserve the full contract for readers that
genuinely consume the whole thing.

**When removing a shared-lib duplicate, grep every consumer for the
bare reference.** A bare `skills/lib/repo-config.md` Read can be
"working" only because the consuming plugin's own duplicate copy
happens to sit at that exact relative path — not because cross-plugin
resolution works. Delete the duplicate and every such reference breaks
at once.

`sdlc:pr-review-pipeline` is the same case at a smaller scale: it
needs one real
field (`issue-link-prefix`, for recognizing `References:` trailers — an
issue-tracker concern, independent of the PR-diff/review-post mechanics
`github-prs` owns), and gets the same inline-parse treatment.
