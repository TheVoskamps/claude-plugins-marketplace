# sdlc

End-to-end issue orchestration: groom an issue until it can be
implemented without stopping to ask, plan and delegate the
implementation of one or more issues across parallel teammate agents,
review the resulting PRs through a theorem-based pipeline, hand the
human a set of PRs to bless, and watch each blessed PR until it
merges.

## Find the owner of a statement before you edit it

This plugin's hazard is duplication. Its behavior is described across
an agent file, a skill body and this README, and
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
| What the close-out does on each merge-readiness state a blessed PR reports, and the bounds on its waits | `skills/orchestrate/SKILL.md` |
| What a merge-readiness brief asks of the fixer | `agents/issue-fixer.md` |
| How the finalizer's section is found and replaced on a re-run | `agents/pr-finalizer.md` |
| How a generator turns a PR — or, before one exists, the issues a batch will close — into theorems, and what may be emitted at all | `skills/theorem-generation/SKILL.md` |
| The bar an issue meets before the orchestrator runs on it, the issue-body grammar that bar keys on, and the check that grades a body against it | `skills/orchestrate-readiness/SKILL.md` |
| What a brief parameter and a consequence class mean | `skills/theorem-agents-interface/SKILL.md` |
| An agent's `model:` and `effort:` | that agent's frontmatter |

Some owners are worth spelling out, because the obvious guess is wrong.
The review procedure is an **agent**, not a skill, so both
`/sdlc:orchestrate` and `/sdlc:git-review-pr` reach it by spawning it,
and a change to what a review does touches the reviewer and both
callers. And this file is a **roster**, not a contract: the rosters
below carry a one-line purpose and a pointer, never a restatement. A README that
added a copy of a contract would add a surface to sweep — one that no
test and no doc pass naturally opens — and it would go stale silently.
When something here and an owner file disagree, the owner file wins
and this file is the thing to fix.

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
- A renamed heading in the issue-body grammar: the grammar has one
  owner, `skills/orchestrate-readiness/SKILL.md`, and its readers name
  that skill rather than spelling a heading — the writer,
  `skills/orchestrate-ready/SKILL.md`; the gate and the "Files likely
  affected" step in `skills/orchestrate/SKILL.md`; and
  `skills/theorem-generation/SKILL.md`, which keys a criterion
  theorem's `settle-mode` off the acceptance sub-headings and, on the
  issues-only brief, reads the files-affected section in place of a
  diff. So a grep for the heading literal hits the owner and one file
  outside this plugin, `plugins/issues/skills/issue-create/SKILL.md`,
  which spells the literal because the plugin sandbox keeps it from
  reaching the skill. A rename edits the owner, that file, and any
  reader whose wording no longer fits the renamed section.

Surfaces outside this plugin that a contract change reaches:
`plugins/github-prs/` attributes PR verbs to named `sdlc` agents in its
README and in several of its skills, so settle that list by grepping
the agent names across that plugin rather than by recalling which files
carried them last time.
`plugins/issues/` deliberately names no `sdlc` reader of its
repo-config, for the reason `plugins/issues/README.md` gives — do not
add one back. Its `skills/issue-create/SKILL.md` does read the
issue-body grammar, though, and spells the files-affected heading
literally, so a change to that grammar reaches that file too.

The header `style-checker` takes its rules from, `## For Authors and
Checkers`, is spelled in the global style guides under
`~/.claude/docs/rules/` — outside this repository, so a rename there
never shows up in a grep here — and in their per-repo extension files.
By the checker's own wording a guide without that header contributes no
rules, so a renamed header makes the pass report clean rather than
fail. A PR that renames it in the guides edits `agents/style-checker.md`
and the orchestrator's roster line and spawn prompt in the same change.

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
this file. And how `/sdlc:orchestrate-ready` and `/sdlc:orchestrate`
relate — one writes a body up to the bar, the other refuses a body
below it, and neither runs the other — is summarised here, so a PR
that changes how the two relate edits it here. So are the stages a
blessed PR goes through and the split between the gate that reports a
merge state and the teammate that remedies it, so a PR that reorders
those stages or moves a remedy edits it here.

## A blessed PR is gated on merge readiness, and the gate never remedies

The human's end-of-loop blessing authorizes the ready flip and nothing
past it, and the flip is not the next thing that happens. "Ready for
review" is a draft flag; it says nothing about whether the branch is
current with its base, merges cleanly, or passes its required checks,
and a final section written while the branch is behind its base
describes commits a rebase is about to rewrite. So a blessed PR goes
through the close-out's stages in order: the agents that still put
commits on the branch (`docs-writer`, `agent-memory-scrubber`), then
the **ready loop**, which runs `github-prs:pr-ready-to-merge` and
leaves only on a state the orchestrator's table lets through; then the
linear **close-out** — the In Review flips, `pr-finalizer`, the ready
flip; then the **monitor loop**, which polls until the PR merges and
re-runs the gate while it waits; and, once per run after the last PR's
monitor loop ends, the **post-merge tail**, which owns the single
cleanup sweep and returns the primary clone to the default branch. One
PR goes through the stages at a time, because the first merge moves
the base the next PR is measured against.

The split that holds this together: the gate **reports**, and the
remedy is a teammate's. The orchestrator never runs `git rebase` or
`git merge` or hand-edits a conflict in the primary clone. A branch the
gate finds `BEHIND` or `DIRTY` is handed to `issue-fixer` through the
same fixer-brief comment the review loop uses, carrying the gate's
report verbatim, and the fixer's return is followed by the memory
scrub and the gate again rather than a review round — so `issue-fixer` performs merge-readiness
remedies as well as review fixes, and the two kinds of brief are told
apart by whether the brief carries findings. What each state drives,
and every wait bound in the loops, is owned by
`skills/orchestrate/SKILL.md`, and each bound is a declared starting
value rather than a measured one.

Because every failed gate means the close-out is run again, each of
its steps is safe to repeat: the status flips repeat harmlessly, the
ready flip no-ops on a PR already ready, and `pr-finalizer` finds a
detail chain a previous run posted and leaves it alone, and finds its
own marked section in the body and overwrites it, so a reader never
meets a stale section before the current one.

## The issue is the ceiling of the fix loop

An issue's acceptance section is the ceiling of the fix loop, not
its floor. A review finding whose fix lies outside it, or a diff that
already reaches past it, is the human's to admit or refuse, and the
orchestrator never admits one on its own. That boundary is enforced by
slots that must be filled rather than by prose asking for judgment, and
each slot has one owner:

| Slot | Owner |
| --- | --- |
| The `Scope:` block that ends the developer's report | `agents/issue-developer.md` |
| The gate that reads that block before the first review round | `skills/orchestrate/SKILL.md` |
| The scope ruling every finding line of a fixer brief ends in, and what it is derived from | `skills/orchestrate/SKILL.md` |
| What a fixer does with a ruled finding line, and with one that has no ruling | `agents/issue-fixer.md` |
| The rule that a finding class recurring on consecutive rounds is a design question | `skills/orchestrate/SKILL.md` |
| The grading of an issue body's structural instruction against the repo | `skills/orchestrate/SKILL.md` |
| How a finding dropped on a scope ruling reaches the next round and retires | `agents/theorem-based-pr-reviewer.md` |
| How a finding dropped on a scope ruling is worded in the PR's final section | `agents/pr-finalizer.md` |

The reviewer's own scope theorem, in `skills/theorem-generation/SKILL.md`,
is unchanged by any of this: the slots make the orchestrator act on
the theorem's answer, and none of them changes how that answer is
produced. A scope ruling is the orchestrator's judgment, never the
human's, and the reviewer keeps the two apart by retiring a
scope-dropped theorem under its own label rather than as
human-refuted.

## The theorem set is seeded from the issues before the developer runs

The first theorem list the human sees is generated from the issues
alone and ruled on before the batch's developer is spawned, so a
developer that goes beyond the issues, or decides something they do
not, surfaces in the first review round as new theorems against a list
the human already owns. That seed is **round 0**: rounds count
implementer passes from 1, and 0 is the pre-loop stage. The generator
runs on an issues-only brief and its return is held, not persisted —
every path `bin/sdlc-agent-result-persist` composes is keyed on a PR
number, and none exists yet — until the developer's PR is open and
linked, when the ruled list is written as round 0's records file.
Round 0 holds that one file, so a walk that starts at round 1 never
sees it, and a PR with no round 0 — one reviewed outside the
orchestrate loop, or one whose seed was lost with the session that
took it — is reviewed from its whole diff, with the review saying so.
Each piece has one owner:

| Slot | Owner |
| --- | --- |
| The issues-only brief, and what a generator emits on it | `skills/theorem-agents-interface/SKILL.md` and `skills/theorem-generation/SKILL.md` |
| The seed spawn, the tier pick against the issue bodies, the per-theorem ruling, and the round-0 write | `skills/orchestrate/SKILL.md` |
| Round 0 as a valid round number holding only a records file | `skills/agent-result-persist-interface/SKILL.md` |
| A record without `state`, the seed ruling as a `human-refuted` source, and round 1's delta over the whole branch | `agents/theorem-based-pr-reviewer.md` |
| The files-affected section the seed generator reads in place of a diff | `skills/orchestrate-readiness/SKILL.md` |

## Skills

| Skill | Purpose | Where it runs |
| ------- | --------- | --------------- |
| `/sdlc:orchestrate-ready <issue>` | Groom one issue until the readiness check passes, then flip its status | main session, interactive |
| `/sdlc:orchestrate <issue>…` | Plan, delegate, and coordinate the end-to-end fix for one or more issues, refusing any that fails the readiness check | main session |
| `/sdlc:git-review-pr <PR> [--generator <name>] [--full]` | Review one PR — a thin standalone wrapper that spawns the reviewer agent | main session |
| `sdlc:theorem-generation` | How a generator turns a PR, or the issues a batch will close, into disprovable theorems | preloaded into each generator agent |
| `sdlc:theorem-agents-interface` | What a theorem agent's brief parameters and the consequence classes mean | preloaded into each theorem agent |
| `sdlc:agent-result-persist-interface` | What the `sdlc-agent-result-persist` CLI does — its modes, flags, paths and record grammar | preloaded into the reviewer, each generator variant, the disprover, the verifier, and `pr-finalizer` |
| `sdlc:documentation-definition` | What counts as documentation rather than code | preloaded into the agents that decide which files they may edit or review |
| `sdlc:orchestrate-readiness` | The bar an issue meets before the orchestrator runs on it, the issue-body grammar, and the check that returns what a body is missing as a gap list | invoked by the grooming skill and the orchestrator; preloaded into each generator variant |

The rows with no leading slash are not user verbs — each declares
`user-invocable: false`, which
keeps it out of the human `/` menu while leaving it invocable.
`theorem-generation` and `orchestrate-readiness` are preloaded into
each `theorem-generator` variant through that agent's `skills:`
frontmatter, and `theorem-agents-interface` into every theorem agent
— the generator variants, `theorem-disprover`, and
`counterexample-verifier` — the same way. `theorem-based-pr-reviewer`
reads `theorem-agents-interface` by name as well, for the class
glosses it grades its own theorem-less findings by.

The review procedure is absent from that table because it is an agent
rather than a skill, per "Find the owner of a statement before you
edit it" above. Every caller spawns that one agent to run the fan-out,
so the procedure is its body: a skill wrapping a procedure only one
agent ever runs would split one contract across two files that must
agree, and an agent body is already loaded at spawn.

`/sdlc:orchestrate-ready` is the grooming step in front of the flow,
and `/sdlc:orchestrate` does not invoke it — the user runs it first,
per issue, and runs the orchestrator once the issues are ready. Both
invoke the same check, `orchestrate-readiness`: the grooming skill
rewrites the body until the check returns no gap, and the orchestrator
runs the check on every issue it is given before any analysis and
stops, before a branch or a PR exists, on the first non-empty gap
list, naming the grooming skill rather than running it — grooming is a
conversation with the human, and the orchestrator is not one. The bar
and the grammar are owned by `skills/orchestrate-readiness/SKILL.md`;
why grooming is interactive rather than an agent is owned by
`skills/orchestrate-ready/SKILL.md`.

## Executables

The plugin ships exactly one, `bin/sdlc-agent-result-persist`, whose
whole contract is owned by
`skills/agent-result-persist-interface/SKILL.md`. A PR that adds or
removes an executable edits this count.

## Files it writes

Everything the **review pipeline** persists is written by
`bin/sdlc-agent-result-persist` under XDG state, outside every
repository — a review round writes nothing to the branch it reviews. A
PR that adds or removes one of these edits this list, the same
convention "Executables" above sets. Which mode writes each, and the
record grammar the log holds, are part of that contract and are owned
by `skills/agent-result-persist-interface/SKILL.md`.

`pr-finalizer` reads that state and writes none of it. The orchestrator
writes exactly one of these files, round 0's `records` — the seed the
human ruled on before the developer ran, transcribed through the same
script. The implementing
agents are outside the claim entirely and write nothing this
list owns: those declaring `memory: project` capture their agent memory
into the session's inbox, each of them but `style-checker` commits its
work to the branch, and `agent-memory-scrubber` commits what that inbox
transfers.

Write `<round-dir>` for
`${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/<owner>/<repo>/pr<pr>/round<round>`,
the round's own directory:

| File | What it holds |
| ------- | --------------- |
| `<round-dir>/log` | the round log |
| `<round-dir>/<theorem>-<agent>` | one child's full report |
| `<round-dir>/records` | the round's theorem records, which the next round carries forward; round 0's is the ruled seed |
| `<round-dir>/review` | the round's argued review, which the posted review summarises and `pr-finalizer` posts in full once the loop concludes |
| `<round-dir>.voided-<instant>/` | the whole directory of a round whose branch moved under it, set aside rather than overwritten |

The PR number keys the path because a PR is worked by one orchestrate
run, and the agent tree under it, at a time. Nothing in the path names
a session, so any reviewer spawned over that PR reads the round an
earlier instance left behind — the same run's re-spawn after an
in-progress return, and equally a spawn from a later session, such as
`/sdlc:git-review-pr <PR>`. Finding it is the reviewer's own job, per
`agents/theorem-based-pr-reviewer.md` → "Read the round log, then
anchor the round", which it runs on every spawn; no caller looks for
the log on its behalf.

The `enter` record also carries a path outside that directory,
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
wanted. A `pr<N>/` stays after its PR merges or closes, and nothing
here bounds that growth — removing one is the operator's own call.

## Agents

Every agent declares `isolation: worktree`, so the harness creates a
throwaway worktree per spawn.

| Agent | Purpose |
| ------- | --------- |
| `issue-developer` | Implements one batch of issues on one branch |
| `issue-fixer` | Applies review findings, or a merge-readiness remedy — a rebase onto the base, resolving the conflicts the brief lists — to an open PR's branch |
| `code-documenter` | Adds or corrects the comments the style guides require in a round's code, before its review |
| `style-checker` | Reports a round's style-guide violations for the human to rule on, before its review |
| `docs-writer` | Writes a PR's documentation once, after its review loop ends |
| `agent-memory-scrubber` | Curates the run's agent-memory inbox onto the PR |
| `pr-finalizer` | Posts the run's assembled review detail to a finished PR and writes the run's final section into its body, replacing the one an earlier run left |
| `theorem-based-pr-reviewer` | Reviews one PR, fanning out the generator, the disprovers, and the verifiers from inside itself |
| `theorem-generator` | Searches one PR — or, before one exists, the issues a batch will close — for claims worth trying to disprove |
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
so nothing here reads another plugin's files.
