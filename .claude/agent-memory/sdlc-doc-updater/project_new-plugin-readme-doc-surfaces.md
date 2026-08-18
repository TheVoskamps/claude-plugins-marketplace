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

- `docs/plugin-authoring-constraints.md` → "Sharing behavior (a parse, a
  lookup, a derivation)" names the **registration surfaces** of a new
  skill. A plugin README that rosters its own skills is one of them, so
  that sentence has to name the plugin roster alongside `plugin.json`
  and the root README bullet — the round that creates such a roster is
  exactly the round that would otherwise falsify it.
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
- `plugins/issues/skills/repo-config/SKILL.md`'s opening paragraph is a
  SECOND reader roster in that plugin ("read by the multi-issue
  orchestrator, by its `sdlc:pr-review-pipeline` review skill, and by
  every `/issue-*` skill"), and the `lib/repo-config.md` grep that finds
  the Migration-policy one does not reach it — its wording names no
  field. The two rosters are separate edits: PR #283 needed both, and
  repairing Migration policy leaves this one untouched. Grep
  `plugins/issues/` for `multi-issue orchestrator`, not for the field
  name.

Both reader-roster edits are insertions into an already-wrapped
paragraph, so they land ragged and they land as an ordinal ("is the
third such reader") — a tally that rots the next time a reader joins.
Reflow the whole paragraph and write the new reader in without
counting it. A later fixer round that only tightens the new skill's
own procedure has no other doc impact, so those leftovers are the
whole pass.

The CLAUDE.md sweep paragraph's "the README owns X and nothing else, so
it takes an edit when …" clause is the leftover that survives a review
round: on PR #283 a fixer reconciled exactly one instance of it (the
root README bullet now spells a skill name, so "no behavior to falsify"
became "no *contract* to falsify") and left the plugin README's own
non-roster claims — the frontmatter keys it spells for a whole class
(`isolation: worktree` on every agent, `user-invocable: false` on the
non-verb skills) and the one sequencing fact no other file states
(`/sdlc:orchestrate` does not invoke the grooming skill) — outside both
trigger lists. Settle the last one by grepping the skill name across
`plugins/`: the orchestrator's own SKILL.md naming it nowhere is what
makes the README load-bearing rather than a restatement.

**Why:** each is a list presented as complete, and each is written by an
agent grading its own change in the same commit.

**How to apply:** when a diff adds `plugins/<p>/README.md` at all, treat
the README's own claim-bearing paragraphs as unverified prose, and check
the CLAUDE.md sweep paragraph the same round wrote — its "takes an edit
only when X" clause is normally narrower than what the README actually
carries, and the README's own ownership paragraph has to state the same
triggers.
