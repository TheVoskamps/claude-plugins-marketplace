---
name: sdlc-docs-locality
description: Where sdlc-plugin agent-contract changes land in docs — no plugins/sdlc/README.md exists; the orchestrate SKILL.md teammate roster is the stale-prone surface
metadata:
  type: project
---

The `sdlc` plugin ships **no** `plugins/sdlc/README.md`. When an agent's
contract changes (what it commits, when it runs, what it returns), the
doc surfaces that go stale are, in order of likelihood:

- `plugins/sdlc/skills/orchestrate/SKILL.md` → the teammate-agent roster
  near the top (one bullet per agent, each ending in what the agent
  pushes). It restates each agent's contract in one line and is the
  thing a PR touching only `agents/*.md` forgets.
- Cross-reference strings: the roster and the fix loop both quote
  `### After each ...` headings verbatim. Renaming a heading in
  SKILL.md means grepping the quoted title across `plugins/sdlc/`.
- Not stale-prone: root `README.md`'s one-line `sdlc` bullet,
  `plugins/github-prs/README.md`, `plugins/issues/skills/**` — these
  name the agents only as a list, never their behavior.
- `docs/plugin-migration-plan.md` mentions the agents but is a frozen
  historical plan; never edit it (see [[plugin-docs-locality]]).

**Why:** an sdlc PR's real diff is `agents/*.md` + `orchestrate/SKILL.md`,
and the roster line is the only prose that duplicates an agent's contract
outside that agent's own file.

**How to apply:** on any sdlc PR, after reading the diff, re-read the
SKILL.md roster bullet for each agent the PR touched and check it against
that agent's current Output section.

Judgment call worth keeping (mine, not the user's): SKILL.md's
`Phase 1 / Phase 2 / Phase 3` headings violate the writing-style
no-sequence-names rule, but they are load-bearing across the file's
own report templates and a Hard Constraint ("wait for confirmation
before starting Phase 2"). Renaming them is a cross-file refactor, not
a doc-pass sweep — leave them and say so in the report rather than
churning on them each round.
