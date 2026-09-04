# sdlc

End-to-end issue orchestration: groom an issue until it can be
implemented without stopping to ask, plan and delegate the
implementation of one or more issues across parallel teammate agents,
review the resulting PRs through a theorem-based pipeline, and hand
the human a set of PRs to bless.

## Find the owner of a statement before you edit it

This plugin's hazard is duplication. Its behavior is described across
an agent file, a skill body, this README and the repo's `docs/`, and
nothing tests prose, so a change made in one place leaves the others
asserting the opposite. Every fact has exactly one owner: edit the
owner, repair pointers elsewhere, and never let a second file restate
the fact.

| Fact | Owner |
| --- | --- |
| Which skills, agents and executables the plugin ships, and its `dependencies` edges | this file |
| What one agent does | that agent's own file under `agents/` |
| What a review checks and how it is reported | `agents/theorem-based-pr-reviewer.md` |
| Which generator tier a round gets | `agents/theorem-based-pr-reviewer.md` |
| How the orchestrator sequences the flow and briefs each teammate | `skills/orchestrate/SKILL.md` |
| How a generator turns a PR into theorems, and what may be emitted at all | `skills/theorem-generation/SKILL.md` |
| What a brief parameter and a consequence class mean | `skills/theorem-agents-interface/SKILL.md` |
| An agent's `model:` and `effort:` | that agent's frontmatter |

Some owners are worth spelling out, because the obvious guess is wrong.
The review procedure is an **agent**, not a skill, so both
`/sdlc:orchestrate` and `/sdlc:git-review-pr` reach it by spawning it,
and a change to what a review does touches the reviewer, both callers,
and — when it changes which agents a round spawns —
`docs/plugin-authoring-constraints.md`'s worked fan-out instance. And
this file is a **roster**, not a contract: the rosters below carry a
one-line purpose and a pointer, never a restatement. A README that
added a copy of a contract would add a surface to sweep — one that no
test and no doc pass naturally opens — and it would go stale silently.
When something here and an owner file disagree, the owner file wins
and this file is the thing to fix.

Frontmatter has one deliberate exception: `skills/orchestrate/SKILL.md`
states the teammates' `effort: medium` default, twice, because effort
has no `Agent`-tool override and the value is a decision rather than a
per-agent tier. Both statements name the off-default generators as
exceptions, and a PR changing any teammate's effort updates both.

## Sweep a contract change by grepping the string, not the file list

Nothing here is refactor-safe by construction, so derive the sweep
rather than recalling it:

- A renamed heading: grep the quoted title across the repo, and compare
  each pointer against the heading **line**, joining a wrapped quote
  back across its line breaks first. A pointer that quotes only the
  readable half of a subtitled heading still greps to a hit.
- A renamed workflow section in `agents/theorem-based-pr-reviewer.md`:
  its headings are named rather than numbered, precisely so that
  inserting one renames nothing, but a rename is still a cross-file
  sweep. Grep the quoted heading repo-wide, then read that agent's body
  end to end — it refers to its own sections by name throughout, and a
  reference wrapped across two lines survives a single-line grep.
- A changed count or roster: a back-reference like "those three" goes
  stale in silence. Read the paragraph; don't trust the grep.

Surfaces outside this plugin that a contract change reaches:
`plugins/github-prs/` attributes PR verbs to named `sdlc` agents in its
README and in several of its skills, so settle that list by grepping
the agent names across that plugin rather than by recalling which files
carried them last time.
`plugins/issues/` deliberately names no `sdlc` reader of its
repo-config, for the reason `plugins/issues/README.md` gives — do not
add one back.

## A spawn template and its receiving agent are one change

The orchestrator's teammate briefs are two-sided, and the receiving
side is the half that stays stale. When you widen a spawn template in
`skills/orchestrate/SKILL.md`, repair the bullet **list** under the
receiving agent's `## Inputs`, matching it against the template field
by field. The prose around that list often already reads as if it
covered the new field, which is what makes the omission survive review.

The load-bearing half is what a brief may **not** carry:
`issue-developer`'s Inputs says nothing of an issue's content reaches
it, and the spawn template carries no title, body, labels or file
list. The two agree only because both were changed together, so
re-adding either end silently falsifies the other. Both contracts are
justified once, in SKILL.md's "Spawn-prompt principle" and
"Report-consumption principle"; every other mention is a pointer, and
what follows a pointer is that site's application of the rule, never
the rule restated.

SKILL.md's `Phase 1` / `Phase 2` / `Phase 3` headings stay as they
are. They read as sequence names, but they are load-bearing across the
file's report templates and a Hard Constraint, so renaming them is a
cross-file refactor rather than a doc-pass sweep.

What this file *does* own is the roster itself: which skills, which
agents and which executables the plugin ships, plus the `dependencies`
edges and the cross-plugin skills those edges cover. A PR that adds,
removes, or renames a skill or an agent updates the matching table
below, and so does one that changes a user verb's argument shape — the
Skill column spells that shape, and a human reading a roster rather
than a skill file has nowhere else to find it. A PR that changes which
cross-plugin skill this plugin invokes updates "Dependencies" at the
end.

Not everything below is a roster entry, and what is not has a trigger
of its own. The frontmatter keys spelled here hold for a whole class —
`isolation: worktree` on every agent, `user-invocable: false` on the
skills that are not user verbs — so a PR changing either key edits
this file. And the sequencing of `/sdlc:orchestrate-ready` in front of
`/sdlc:orchestrate` is stated here and nowhere else, so a PR that
changes how the two relate edits it here.

## Skills

| Skill | Purpose | Where it runs |
| ------- | --------- | --------------- |
| `/sdlc:orchestrate-ready <issue>` | Groom one issue up to the bar the orchestrator needs, then flip its status | main session, interactive |
| `/sdlc:orchestrate <issue>…` | Plan, delegate, and coordinate the end-to-end fix for one or more issues | main session |
| `/sdlc:git-review-pr <PR> [--generator <name>] [--full]` | Review one PR — a thin standalone wrapper that spawns the reviewer agent | main session |
| `sdlc:theorem-generation` | How a generator turns a PR into disprovable theorems | preloaded into each generator agent |
| `sdlc:theorem-agents-interface` | What the reviewer's brief parameters and the consequence classes mean | preloaded into each theorem agent |
| `sdlc:agent-result-persist-interface` | What the `sdlc-agent-result-persist` CLI does — its modes, flags, paths and record grammar | preloaded into the reviewer, each generator variant, the disprover, and the verifier |

`theorem-generation`, `theorem-agents-interface` and
`agent-result-persist-interface` carry no leading slash here because
they are not user verbs — each declares `user-invocable: false`, which
keeps it out of the human `/` menu while leaving it invocable.
`theorem-generation` is preloaded into each
`theorem-generator` variant through that agent's `skills:`
frontmatter, and `theorem-agents-interface` into every theorem agent
— the generator variants, `theorem-disprover`, and
`counterexample-verifier` — the same way. `theorem-based-pr-reviewer`
reads `theorem-agents-interface` by name as well, for the class
glosses it grades its own theorem-less findings by.

The review procedure is absent from that table because it is an agent
rather than a skill, per "Find the owner of a statement before you
edit it" above. Why a fan-out procedure lives in one agent rather than
in a skill its subagents preload is worked through in
`docs/plugin-authoring-constraints.md` →
"Fanning out parallel agents: one home for the procedure".

`/sdlc:orchestrate-ready` is the grooming step in front of the flow,
and `/sdlc:orchestrate` does not invoke it — the user runs it first,
per issue, and runs the orchestrator once the issues are ready. What
it assesses an issue against, and why it is interactive rather than an
agent, is owned by `skills/orchestrate-ready/SKILL.md`.

## Executables

The plugin ships exactly one, `bin/sdlc-agent-result-persist`, whose
whole contract is owned by
`skills/agent-result-persist-interface/SKILL.md`. A PR that adds or
removes an executable edits this count.

## Files it writes

Everything this plugin persists is written by
`bin/sdlc-agent-result-persist` under the harness's per-session
scratchpad, outside every repository — a review round writes nothing to
the branch it reviews. A PR that adds or removes one of these edits this
list, the same convention "Executables" above sets. Which mode writes
each, and the record grammar the log holds, are part of that contract
and are owned by `skills/agent-result-persist-interface/SKILL.md`.

| File | What it holds |
| ------- | --------------- |
| `<scratchpad>/sdlc/theorem-based-pr-reviewer-<owner>-<repo>-pr<pr>-round<round>` | the round log |
| `<that path>-<theorem>-<agent>` | one child's full report |
| `<that path>.voided-<instant>` and `<that path>.voided-<instant>-<theorem>-<agent>` | the log and every result file of a round whose branch moved under it, set aside rather than overwritten |

The `enter` record also carries a fourth path,
`~/.claude/projects/<project>/<session>/subagents/agent-<agent-id>.jsonl`
— the harness's own transcript of that child. The script **composes**
that path and writes nothing there; recording it is what lets a
post-mortem reach a child's transcript after its worktree is gone.

**Nothing ever removes any of it, and that is deliberate.** There is no
cleanup mode, no expiry, and no sweep: a round log outlives the
worktrees of every child it names, and the voided copies outlive the
round they describe. That accumulation is the debugging trail — a
stalled or voided round is diagnosed from these files and from nothing
else, since the reviewer holds no state across a turn. Deleting on a
schedule would throw away the evidence at exactly the moment it is
wanted, so the growth is left for the session scratchpad's own lifetime
to bound.

## Agents

Every agent declares `isolation: worktree`, so the harness creates a
throwaway worktree per spawn.

| Agent | Purpose |
| ------- | --------- |
| `issue-developer` | Implements one batch of issues on one branch |
| `issue-fixer` | Applies review findings to an open PR's branch |
| `doc-updater` | Updates the docs a PR's changes falsify |
| `agent-memory-scrubber` | Curates the run's agent-memory inbox onto the PR |
| `pr-finalizer` | Appends the run's final section to a finished PR's body |
| `theorem-based-pr-reviewer` | Reviews one PR, fanning out the generator, the disprovers, and the verifiers from inside itself |
| `theorem-generator` | Searches one PR for claims worth trying to disprove |
| `theorem-generator-medium` | The same generator at a higher reasoning tier |
| `theorem-generator-high` | The same generator at a higher reasoning tier still |
| `theorem-generator-xhigh` | The same generator at the highest reasoning tier |
| `theorem-disprover` | Tries to break exactly one theorem |
| `counterexample-verifier` | Tries to reject exactly one disprover's counterexample |

### The generator skeletons are copies of one file

`agents/theorem-generator.md`, `-medium`, `-high` and `-xhigh` are
byte-identical except the frontmatter `name:` and `effort:` lines and
the tier phrase in `description:`. Generation instructions live in
`skills/theorem-generation/SKILL.md`, preloaded into each skeleton, so
picking a tier is picking which definition to spawn rather than
passing a parameter. After editing any skeleton, prove the others
match:

```bash
for v in medium high xhigh; do
  diff plugins/sdlc/agents/theorem-generator.md \
       plugins/sdlc/agents/theorem-generator-$v.md
done
```

Only those lines may differ. A skeleton must not carry generation
guidance, and must not *enumerate* what the skill supplies — a list of
the skill's sections is byte-identical across all four skeletons, so
the `diff` passes while every copy names a section set the skill no
longer has. Point at the whole file instead.

`theorem-disprover` and `counterexample-verifier` are deliberately not
skeleton sets: one definition each, no tiers, and a `model` the
reviewer routes per spawn. A frontmatter `model:` is only the default
for an unrouted spawn, and no file outside that frontmatter spells the
value — which is what keeps a model change a one-file edit.

## Dependencies

`plugin.json` declares `dependencies` on `issues`, `git-tools`,
`github-prs`, and `cc-tools`. Those edges are what guarantee the
cross-plugin skills this plugin invokes are installed and enabled
wherever it runs — the issue verbs, `git-branch-create`,
`git-issues-from-branch`, the PR verbs, `agent-memory-inbox-capture`,
and `agent-memory-inbox-cleanup`.
The same `git-tools` edge also covers
`git-cleanup-branches-and-worktrees`, which
`skills/orchestrate/SKILL.md` invokes once. The edge coordinates
install and enablement, not file access: plugins are file-sandboxed,
so nothing here reads another plugin's files (see
`docs/plugin-authoring-constraints.md`).
