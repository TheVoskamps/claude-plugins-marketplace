# Working in plugins/sdlc

**Who reads this and when:** any agent about to edit a file under
`plugins/sdlc/`, or about to change what one of its agents does. Read it
before the first edit, not after.

The plugin's hazard is duplication. Its behavior is described across an
agent file, a skill body, a plugin README and this repo's docs, and
nothing tests prose, so a change made in one place leaves the others
asserting the opposite.

## Find the owner of a statement before you edit it

Every fact about this plugin has exactly one owner. Edit the owner;
repair pointers elsewhere; never let a second file restate the fact.

| Fact | Owner |
| --- | --- |
| Which skills and agents the plugin ships, and its `dependencies` edges | `plugins/sdlc/README.md` |
| What one agent does | that agent's own file |
| How the orchestrator drives the agents | `skills/orchestrate/SKILL.md` |
| How a generator turns a PR into theorems, and what may be emitted at all | `skills/theorem-generation/SKILL.md` |
| What a brief parameter and a consequence class mean | `skills/theorem-agents-interface/SKILL.md` |
| Which generator tier a round gets | `agents/theorem-based-pr-reviewer.md` |
| An agent's `model:` and `effort:` | that agent's frontmatter |

Some owners are worth spelling out, because the obvious guess is wrong.
The review procedure is an **agent** (`theorem-based-pr-reviewer`), not a
skill, so both `/sdlc:orchestrate` and `/sdlc:git-review-pr` reach it by
spawning it, and a change to what a review does touches the reviewer,
both callers, and — when it changes which agents a round spawns —
`docs/plugin-authoring-constraints.md`'s worked fan-out instance. And
`plugins/sdlc/README.md` is a **roster**, not a contract: it takes an
edit when a skill or agent is added, removed or renamed, and when the
frontmatter keys that hold for a whole class change, and otherwise stays
out of the way.

Frontmatter has one deliberate exception: `skills/orchestrate/SKILL.md`
states the teammates' `effort: medium` default, twice, because effort
has no `Agent`-tool override and the value is a decision rather than a
per-agent tier. Both statements name the off-default generators as
exceptions. A PR changing any teammate's effort updates both.

## Sweep a contract change by grepping the string, not the file list

Nothing in this plugin is refactor-safe by construction, so derive the
sweep rather than recalling it:

- A renamed heading: grep the quoted title across the repo, and compare
  each pointer against the heading **line**, joining a wrapped quote
  back across its line breaks first. A pointer that quotes only the
  readable half of a subtitled heading still greps to a hit.
- A renumbered workflow step in `theorem-based-pr-reviewer.md`: its
  headings are numbered, so inserting one renames every later heading
  without the diff touching it. Grep `→ "` for a leading digit
  repo-wide, then read that agent's body end to end — it also refers to
  its own steps by bare number, which no heading grep reaches.
- A changed count or roster: a back-reference like "those three" goes
  stale in silence. Read the paragraph, don't trust the grep.

Surfaces outside `plugins/sdlc/` that a contract change reaches:
`plugins/github-prs/README.md` and its `pr-diff`, `pr-review-submit`
and `pr-closing-issues` skills each attribute a PR verb to a named
`sdlc` agent, so settle that list by grepping the agent names across
`plugins/github-prs/` rather than opening the files named here.
`plugins/issues/` deliberately names no `sdlc` reader of repo-config —
a reader contract states what a file provides, never who consumes it —
so do not add one back.

## A spawn template and its receiving agent are one change

The orchestrator's teammate briefs are two-sided, and the receiving side
is the half that stays stale. When you widen a spawn template in
`skills/orchestrate/SKILL.md`, repair the bullet **list** under the
receiving agent's `## Inputs` — matching it against the template field by
field. The prose around that list often already reads as if it covered
the new field, which is what makes the omission survive review.

The load-bearing half is what a brief may **not** carry:
`issue-developer`'s Inputs says nothing of an issue's content reaches it,
and the spawn template carries no title, body, labels or file list. The
two agree only because both were changed together, so re-adding either
end silently falsifies the other. Both contracts are justified once, in
SKILL.md's "Spawn-prompt principle" and "Report-consumption principle";
every other mention is a pointer, and what follows a pointer is that
site's application of the rule, never the rule restated.

SKILL.md's `Phase 1` / `Phase 2` / `Phase 3` headings stay as they are.
They read as sequence names, but they are load-bearing across the file's
report templates and a Hard Constraint, so renaming them is a cross-file
refactor rather than a doc-pass sweep.

## The generator skeletons are copies of one file

`agents/theorem-generator.md`, `-medium`, `-high` and `-xhigh` are
byte-identical except the frontmatter `name:` and `effort:` lines and
the tier phrase in `description:`. Generation instructions live in
`skills/theorem-generation/SKILL.md`, preloaded into each skeleton, so a
tier is a choice of which definition to spawn rather than a parameter
anything passes.

After editing any skeleton, prove the others match:

```bash
for v in medium high xhigh; do
  diff plugins/sdlc/agents/theorem-generator.md \
       plugins/sdlc/agents/theorem-generator-$v.md
done
```

Only those lines may differ. A skeleton must not carry generation
guidance, and must not *enumerate* what the skill supplies — a list of
the skill's sections is byte-identical across all four skeletons, so the
`diff` passes while every copy names a section set the skill no longer
has. Point at the whole file instead.

`theorem-disprover` and `counterexample-verifier` are deliberately not
skeleton sets: one definition each, no tiers, and a `model` the reviewer
routes per spawn. A frontmatter `model:` is only the default for an
unrouted spawn, and no file outside that frontmatter spells the value —
which is what keeps a model change a one-file edit.

## Review writes nothing on the branch it reviews

`theorem-based-pr-reviewer` and the agents it spawns are non-mutating:
none declares `memory:`, none carries `Edit`, and the reviewer's `Write`
is bounded to staging its review body under `.claude/tmp/<task-slug>/`
so `/github-prs:pr-review-submit` can post it by path. Keep that
structural — no `memory:` key, no widened `Write`, no commit step, no
writing tool on a spawned agent.

A round's theorem list is no exception: the reviewer persists records in
the **review it posts** and the next round reads them back off the PR. A
PR artifact is not a branch write. Never repair a persistence gap by
giving review a file the branch would carry.

So a durable lesson learned while reviewing lands as a PR — against
`theorem-generation` (how to state a better theorem), `theorem-disprover`
(how to establish a fact), `counterexample-verifier` (how to reject a bad
counterexample), or `CLAUDE.md` — never as a memory entry.

## Agent memory never reaches a commit

Exactly three agents declare `memory: project`: `issue-developer`,
`issue-fixer`, `doc-updater`. Each ends its run by invoking
`/cc-tools:agent-memory-inbox-capture`, which copies entries into a
session-scoped inbox under the harness scratchpad.
`agent-memory-scrubber` runs after all of them and commits only the
`CLAUDE.md` and `docs/` changes it decides on. Nothing under
`.claude/agent-memory/` is ever staged, and the inbox dies with the
session.

Changing which agents declare `memory:` sweeps `skills/orchestrate/`
`SKILL.md` in two places — its frontmatter-baseline paragraph, which
later refers back to the roster by count rather than by name, and its
curation section.

The capture-then-curate flow is owned by `cc-tools` and driven by
`sdlc`, so a PR touching either side bumps **both** plugins' versions.
Couple the two sides by contract, never by string: `agent-memory-`
`scrubber` branches on the `Commit:` field of the cleanup skill's
report, not on a sentence around it. The inbox path and the grading
rubric live only in `plugins/cc-tools/skills/lib/`; an `sdlc` file that
spells either is a second source of truth, and cannot be a `Read` in any
case, since plugins are file-sandboxed.
