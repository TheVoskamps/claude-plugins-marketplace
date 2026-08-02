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
  near the top (one bullet per agent, each closing with what that agent
  leaves behind — a push, a PR, or a posted review). It restates each
  agent's contract in one line and is the thing a PR touching only
  `agents/*.md` forgets.
- The same SKILL.md restates a contract a second and third time in
  running prose: the "After each issue-developer or issue-fixer"
  section and the fix-loop's `doc-updater` step both spell out the
  no-doc-impact outcome. A change to an agent's Output section can
  falsify all three sites at once — grep the agent name across
  SKILL.md rather than fixing only the roster bullet.
- Cross-reference strings: `plugins/sdlc/agents/doc-updater.md` and
  SKILL.md's own fix-loop step quote a `### After each ...` heading
  verbatim; the roster quotes no heading. Renaming a heading in
  SKILL.md means grepping the quoted title across `plugins/sdlc/`.
- Not stale-prone: root `README.md`'s one-line `sdlc` bullet,
  `plugins/github-prs/README.md`, `plugins/issues/skills/**` — these
  name the agents only as a list, never their behavior.
- `docs/plugin-migration-plan.md` mentions the agents but is a frozen
  historical plan; never edit it (see [[plugin-docs-locality]]).

**Why:** an sdlc PR's real diff is `agents/*.md` + `orchestrate/SKILL.md`,
and SKILL.md is where an agent's contract gets duplicated outside that
agent's own file.

**How to apply:** on any sdlc PR, after reading the diff, grep SKILL.md
for each agent the PR touched and check every hit — roster bullet,
section prose, fix-loop step — against that agent's current Output
section.

Judgment call worth keeping (mine, not the user's): SKILL.md's
`Phase 1 / Phase 2 / Phase 3` headings violate the writing-style
no-sequence-names rule, but they are load-bearing across the file's
own report templates and a Hard Constraint ("wait for confirmation
before starting Phase 2"). Renaming them is a cross-file refactor, not
a doc-pass sweep — leave them and say so in the report rather than
churning on them each round.
