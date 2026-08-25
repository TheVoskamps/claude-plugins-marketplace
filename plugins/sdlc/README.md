# sdlc

End-to-end issue orchestration: groom an issue until it can be
implemented without stopping to ask, plan and delegate the
implementation of one or more issues across parallel teammate agents,
review the resulting PRs through a theorem-based pipeline, and hand
the human a set of PRs to bless.

## This README points; it does not restate

Every contract in this plugin has exactly one owner, and it is never
this file. An agent's contract — what it does, what it commits, when
it runs — is owned by that agent's own definition under `agents/`.
What a review checks and how it is reported is owned by
`agents/theorem-based-pr-reviewer.md`. What a generator may emit is
owned by `skills/theorem-generation/SKILL.md`. What the reviewer's
briefs to the theorem agents mean, and what a consequence class means,
is owned by `skills/theorem-agents-interface/SKILL.md`. How the whole
flow is sequenced, what each teammate is briefed with, and the
condition each teammate's return leaves the orchestrator in are owned
by `skills/orchestrate/SKILL.md`.

So the rosters below carry a one-line purpose and a pointer, never a
restatement. That is deliberate: a README that added a copy of a
contract would add a surface to sweep — one that no test and no doc
pass naturally opens — and it would go stale silently. When something
here and an owner file disagree, the owner file wins and this file is
the thing to fix.

What this file *does* own is the roster itself: which skills and which
agents the plugin ships, plus the `dependencies` edges and the
cross-plugin skills those edges cover. A PR that adds, removes, or
renames a skill or an agent updates the matching table below, and so
does one that changes a user verb's argument shape — the Skill column
spells that shape, and a human reading a roster rather than a skill
file has nowhere else to find it. A PR that changes which cross-plugin
skill this plugin invokes updates "Dependencies" at the end.

Not everything below is a roster entry, and what is not has a trigger
of its own. The frontmatter keys spelled here hold for a whole class —
`isolation: worktree` on every agent, `user-invocable: false` on the
skills that are not user verbs — so a PR changing either key edits
this file. And the sequencing of `/sdlc:orchestrate-ready` in front of
`/sdlc:orchestrate` is stated here and nowhere else in the plugin, so
a PR that changes how the two relate edits it here — and the repo's
`CLAUDE.md`, which records that this file owns the statement and
therefore states it too, with it.

## Skills

| Skill | Purpose | Where it runs |
| ------- | --------- | --------------- |
| `/sdlc:orchestrate-ready <issue>` | Groom one issue up to the bar the orchestrator needs, then flip its status | main session, interactive |
| `/sdlc:orchestrate <issue>…` | Plan, delegate, and coordinate the end-to-end fix for one or more issues | main session |
| `/sdlc:git-review-pr <PR> [--generator <name>] [--full]` | Review one PR — a thin standalone wrapper that spawns the reviewer agent | main session |
| `sdlc:theorem-generation` | How a generator turns a PR into disprovable theorems | preloaded into each generator agent |
| `sdlc:theorem-agents-interface` | What the reviewer's brief parameters and the consequence classes mean | preloaded into each theorem agent |

`theorem-generation` and
`theorem-agents-interface` carry no leading slash here because they
are not user verbs — each declares `user-invocable: false`, which
keeps it out of the human `/` menu while leaving it invocable.
`theorem-generation` is preloaded into each
`theorem-generator` variant through that agent's `skills:`
frontmatter, and `theorem-agents-interface` into every theorem agent
— the generator variants, `theorem-disprover`, and
`counterexample-verifier` — the same way. `theorem-based-pr-reviewer`
reads `theorem-agents-interface` by name as well, for the class
glosses it grades its own theorem-less findings by.

The review procedure itself is not a skill: it lives in
`agents/theorem-based-pr-reviewer.md`, the agent both
`/sdlc:orchestrate` and `/sdlc:git-review-pr` spawn, which fans out
parallel subagents of its own. The worked reasoning is in
`docs/plugin-authoring-constraints.md` →
"Fanning out parallel agents: one home for the procedure".

`/sdlc:orchestrate-ready` is the grooming step in front of the flow,
and `/sdlc:orchestrate` does not invoke it — the user runs it first,
per issue, and runs the orchestrator once the issues are ready. What
it assesses an issue against, and why it is interactive rather than an
agent, is owned by `skills/orchestrate-ready/SKILL.md`.

## Agents

Every agent declares `isolation: worktree`, so the harness creates a
throwaway worktree per spawn. Each one's frontmatter is the sole
source of truth for its `model` and `effort`; no value is spelled
here.

| Agent | Purpose |
| ------- | --------- |
| `issue-developer` | Implements one batch of issues on one branch |
| `issue-fixer` | Applies review findings to an open PR's branch |
| `doc-updater` | Updates the docs a PR's changes falsify |
| `agent-memory-scrubber` | Curates the run's agent-memory inbox onto the PR |
| `theorem-based-pr-reviewer` | Reviews one PR, fanning out the generator, the disprovers, and the verifiers from inside itself |
| `theorem-generator` | Searches one PR for claims worth trying to disprove |
| `theorem-generator-medium` | The same generator at a higher reasoning tier |
| `theorem-generator-high` | The same generator at a higher reasoning tier still |
| `theorem-generator-xhigh` | The same generator at the highest reasoning tier |
| `theorem-disprover` | Tries to break exactly one theorem |
| `counterexample-verifier` | Tries to reject exactly one disprover's counterexample |

The generator definitions are skeletons over
`skills/theorem-generation/SKILL.md`, byte-identical apart from the
frontmatter lines naming the definition and its tier, so picking a
tier is picking which definition to spawn. The
repo's `CLAUDE.md` → "The generator skeletons are copies of one file"
carries the invariant and the `diff` check that enforces it.

Which agents write memory, and which write nothing at all, is stated
in `skills/orchestrate/SKILL.md`. No agent memory reaches a commit:
the writers capture the entries that outlive their run into a
session-scoped inbox under the harness scratchpad, and
`agent-memory-scrubber` transfers the durable ones into `CLAUDE.md` or
`docs/` and deletes the rest. The
repo's `CLAUDE.md` → "Review writes nothing, so review lore is a PR"
says how the review side's silence is enforced and where a review
lesson lands instead.

## Dependencies

`plugin.json` declares `dependencies` on `issues`, `git-tools`,
`github-prs`, and `cc-tools`. Those edges are what guarantee the
cross-plugin skills this plugin invokes are installed and enabled
wherever it runs — the issue verbs, `git-branch-create`,
`git-issues-from-branch`, the PR verbs, `agent-memory-inbox-capture`,
and `agent-memory-inbox-cleanup`.
The same `git-tools` edge also covers
`git-cleanup-branches-and-worktrees`, which nothing here invokes:
`skills/orchestrate/SKILL.md` names it as the whole-repo sweep of the
same shape as the per-worktree cleanup the orchestrator performs
inline. The edge coordinates install and enablement, not file access:
plugins are file-sandboxed, so nothing here reads another plugin's
files (see `docs/plugin-authoring-constraints.md`).
