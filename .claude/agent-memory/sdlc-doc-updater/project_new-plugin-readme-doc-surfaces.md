---
name: new-plugin-readme-doc-surfaces
description: A round that adds a user-facing skill AND writes the plugin's first README leaves three enumerations stale — plugin-authoring-constraints' registration-surface sentence, the new README's own dependencies list, and issues/lib repo-config's sdlc-reader roster
metadata:
  type: project
---

A round that ships a new user-facing skill in an existing plugin *and*
writes that plugin's first `README.md` (PR #283, `sdlc:orchestrate-ready`)
updates the loud surfaces itself — `plugin.json` `description`, the root
`README.md` roster bullet, the repo `CLAUDE.md` sweep section. The
enumerations it leaves stale, none of them next to the diff:

- `docs/plugin-authoring-constraints.md` → "Sharing behavior…" names the
  **registration surfaces** of a new skill (`plugin.json` description +
  root README bullet). A plugin README that rosters its own skills is a
  third one, and the round that creates that roster is exactly the round
  that falsifies the sentence.
- The new README's `dependencies` paragraph enumerates the cross-plugin
  skills the edges cover. Settle it by grepping the plugin tree for each
  dependency's skill names — `sdlc` invokes
  `git-cleanup-branches-and-worktrees` too, and the hand-written list had
  only `git-branch-create` / `git-issues-from-branch`.
- `plugins/issues/skills/lib/repo-config.md` → "Migration policy" names
  the `sdlc` readers and *which field each still parses*. A new skill
  that reads `github-project.fields.status.options` joins that roster;
  editing it costs an `issues` version bump, which is why it gets
  skipped. See [[agent-retirement-doc-surfaces]] for the same file on the
  removal side.

**Why:** each is a list presented as complete, and each was written by an
agent grading its own change in the same commit.

**How to apply:** when a diff adds `plugins/<p>/README.md` at all, treat
the README's own claim-bearing paragraphs as unverified prose, and check
the CLAUDE.md sweep paragraph the same round wrote — its "takes an edit
only when X" clause is normally narrower than what the README actually
carries.
