---
name: cross-plugin-lib-sharing-resolved-for-real-config-needs
description: gh:branch-create and github-prs:pr-create genuinely need 2 real (non-vacuous) repo-config fields each; final fix was an inline 2-field parse per skill, not a bare cross-plugin Read of the issues plugin's skills/lib/repo-config.md (which cannot resolve — plugins are file-sandboxed)
metadata:
  type: project
---

# Cross-plugin lib sharing, resolved for real config needs

Follow-up to [[project_cross-plugin-lib-sharing-unresolved]], which
documented that the "vacuous guard" resolution (zero repo-config
coupling) applied to `pr-ready`/`pr-draft`/`pr-link-issue`/`pr-diff`/
`pr-review-submit` — five GitHub-only `gh` wrappers with no other
backend to branch on. That memory left one case open: what about a
skill that needs *real*, per-repo-varying config values, not a
backend guard?

`gh:branch-create` (needs `default-issue-source-branch` +
`issue-branch-naming-prefix`) and `github-prs:pr-create` (needs
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
contract" question from
[[project_cross-plugin-lib-sharing-unresolved]]'s "How to apply
generally" section, applied to the case that memory left unresolved
(real fields, not a vacuous guard). Both the skill's own SKILL.md and
its plugin's README.md needed the fix — the README had independently
drifted to also claim `pr-diff`/`pr-review-submit` read repo-config
"internally", which was already false before this pass (verified by
reading both SKILL.md files: they read no repo-config at all).

**How to apply generally:** when a new cross-plugin skill's repo-config
need turns out to be a small, real (non-vacuous) field set — not the
full six-field contract — inline the parse. Don't reach for a bare
`skills/lib/repo-config.md` cross-plugin reference (it silently
doesn't work) and don't duplicate the 496-line lib into the new
plugin (churn, drift risk). Reserve the full reader contract for
readers that actually consume the whole thing (schema-version gating,
`github-project:`/`jira:` block resolution) — today that means readers
living inside the `issues` plugin itself, or a plugin willing to bundle
a duplicate copy (the debt-laden `sdlc` precedent this issue #143 PR
just removed — see the `sdlc` plugin's dependency list, now
`["issues", "gh", "github-prs"]` with zero repo-config lib coupling of
its own).

**Same bug, same fix, one more surface:** deleting
`plugins/sdlc/skills/lib/repo-config.md` (per this issue's design)
broke a bare `skills/lib/repo-config.md` reference that had been
*silently working* in all four `sdlc` agents before this PR — not
because it correctly resolved into the `issues` plugin, but because
`sdlc`'s own duplicate copy happened to sit at that exact relative
path and satisfied the bare `Read`. `pr-reviewer` still needs one real
field (`issue-link-prefix`, for recognizing `References:` trailers —
an issue-tracker concern, independent of the PR-diff/review-post
mechanics `github-prs` now owns) after the duplicate's removal, so it
got the same inline-parse treatment as `branch-create`/`pr-create`
above. Lesson: when removing a shared lib duplicate, grep every
consumer for the bare reference — it may have been "working" only by
coincidental path overlap, not by a real cross-plugin resolution
mechanism.
