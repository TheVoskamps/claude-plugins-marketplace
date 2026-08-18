---
name: new-plugin-readme-doc-surfaces
description: Where a round that adds a user-facing skill AND writes the plugin's first README has to land edits — beyond plugin.json/root README, three enumerations away from the diff
metadata:
  type: project
---

A round that ships a new user-facing skill in an existing plugin *and*
writes that plugin's first `README.md` (PR #283, `sdlc:orchestrate-ready`)
naturally hits the loud surfaces — `plugin.json` `description`, the root
`README.md` roster bullet, the repo `CLAUDE.md` sweep section. The map of
where the rest of the edits land, none of them next to the diff:

- `docs/plugin-authoring-constraints.md` → "Sharing behavior…" names the
  **registration surfaces** of a new skill. A plugin README that rosters
  its own skills is one of them, so that sentence has to name the plugin
  roster alongside `plugin.json` and the root README bullet — the round
  that creates such a roster is exactly the round that would otherwise
  falsify it.
- The new README's `dependencies` paragraph enumerates the cross-plugin
  skills the edges cover. Settle it by grepping the plugin tree for each
  dependency's skill names rather than writing the list from memory —
  `sdlc` invokes `git-cleanup-branches-and-worktrees` as well as
  `git-branch-create` / `git-issues-from-branch`.
- `plugins/issues/skills/lib/repo-config.md` → "Migration policy" names
  the `sdlc` readers and *which field each still parses*. A new skill
  that reads `github-project.fields.status.options` joins that roster;
  editing it costs an `issues` version bump, which is why it is the one
  most easily skipped. See [[agent-retirement-doc-surfaces]] for the same
  file on the removal side.

**Why:** each is a list presented as complete, and each is written by an
agent grading its own change in the same commit.

**How to apply:** when a diff adds `plugins/<p>/README.md` at all, treat
the README's own claim-bearing paragraphs as unverified prose, and check
the CLAUDE.md sweep paragraph the same round wrote — its "takes an edit
only when X" clause is normally narrower than what the README actually
carries, and the README's own ownership paragraph has to state the same
triggers.
