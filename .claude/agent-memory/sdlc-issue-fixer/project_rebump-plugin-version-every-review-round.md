---
name: rebump-plugin-version-every-review-round
description: On this marketplace repo a fixer re-bumps the plugin version on every review round, even when the PR already bumped it — one bump per round, not one per PR.
metadata:
  type: project
---

When a fix round changes anything under `plugins/<name>/`, bump that
plugin's `version` again, even though the PR already carries a bump from
an earlier round. One bump per round of changed plugin content, not one
bump per PR.

**Why:** the repo's CLAUDE.md only states the weaker rule ("a PR that
modifies a plugin MUST also bump its version"), which a fixer can read as
already-satisfied and leave alone. The established practice is stronger,
and the evidence is in history rather than in any doc: PR #159 bumped
guardrails `0.9.6 -> 0.9.7 -> 0.9.8` across three commits on one branch
as review rounds landed (`b6cd57b`, `4a11979`). Reviewers here ask the
fixer to decide this explicitly, so it is a recurring question, not a
one-off.

**How to apply:** before committing a fix round, check whether the diff
touches `plugins/<name>/`; if so, edit `version` in
`plugins/<name>/.claude-plugin/plugin.json` as its own commit (CLAUDE.md
calls the bump "a separate, deliberate edit"). Verify the precedent is
still live rather than trusting this note —
`git log --format="%h %s" -- plugins/<name>/.claude-plugin/plugin.json`
and look for two bump commits sharing one merge PR. Note the intermediate
version is never published (main sits one behind until merge), which is
the argument *against* re-bumping — it lost, so do not re-litigate it.
