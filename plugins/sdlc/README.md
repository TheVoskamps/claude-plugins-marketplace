# sdlc

End-to-end issue orchestration: groom an issue until it can be
implemented without stopping to ask, plan and delegate the
implementation of one or more issues across parallel teammate agents,
review the resulting PRs through a theorem-based pipeline, hand the
human a set of PRs to bless, watch each blessed PR until it merges,
and remove what each merged PR left behind — the worktrees its agents
ran in, its local branch and its scratch — or, when the human asks,
everything every run left in the repo. Review state is kept through
both, and deleted only when the human passes `--review-state`.

## Find the owner of a statement before you edit it

This plugin's hazard is duplication. Its behavior is described across
an agent file, a skill body, the lib files beside that body and this
README, and nothing tests prose, so a change made in one place leaves
the others asserting the opposite. Every fact has exactly one owner:
edit the owner, repair pointers elsewhere, and never let a second file
restate the fact.

| Fact | Owner |
| --- | --- |
| Which skills, agents, executables and hooks the plugin ships, and its `dependencies` edges | this file |
| What one agent does | that agent's own file under `agents/`, and for `theorem-based-pr-reviewer` also the lib files under `skills/lib/theorem-based-pr-reviewer/` that file names |
| What a review checks | `agents/theorem-based-pr-reviewer.md` |
| How the argued review a round stores is written — its sections and the finding format — the records file's field rules, and the calls that store the round and post its review | `skills/lib/theorem-based-pr-reviewer/review-body.md` |
| The reviewer's resume loop, its resume-pass loop and its deadline arm | `skills/lib/theorem-based-pr-reviewer/resume.md` |
| The round derivations — the arm a resumed round is in and the work left in each stage, each theorem's disposition, class, severity and stamped state, the per-issue and overall verdicts, and the posted review body — and the tables and rules they apply | `bin/sdlc-agent-result-persist`, under the contract `skills/agent-result-persist-interface/SKILL.md` states |
| The judgment calls that remain in the review — the tier rubric, reading an adjustment comment into an edit, each child's brief, and raising a `NEEDS_CHANGES` to `BLOCKED` for a fix outside the issue's scope | `agents/theorem-based-pr-reviewer.md` |
| Which generator tier a round gets | `agents/theorem-based-pr-reviewer.md` |
| How the orchestrator sequences the flow, what it branches on when a teammate returns, and how it briefs the teammates it spawns during the code loop | `skills/orchestrate/SKILL.md` |
| The procedure the orchestrator runs at one moment of the flow, and the briefs it spawns at that moment | the file for that moment under `skills/orchestrate/lib/` |
| What the merge-readiness loop does on each state the gate reports, which of those it returns as a question, how a ruling is matched to the question it answered, and the bounds on its waits | `agents/pr-merge-readiness.md` |
| What ends the monitor loop | `agents/pr-monitor.md` |
| Where the sdlc config tiers live, which keys they hold with what values and defaults, how the tiers resolve, what a read aborts on, and how a writer merge-updates one | `skills/lib/sdlc-config.md` |
| Which files a compaction reloads, how a skill's name is resolved to its file, what the reload message holds, how its row is drawn on screen, and what is recorded from one compaction to the next | `hooks/reload-after-compact.ts` |
| Which hook modules the plugin registers, and in what order | `hooks/register.ts` |
| What a merge-readiness brief asks of the fixer | `agents/issue-fixer.md` |
| How a PR body is cut around the finalizer's section and put back together, so a re-run replaces the section | `bin/sdlc-pr-body` |
| How the finalizer reaches a round's review state, and what each report of the detail post means for its section | `agents/pr-finalizer.md` |
| In what order the review detail is assembled, which rounds a chain holds when the PR already carries chains, how it is chunked under GitHub's comment cap, and how a piece too large for one chunk is split across chunks | `bin/sdlc-pr-post-theorem-records` |
| How the generator turns a PR — or, before one exists, the issues a batch will close — into theorems, and what may be emitted at all | `agents/theorem-generator.md` |
| What a generated theorem list is judged on before any disprover runs, what the assessment recommends, and the format it is written in | `agents/theorem-assessor.md` |
| The tier the generator runs at on one spawn, and where it is recorded | the `effort` of the `Agent` call that spawns it, which `agents/theorem-based-pr-reviewer.md` makes on a review round and on the seed alike; written to the generate-stage `spawn` record by `agents/theorem-based-pr-reviewer.md` for a review round, and by `skills/orchestrate/lib/pr-lifecycle.md` for the seed, from the tier the seed reviewer reported |
| The bar an issue meets before the orchestrator runs on it, the issue-body grammar that bar keys on — which keys a `### Mechanical` bullet may open with, what each asserts, and which of them is executed — how a body is graded against the rest of the bar, and what a mechanical gap is | `skills/orchestrate-readiness/SKILL.md` |
| The terms for a repo statement an issue contradicts — instruction file, capability claim, policy claim and test — and the search that looks for one | `skills/orchestrate-readiness/SKILL.md` |
| How the `### Mechanical` lines of both acceptance sections are graded: how a body is split into its sections and their bullets, which lines under `### Mechanical` are refused as no bullet, which paths are refused with nothing run, how a section's presence and its bullet count are settled, which heading and which list items make a section a mistitled files-affected list, which gap lines open `mechanical:`, what each gap line says, and what the check exits with | `bin/sdlc-readiness-check` |
| Which issues the check refuses before it grades a body — each refusal's condition, the order they are checked in, the line each prints, and the exit status that sets a refusal apart from a gap | `bin/sdlc-readiness-check` |
| What a brief parameter and a consequence class mean | `skills/theorem-agents-interface/SKILL.md` |
| Which file class a path falls in — code, instruction Markdown, or documentation | the global Claude configuration, outside this repository; no file in this plugin restates it |
| Which classes one agent edits, checks or reviews | that agent's own file under `agents/` |
| How a payload reaches `sdlc-agent-result-persist`, and where a child stages its `leave` payload | `skills/agent-result-persist-interface/SKILL.md` |
| What the PR-read CLIs — the round under way, the adjustment comments and their cut, the fixer brief, the records chain — take, print and exit with, and which of a PR's reviews are pipeline reviews | `skills/pr-read-cli-interface/SKILL.md` |
| Which sources a run's time report reads, how it attributes each second, what it names as missing, and what its Decisions table counts per decision class | `bin/sdlc-orchestrate-analysis` |
| The decision record's file format, what `ask` refuses, the closed class list, how problems and options are numbered, the printed question, when a problem is open and when a design gap is pending, and where a record is stored | `bin/sdlc-decision` |
| How a skill puts a decision to the human through that script: one record per turn, the search behind a design gap's existing pattern, fitting a list of candidates to the option count, ending the turn on what `ask` printed, recording the reply, and putting a problem still open again on its own record | `skills/lib/decision-record.md` |
| Which prompts a skill keeps out of the decision record, and what it keys its records on | that skill's own `SKILL.md` |
| What a standing-ruling key is, and what each one's ruling does | `skills/lib/sdlc-config.md` |
| The conditions under which the orchestrator passes a standing ruling to a record | `skills/orchestrate/SKILL.md` |
| What the cleanup removes in each scope and in what order, what it keeps, the lines it prints and what it exits with | `bin/sdlc-orchestrate-cleanup` |
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

## The orchestrator's body holds what every turn needs

`skills/orchestrate/SKILL.md` is resident for the whole run, so every
line in it competes for attention with the judgment text the run
depends on: the agent roster with what the orchestrator branches on at
each return, the spawn-prompt and report-consumption principles, the
fix loop's decision points, the escalation relay and the hard
constraints. Procedure that applies at one known moment lives outside
the body, in one of two shapes:

- A **linear** procedure — run once at its moment, top to bottom — is
  a lib file under `skills/orchestrate/lib/`, one file per moment. The
  body names each file exactly once, at the point where it applies, and
  the orchestrator reads it when that moment arrives and not before.
- A **loop** — a gate run repeatedly with a remedy between runs — is
  an agent, spawned at its moment and reporting back when the loop
  ends, so that no single surface absorbs the whole loop and its
  bounds move with it.

| Lib file | Moment |
| --- | --- |
| `pre-flight.md` | before any issue is read: the primary-clone check, the per-repo config read, and the sdlc config resolution |
| `plan.md` | grouping the issues into batches and waves, the decision item for a batch that needs a resolving install, the plan presented before anything spawns, the one decision record its decision items go through, and whether Execution waits for the human to confirm it |
| `issue-lifecycle.md` | every issue-status transition, and the `/issue-*` verbs the orchestrator runs |
| `pr-lifecycle.md` | a PR from the developer's report to the ready flip: the link to its issues, the round-0 write, the body freeze, the documentation loop's briefs and round mechanics, the one spawn once the documentation loop has ended, the close-out, reopening the review loop after one, and the briefs for the two loop agents |
| `wrap-up.md` | after the last PR's monitor loop ends, or its ready flip when the run monitors nothing: the post-merge tail and the summary |

A step the orchestrator runs is run by exactly one of the body, a lib
file, `pr-merge-readiness` or `pr-monitor`; a PR that moves a step
edits the surface it leaves and the one it lands in, and this table
when a lib file's moment changes.

`agents/theorem-based-pr-reviewer.md` splits the same way: what every
turn of a round needs stays in the agent file, and a linear procedure
for one moment is a lib file under `skills/lib/theorem-based-pr-reviewer/`,
which the agent file names once, at its moment.

| Lib file | Moment |
| --- | --- |
| `resume.md` | when `--mode next` names an arm other than `no-log`, or a line is `overdue`: the resume-pass loop, the resume loop every wait runs, and the deadline arm |
| `review-body.md` | once `--mode dispose` has exited 0: the argued review's sections, the finding format, the records file's field rules, and the calls that store the round and post its review |

A step the reviewer runs is run by exactly one of the agent file or a
lib file; a PR that moves a step edits both surfaces it touches, and
this table when a lib file's moment changes.

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
  owner, `skills/orchestrate-readiness/SKILL.md`, and a reader either
  names the skill and a section's role or spells a heading literal.
  Among the first: the writer, `skills/orchestrate-ready/SKILL.md`; the
  gate and the "Files likely affected" step in
  `skills/orchestrate/SKILL.md`; and `agents/theorem-generator.md`,
  which keys a criterion theorem's `settle-mode` off the sub-headings of
  the section its mode reads — the code and instruction Markdown
  section in a code round, the documentation section in a documentation
  round. Among the second, where the wording cannot avoid the literal:
  the orchestrator's scope rules and its rule for a batch with no code
  to implement, and the `docs-writer` writing brief, spell the
  acceptance-section headings, and
  `plugins/issues/skills/issue-create/SKILL.md` spells every heading it
  reads because the plugin sandbox keeps it from reaching the skill. So
  grep the quoted heading repo-wide rather than recalling who spells
  it, and a rename edits the owner, every hit, and any reader whose
  wording no longer fits the renamed section.

Surfaces outside this plugin that a contract change reaches:
`plugins/github-prs/` attributes PR verbs to named `sdlc` agents in its
README and in several of its skills, so settle that list by grepping
the agent names across that plugin rather than by recalling which files
carried them last time.
`plugins/issues/` deliberately names no `sdlc` reader of its
repo-config, for the reason `plugins/issues/README.md` gives — do not
add one back. Its `skills/issue-create/SKILL.md` does read the
issue-body grammar, though, and spells the acceptance-section and
files-affected headings literally, so a change to that grammar reaches
that file too.

The header `style-checker` takes its rules from, `## For Authors and
Checkers`, is spelled in the global style guides — the code-style
guide, the instruction-Markdown guide and the documentation style
guide, all outside this repository, so a rename there never shows up
in a grep here — and in their per-repo extension files.
By the checker's own wording a guide without that header contributes no
rules, so a renamed header makes the pass report clean rather than
fail. A PR that renames it in the guides edits `agents/style-checker.md`,
the orchestrator's roster line, and every `style-checker` spawn prompt
— the code loop's in `skills/orchestrate/SKILL.md` and the
documentation loop's in `skills/orchestrate/lib/pr-lifecycle.md` — in
the same change.

## A spawn template and its receiving agent are one change

The orchestrator's teammate briefs are two-sided, and the receiving
side is the half that stays stale. When you widen a spawn template —
in `skills/orchestrate/SKILL.md`, in the lib file for the moment the
spawn belongs to, or in `agents/pr-merge-readiness.md`, which briefs
the teammates it spawns itself — repair the bullet **list** under the
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
`isolation: worktree` on every agent but the two loop agents,
`user-invocable: false` on the skills that are not user verbs — so a
PR changing either key edits this file. And how `/sdlc:orchestrate-ready` and `/sdlc:orchestrate`
relate — one writes a body up to the bar, the other refuses a body
below it, and neither runs the other — is summarised here, so a PR
that changes how the two relate edits it here. So are the stages a
blessed PR goes through and the split between the gate that reports a
merge state and the teammate that remedies it, so a PR that reorders
those stages or moves a remedy edits it here.

## The config lives in tiers no agent reads

Sdlc's config turns the flow's waits on a human and the bounds on its
loops:

- `plan-confirm` — whether Execution waits for the human to confirm
  the plan, which is presented under every value. `ask` always waits.
  `auto` waits only for a plan carrying a decision item.
  `auto-single-batch`, the default, waits for that plan and for one of
  more than one batch, so a plan stops only where it carries a decision
  or a grouping across batches for the human to rule on. A plan that
  does not wait says so in place of its prompt, naming the value that
  let it through. A plan carrying a decision item ends on its decision
  record's question in place of the prompt, and the reply to it also
  confirms the plan.
- `max-issues-per-batch` — the most issues one batch holds, a positive
  integer that defaults to `8`. A batch the grouping would make larger
  is split into more batches.
- `seed-review` — how the seed theorem list is settled before a batch's
  developer runs. `ask` stops for the human's ruling.
  `accept-as-emitted` accepts the list as generated, applies none of
  `theorem-assessor`'s recommendations, and does not wait.
  `accept-recommended`, the default, applies every recommendation,
  coverage-gap adds included, and does not wait. `auto-accept` is a
  deprecated alias for `accept-as-emitted`: a file that sets it keeps
  that behaviour, and a `sdlc-config-*` verb that rewrites the file
  writes `accept-as-emitted` in its place.
- `merge-wait` — whether the monitor loop runs after a PR's ready
  flip. It defaults to `monitor`; `skip` runs none.
- `merge-poll-interval-seconds` — the wait between two of that loop's
  polls, a positive integer with no upper cap that defaults to `60`.
- `merge-max-unchanged-polls` — how many consecutive polls with no
  change in state the loop runs before it asks whether to keep
  waiting, a positive integer that defaults to `720`.
- `code-review-max-rounds` — the most review rounds the code loop runs
  per PR, a positive integer or `unlimited`. It defaults to `10`.
- `docs-review-max-rounds` — the most review rounds the documentation
  loop runs per PR, with the same values. It defaults to `5`.
- `loop-end` — whether the code loop's end, before the documentation
  loop starts, waits for the human. It is `ask` or `auto-when-clean`,
  and defaults to `auto-when-clean`.
- `docs-loop-end` — whether the documentation loop's end, before the
  merge stages and the ready flip, waits for the human. It takes the
  same values, and defaults to `auto-when-clean`.
- `ready-rewrite-approval` — whether `/sdlc:orchestrate-ready` asks the
  human to approve the acceptance criteria and the files-affected list
  before it rewrites an issue's body. `ask`, the default, asks. `auto`
  rewrites the body without that question once every design gap has
  the human's stored answer, and prints what it wrote.
- `orchestrate-statuses` and `orchestrate-ready-statuses` — the
  statuses an issue may be at for `/sdlc:orchestrate` and for
  `/sdlc:orchestrate-ready` to run on it, per "An issue already done or
  already in work is refused before its body is graded" below. They
  default to `[Todo, Ready]` and `[Backlog, Todo, Ready]`. Each is a
  list of one or more status names, where every other key holds one
  value, and a tier that sets one sets the whole list: a higher tier's
  list replaces a lower one's and never merges with it.
- `follow-up-issue-type`, `follow-up-issue-priority`,
  `follow-up-issue-status` and `follow-up-issue-assignee` — the fields
  a follow-up issue the human ordered is filed with, for each field
  the order named no value for. Each defaults to `repo-default`, which
  files the issue with the target repository's own default and asks
  nothing, except for a priority or status slot the target configures
  with no default, which is asked. `ask` makes the field a question. A
  type, option or login name is passed as given, and the assignee also
  takes `@me` and `none`, which files the issue unassigned.
- `outside-criteria-finding` and `recurring-finding-class` — the
  standing rulings, per "A standing ruling settles a recurring class
  of finding from config" below. They default to `fix-in-pr` and
  `fix-class`, and each takes `ask`.

The two loops count their rounds separately, so no code-loop round
counts against `docs-review-max-rounds`. A loop that reaches its cap
ends there, and that end reaches the human as one decision listing
every finding still open; under `unlimited` it has no cap and runs
until a review approves with no findings.

Neither loop-end key has any effect on the other loop's end. `ask`
puts every end of its loop to the human as a decision, so
`docs-loop-end: ask` restores the decision before the ready flip, and
`loop-end: ask` the one before the documentation loop.
`auto-when-clean` skips that decision for a clean end — a last review
round that is APPROVED with no open finding of any severity — and
starts the next stage. Every other end still asks, under either value:
a loop at its round cap, and a loop the human's ruling ended.

That a loop ends only on the human's pick is a policy, and
`auto-when-clean` is its one exception: under that value the human
confirmed every clean end of the loop in advance. Whether an end is
clean is read off the PR's stored round state, never off the reviewer's
report, so the question is skipped only on a verdict the state holds.

A finding still open at a round cap reaches the human only as that
loop end's decision. It used to be a Needs Your Attention row of the
run summary as well, which asked the human to act a second time on
something they had already ruled on. A PR the pick leaves draft is
listed in the summary under Left Draft, with the pick.

One key belongs to no moment of the flow:
`reload-after-compact-token-budget` bounds how much text the
`reload-after-compact` hook appends after a compaction.

With no config file at any tier, a run does not wait for the human at
a plan with one batch and no decision item, at the seed theorem list,
or at a loop's clean end: the defaults keep the waits where there is
something to decide. At the seed list it applies the assessment's
recommendations rather than accepting the list as generated. Nor does
it wait at a finding outside the issue that meets `fix-in-pr`'s
conditions, at a finding class recurring for the first time, or at the
fields of a follow-up issue, other than a priority or status slot the
target repository configures with no default. Each key that takes `ask`
restores its own wait when set to it. The two status lists still gate
with no config file: a key set at no tier resolves to its default like
any other, so there is no setting under which either skill runs on an
issue at any status.
A PR that adds a key, or changes a default, edits this list.

The config is three YAML files — a global user file outside every
repository, a shared repo file that is tracked, and a repo user file
that is gitignored — and the higher tier wins per key, so a team can
commit `seed-review: accept-as-emitted` to the shared file and one user
can put the ruling back for themselves with `ask`. The paths, the
keys' values and defaults, the read aborts and the writer procedure
have one owner,
`skills/lib/sdlc-config.md`; the `sdlc-config-*` verbs are one writer
per tier, each running that procedure against its own file and
restating none of it.

The decision that shapes everything else: **no agent reads the config**.
Pre-flight resolves the tiers once, prints each value beside the tier
it came from, and a value a teammate acts on travels in its brief — the
named exception to the orchestrator's rule against passing resolved
config in briefs. Every agent but the two loop agents runs in a fresh
worktree, where the gitignored repo user file does not exist, so a
teammate that read the tiers itself would resolve a different answer
from the run that spawned it. The brief that carries a key and the
receiving agent's `## Inputs` are therefore one change, the same as any
other spawn-template field.

`/sdlc:orchestrate-ready` resolves the tiers too, before its first
question, and prints them the same way. It spawns no agent, and reads
them for `orchestrate-ready-statuses`, for `ready-rewrite-approval`
and for the `follow-up-issue-*` keys a side-effect issue is filed with.

A `sdlc-config-*` verb asks for a status list by offering the board's
status options, which it reads through `/issue-field-options status`,
and takes typed names beside them. Where those options cannot be read —
outside a git working tree, or in a repository with no status slot
configured — the question is still asked and takes typed names alone,
so the global tier's writer, whose file lives outside every
repository, can set either key from any directory.

The `reload-after-compact` hook is the one reader besides those two
skills. It runs on every compaction, inside an orchestrate run or
outside one, and has no brief to receive a value in, so it resolves the
tiers itself and takes its budget key alone from them. It is not an
agent, so the decision above stands as worded.

What the two switches leave alone is as deliberate as what they skip:

- A `seed-review` value that does not wait skips only the wait. The
  candidate list and `theorem-assessor`'s assessment of it are still
  shown, and the settled list is still written as round 0 of the PR's
  state, so the first review round starts from round 0's records
  whichever way the seed was settled. `accept-as-emitted` writes the
  list as the generator emitted it, with none of the recommendations
  applied. `accept-recommended` writes it with every recommendation
  applied, and adds a `seed-review` record to round 0's log so that
  nothing later takes rulings the config applied for the human's.
- `merge-wait: skip` ends the PR's stages at the ready flip, and the
  summary lists the PR under its own table as ready and unmonitored.
  Nothing re-runs the merge-readiness gate after that flip, so a PR
  that falls `BEHIND` or `DIRTY` while it waits is the human's to
  remedy, not the run's.

## Every question to the human is a checked decision record

`/sdlc:orchestrate` and `/sdlc:orchestrate-ready` used to put decisions
to the human as free prose, and nothing checked the prose or kept the
answer. A question could arrive with no decidable problem statement — a
finding's id and severity, and nothing about what was wrong. A turn
raising several problems drew a reply such as "1" that mapped to none of
them, and a second question was spent on which was meant. And a class of
question the human answered the same way every time was asked again on
every run, because no record showed the pattern and nothing could act
on it.

So a decision — any question that asks the human to choose — reaches
them only as what `bin/sdlc-decision ask` printed for a **decision
record**. The asking skill writes the record as a YAML file holding
every problem its turn raises, and each problem fills these slots:

- **class** — which kind of decision it is, from the closed class list,
  or `unclassified` when none fits. The list is defined in
  `plugins/sdlc/bin/sdlc-decision` and nowhere else.
- **problem** — what is wrong, where, and what it causes.
- **options** — two to four, each with what it does, the **evidence**
  it rests on, and its **cost to the human**: what the human must do or
  notice for the option to work, or `none`. Evidence is typed, either a
  `file:` path and line with the text quoted from that line, or a
  `command:` with the output it printed.
- **recommendation** — one option id, with nothing attached.
- **why** — the reason for that pick.
- **existing-pattern** — on a `design-gap` problem only: the
  `path:line` in this repository that already does the thing, or the
  exact search that found none.

The question goes through a script because each failure above was a
slot left empty or an answer left unrecorded, and prose that nothing
checks is what had let both through. `ask` refuses the record, storing
nothing and naming every failing slot, when:

- the record file is not YAML, holds more than one YAML document, or
  has a `problems:` list that is missing or empty;
- a problem, an option or a piece of evidence is not a mapping;
- a problem statement or a `why` is empty;
- the class is missing or outside the class list;
- a `design-gap` problem's existing-pattern slot is empty;
- a problem holds fewer than two options or more than four;
- an option does not say what it does, has no cost to the human, or
  has no evidence;
- a piece of evidence is neither `file:` nor `command:`, or is both;
- a `file:` value is not `<path>:<line>`, or its quote is empty;
- a `file:` evidence names a file that does not exist or a line it
  does not have, or its quote is not on that line;
- a `command:` evidence lacks the command or its output, or its output
  is not text;
- the recommendation names no option of its problem, names more than
  one, or carries anything beside the option id.

**`ask` never runs a `command:` evidence.** It checks only that the
command and its output are present, so that output is the asker's
record of what it ran. A `file:` evidence is the one kind `ask`
verifies, by reading the named line of the file where it runs; text no
file there holds, such as an issue's body or a line on a branch that is
not checked out, is cited as a `command:` instead.

A sound record is stored and printed in a fixed format: problems are
numbered `P1`, `P2` and on, and each problem's options `P1.1`, `P1.2`
and on, so every option in a turn has an id no other option shares and
a reply of bare ids maps to exactly one option per problem. The human
may still answer in their own words. The caller records such an answer
by passing `answer` the pick `none` for that problem, and `answer`
stores it beside the reply verbatim. The numbered options make the reply
mappable and countable without capping the answer, which is why a
grooming question takes the same form as any other: where a decision is
too open to enumerate, such as a name, its options are candidate
proposals.

A problem the reply did not address is passed no pick. `answer` stores
a problem given no pick as `unanswered`, whatever the reply says, and
it stays **open** on its own record. `answer` takes that record again
while any of its problems is open, appending the later reply below the
earlier one, and `question` prints the record's question again, from
the text `ask` stored beside it, so the skill re-puts the problem by
printing what the human first saw. The problem is never moved to a new
record: no answer to a new record closes the old one's problem, so the
old one would wait for ever. A record stored before `ask` kept its
question has it rendered again from the record and its log, as that
`ask` printed it.

`pending` is the check built on that state. It exits 4, naming each
one, while a `design-gap` problem of the PR or the issue is open — no
ruling resolved it, and its latest pick is absent or `unanswered` — and
0 otherwise. An answer in free text closes the problem only once it is
recorded as the pick `none`: `pending` reads the stored pick and never
the reply, so a free-text answer recorded with no pick leaves the
problem `unanswered` and `pending` exiting 4.

Some prompts stay outside the record, because each asks for a ruling
on a whole artifact shown above it rather than a choice between
options: the plan's confirmation prompt, and the per-theorem rulings on
the seed list under `seed-review: ask`. A plan that carries decision
items puts them through one record, one problem per item, and ends on
that record's question in place of its confirmation prompt.

A record is keyed on the PR, or on an issue where no PR exists yet: a
grooming session, or a batch whose PR is not open. A PR's records are
stored beside its round directories and an issue's in a directory of
its own, per "Files it writes". `ask` lays the repository's state
directory out through the same functions `sdlc-agent-result-persist`
uses, in `bin/lib/sdlc-pr-common.sh`: it moves state written before the
host was part of the path and writes `repo.yml`, so whichever script
runs first for a repository leaves the layout the other expects.

The stored picks are what make the pattern visible. The Decisions
table of `/sdlc:orchestrate-analysis` counts, per class, the questions
asked, the records a ruling resolved, the picks equal to the
recommendation, the picks that differ, and the answers in free text. It
reads the records keyed on the PR, on each issue the PR closes, and on
each issue the PR's head branch names, so a record asked before the PR
existed is counted, and so is one keyed on a member the PR no longer
closes. A class the human always answers as recommended is a candidate
for a standing ruling.

### A standing ruling settles a recurring class of finding from config

A **standing ruling** is a config key named after a decision class.
Passed to `ask` as `--ruling <class>=<value>`, it resolves a record of
that class: `ask` prints `resolved by <class>: <value>` and no
question, and the skill applies the ruling. An `unclassified` problem
is never resolved by one. The classes below recurred on most runs with
the same answer each time, and each stopped the run until the human
replied, so each has a key that defaults to that answer:

- **`outside-criteria-finding`**, default `fix-in-pr` — a finding, or
  an observation no review filed, whose fix lies outside the issue's
  acceptance criteria is fixed in this PR, with the issue edit the fix
  needs. The orchestrator passes the ruling only when all of these
  hold:
  - every file the fix touches is in this repository;
  - the PR is still a draft;
  - the fix needs no decision the issue and the repo leave open, which
    it does when the orchestrator cannot name one fix, with no
    condition attached, backed by evidence from the finding and the
    tree.

  A finding that fails any of them stays with the human: a fix in
  another repository, a fix to a PR that has left draft, and a fix with
  a choice still open in it.
- **`recurring-finding-class`**, default `fix-class` — when findings
  of one class are filed on two consecutive rounds, the next fixer
  brief covers every instance of the class at head rather than the
  reported sites. The record cites both rounds' finding ids as its
  evidence. A class that recurs again after the round that fixed the
  whole class stays with the human, since the ruling has by then been
  tried.

Set to `ask`, either key leaves every record of its class with the
human, as before the keys existed.

The conditions sit with the orchestrator rather than in `ask` because
each is a judgment about the fix, and `ask` checks a record's shape. A
ruling the orchestrator does not pass resolves nothing, so a finding
outside the conditions is asked exactly as under `ask`.

That a standing-ruling key defaults to `ask` is the general rule, and
these keys are its named exceptions: each names its fix value as its
default in its own row of the config contract.

A decision a standing ruling resolved never reached the human as a
question, so it is made visible afterwards: the round's report names
it, the fixer brief carries the finding under a ruling of its own, and
the PR's final section records it as that config key's ruling, never
as the human's or the orchestrator's.

Each piece has one owner:

| Slot | Owner |
| --- | --- |
| The record's slots, what `ask` checks, the class list, the ids, the `resolved by` line, the stored question, and what `pending` counts | `bin/sdlc-decision` |
| The procedure for putting a decision through the record, how many options a list of candidates becomes, the search that fills the existing-pattern slot, and re-putting a problem still open | `skills/lib/decision-record.md` |
| That a decision reaches the human only through the record, the prompts the orchestrator keeps outside it, and what it keys a record on | `skills/orchestrate/SKILL.md` |
| The same for a grooming session | `skills/orchestrate-ready/SKILL.md` |
| The shape of a standing-ruling key, each such key and what its ruling does, and the `follow-up-issue-*` keys | `skills/lib/sdlc-config.md` |
| The conditions on passing `fix-in-pr`, when `fix-class` is no longer passed, and the fixer-brief ruling a resolved finding carries | `skills/orchestrate/SKILL.md` |
| What a fixer does with a finding a standing ruling resolved, and with an owner ruling naming a class | `agents/issue-fixer.md`, and `agents/docs-writer.md` in the documentation loop |
| That a resolved decision is named in the round's report and reaches `pr-finalizer` as a scope note | `skills/orchestrate/lib/pr-lifecycle.md` |
| How a resolved decision is worded in the final section | `agents/pr-finalizer.md` |
| That a round-cap end is one decision and no Needs Your Attention row, and the Left Draft table | `skills/orchestrate/SKILL.md` and `skills/orchestrate/lib/wrap-up.md` |
| How a follow-up issue's fields are filed, and what declining a field's question does | `skills/orchestrate/lib/issue-lifecycle.md` |
| What the Decisions table counts and which records it reads | `bin/sdlc-orchestrate-analysis` |
| The state root's repository layout, shared by the scripts that write under it | `bin/lib/sdlc-pr-common.sh` |

## Grooming asks the human only what is theirs to decide

Most of what `/sdlc:orchestrate-ready` asks is a design decision the
issue body leaves unstated, and those stay the human's. The way it
built its questions failed in repeatable ways: it offered options
without looking for how the repo already did the thing, so the human
supplied the pattern; it asked about another repository or a remote
system, and the human ruled each one out of scope; it asked about a gap
with one possible repair, which the human approved every time; and it
wrote its own proposed answer into the body, passed the readiness check
on that text, and set the issue Ready with nothing ruled on. Each has a
rule now, and the ones a script can hold are held by a script.

**A design gap carries the existing pattern.** Before writing a
`design-gap` problem the skill runs at least one repo-wide search for
the construct, command or name the gap is about, and fills the
problem's existing-pattern slot with the `path:line` that already does
the thing, or with the exact search that found none. `ask` refuses the
problem while the slot is empty, and prints the slot in the question on
an `Existing pattern:` line. A pattern that exists is option 1 and the
recommendation, unless the problem's why states what makes it unfit
here. The slot is required rather than advised because a search that
was skipped and a search that found nothing otherwise read the same to
the human.

**Some gaps are repaired without a question.** The rewrite repairs
each of these and the final report lists it:

- A **mechanical gap**, whose gap line opens `mechanical:` — one the
  bar alone settles the repair of: a section the bar forbids, a
  sentence that fails "Spec quality", and a missing or mistitled
  acceptance or files-affected heading around content the body already
  carries. `sdlc-readiness-check` labels the section and heading gaps.
  Whether a sentence is provenance or spec is a judgment about meaning,
  so the model grades "Spec quality" by reading and labels those gaps
  itself.
- An **"Outcome, not method"** gap. The bar item fails a sentence that
  prescribes an implementation step the implementer can derive from the
  tree or from running a tool: a fix per finding of a tool's report,
  whether a linter's, a type checker's, a test run's or a scanner's; a
  file and line given as where to make a change; and a diagnosis taken
  from a tool's report and stated as fact. It lets through what the
  implementer cannot derive: a config file's content, a name, a
  placement in the tree, a policy such as which findings may be
  excluded and where, an interface a downstream consumer depends on,
  and the observable outcome, which for a tool's output is that the
  tool reports clean. The rewrite restates a failing sentence as the
  outcome it was meant to produce. A prescribed step goes stale on a
  rebase, carries a possible false positive as fact, and has the review
  test the prescription rather than the outcome.
- A gap whose repair lies in an **out-of-scope system**: one this
  repository has no source or config for, such as another repository, a
  remote backend or a third-party service. The body states in one
  sentence what the change assumes of that system. A "Sandbox fit" gap
  is handled the same way, and the out-of-repo work it took out of the
  body is offered as a side-effect issue, filed only on a yes.

The acceptance criteria and the files-affected list the skill derives
or reworks are settled together in one closing approval, which
`ready-rewrite-approval: auto` skips. Every other gap is a design gap,
put to the human as a decision record.

**Design gaps are raised one per turn.** A turn's record holds exactly
one design-gap problem, and the next gap is raised only in a later
turn, after the human answered that one. The skill's opening report
still lists every gap with its proposed default answer, so the human
sees the size of the conversation before the first question. How many
problems a turn raises is the asking skill's choice, not the record's:
a plan's decision items share one record on purpose, and grooming
chooses one.

**An issue is set Ready only when the readiness check returns no gap
and no design gap waits on the human.** The second half is
`sdlc-decision pending`, run directly before the status flip, whatever
the check printed: while it exits non-zero the skill sets no status and
reports the issue as not ready. The check alone cannot be the gate,
because it grades the body, and a body holding the skill's own proposal
passes it. The skill also runs `pending` before it writes its first
record, so a design gap an earlier session left open is put again on
its own record rather than raised a second time. Those records are put
again one per turn, and a record that session wrote with several
problems is put again whole, because its problems cannot move to a new
record.

| Slot | Owner |
| --- | --- |
| The existing-pattern slot and its refusal, and what `pending` counts | `bin/sdlc-decision` |
| The search that fills the slot, and that a found pattern is option 1 and the recommendation | `skills/lib/decision-record.md` |
| What a mechanical gap is, and the "Outcome, not method" bar item | `skills/orchestrate-readiness/SKILL.md` |
| Which gap lines the script labels `mechanical:` | `bin/sdlc-readiness-check` |
| Which gaps the rewrite repairs, which system is out of scope, the closing approval, the `pending` runs, and that a turn raises one design gap | `skills/orchestrate-ready/SKILL.md` |
| The `ready-rewrite-approval` key | `skills/lib/sdlc-config.md` |

## An issue already done or already in work is refused before its body is graded

The readiness gate used to grade an issue's body and nothing else, so
`/sdlc:orchestrate` ran on a closed issue, on one an open PR already
closes, and on one another session was orchestrating, whenever the
body was well specified. `sdlc-readiness-check` now checks the issue
itself first and **refuses** it, before it grades the body, when any
of these holds:

- **Closed** — the issue's state is not `OPEN`.
- **Open closing PR** — an open PR closes the issue. A PR that closed
  it and was merged or closed unmerged does not count.
- **Local branch** — a local branch in this clone decodes to an issue
  set holding the issue, so another run on this machine has it, or left
  it behind.
- **Status** — the repository has a status slot and the issue's status
  is not one the caller allows. An issue with no status, off the board
  or on it with the field empty, is refused too.

The decisions behind them:

- **A refusal is not a gap.** A gap is something grooming repairs in
  the body. A refusal says the issue is not available, which no edit to
  the body changes and neither skill is in a position to settle:
  reopening an issue, closing a PR, deleting a branch and moving a
  status are each the human's call. So a refusal has an exit status and
  a verdict of its own, the body goes ungraded, and both skills print
  the refusal lines as they stand and stop. A remedy a line names
  itself is printed with it; a skill adds none of its own, and neither
  runs one nor offers to.
  `/sdlc:orchestrate` stops the whole run, and `/sdlc:orchestrate-ready`
  ends the session there, rewriting no body and setting no status
  after it.
- **A check that fails is not a pass.** A check that exits on an error
  of its own returns no verdict, and both skills stop on that as they
  do on a refusal, relaying its stderr, since an issue nothing could
  check has not been shown to be available.
- **The branch check compares issue numbers, never branch names.** A
  batch branch names several issues, so each local branch is decoded
  through `git-issue-branch decode` and the issue is looked for in the
  set that returns. The refusal names the branch and
  `/sdlc:orchestrate-cleanup`, because nothing resumes on a leftover
  branch, so what a dead run left is cleaned up before the issue is
  run again.
- **The allowed statuses come from the caller, and the script reads no
  sdlc config.** Each skill resolves its own key with the rest of the
  tiers and passes every name as an `--allow-status`. A call that
  passes none is a usage error rather than an open gate, so a caller
  that forgets the list checks nothing instead of letting every status
  through.
- **Each skill has its own list.** Grooming's default adds `Backlog`
  to the orchestrator's, so an issue can be groomed from `Backlog` and
  orchestrated only once it has left it. Neither default holds the
  status the orchestrator's own In Progress flip sets, which is what
  refuses an issue a session on another machine has started, where the
  branch check cannot see it.
- **A name is matched literally, ignoring case.** A listed name the
  board lacks matches nothing and is no error, so one list can serve
  repositories whose boards name their columns differently. A
  repository with no status slot skips the status check and keeps the
  others.
- **The orchestrator checks again directly before it starts a batch.**
  The gate runs before the plan, and the plan can wait on the human, so
  another session can start an issue in between. The In Progress
  transition re-runs the script on every member of a batch before any
  of that batch's flips, and a refusal of one member leaves the whole
  batch unflipped, unassigned and without a developer, since one
  developer starts a batch's members together. An issue is in one
  batch, so the re-check never meets an issue this run flipped itself.
- **The script writes nothing.** Every status transition stays with
  the skill that made it before, so a check that refuses has changed
  nothing about the issue it refused.

The open closing PR is read off the `closed-by:` row `issue-view`
prints. Under the Jira backend that row reads `unsupported`, which
names no PR, so the refusal never fires there.

| Slot | Owner |
| --- | --- |
| Each refusal's condition, the order they are checked in, the line each prints and the exit status | `bin/sdlc-readiness-check` |
| The `refused` verdict and what the check reads | `skills/orchestrate-readiness/SKILL.md` |
| That the gate stops the whole run on a refusal or on a return with no verdict, and adds no remedy of its own | `skills/orchestrate/SKILL.md` |
| The re-check before a batch's In Progress flips, and what a refusal there leaves undone | `skills/orchestrate/lib/issue-lifecycle.md` |
| That a refusal, or a return with no verdict, ends a grooming session | `skills/orchestrate-ready/SKILL.md` |
| The two status-list keys, their defaults, and how a list value is read, asked for and written | `skills/lib/sdlc-config.md` |

## An issue that contradicts a repo statement is caught before the PR

An issue can specify something an instruction file in the repo forbids.
The implementer used to settle that inside the PR, so what happened to
a rule the repo had chosen was decided by an agent, with the human
absent, at the most expensive point of the run. The conflict is now
looked for at grooming, and one found later goes to the human.

The readiness bar's **No contradicted repo statement** item fails a
body that specifies something an instruction file forbids and does not
say what happens to that statement. A body passes when, for each
statement it contradicts, it names the statement's fate — deleted,
replaced with given text, or given a named exception with its reason —
lists the statement's file in its files-affected section, and carries a
criterion for the edit. The gap line quotes the statement and names its
file.

The readiness check grades the item by searching on every invocation,
so grooming and the orchestrator's pre-run check both run it: it greps
the instruction files for each files-affected path and each identifier
the design names, reads in full the root `CLAUDE.md` and, for every
directory the body touches, the nested `CLAUDE.md` and the on-demand
files it routes, and reports what it searched on a `Searched:` line
ahead of the gap list. The search is a floor, not a proof that no
conflict exists, and the line shows the human what it covered.

The **instruction files** are that search's scope, defined beside the
bar item. No README is among them: every README is Documentation, as
changelogs and ADRs are, and is not searched. A rule that only a README
states is therefore one the search never finds.

A contradicted statement is one of two kinds, and the kind decides who
settles it:

- A **capability claim** says what the harness or a tool can or cannot
  do, so a test can show it false. It is settled by test, by whoever
  finds it: the readiness check's gap line proposes deleting the
  statement only when a test showed it false, quoting the test and its
  output; grooming proposes the deletion to the human with that
  evidence; and mid-run, `issue-developer` or `issue-fixer` runs the
  test, deletes a claim it showed false together with every restatement
  of it, and reports the test and its output.
- A **policy claim** is a choice the repo made where the harness
  permits both, so no test settles it. It is settled by the human: at
  grooming as a design gap whose options are the statement's fates, and
  mid-run by the agent stopping and reporting the statement and its
  file, which the orchestrator puts to the human with the issue edit
  inside each option.

A statement is a capability claim only when a test of it was run.
Prescriptive wording — "never", "may only" — does not decide the kind,
since a false capability claim reads exactly that way. A test is a
read-only command chosen by whoever runs it, never one the issue body
spells. A claim only a state-changing command could settle, or one a
rule forbids or gates behind the human's approval, is not tested, and
is handled as a policy claim, as is one whose test did not show it
false. The default therefore falls toward the human: an agent deletes a
repo statement only on evidence it can quote.

The rule used to live in the root `CLAUDE.md`, which told the
implementer to grade the statement and settle it in the PR without
escalating. It was removed from there, and no `CLAUDE.md` section
replaces it.

| Slot | Owner |
| --- | --- |
| The bar item, the terms, the search and the `Searched:` line | `skills/orchestrate-readiness/SKILL.md` |
| That grooming relays the search and puts a contradicted policy claim to the human | `skills/orchestrate-ready/SKILL.md` |
| What an implementing agent does with each kind mid-run | `agents/issue-developer.md` and `agents/issue-fixer.md` |
| How the orchestrator puts a reported conflict to the human | `skills/orchestrate/SKILL.md` |

## A compaction reloads the skills and rule files a loop was working from

After a compaction a conversation works from the compaction's summary.
The summary truncates the text of the skills it lists, and the rule
files the conversation read on demand are not reopened, so a rule
stated only in one of those files is applied from memory — an invalid
`--mode` value written into a brief, an owner ruling placed where the
receiving agent never looks. The `reload-after-compact` hook closes
that gap: once a compaction has run, it appends one message holding
the full text of the files the compacted loop depended on.

What it reloads:

- **Skills** the loop invoked, through the `Skill` tool or as a slash
  command. The compaction event carries a skill's name and seldom its
  base directory; where a message does name one, the hook uses it, and
  otherwise it resolves the name itself: a
  `<plugin>:<name>` skill in this plugin's own root, or in the cache
  directory of the version `~/.claude/plugins/installed_plugins.json`
  records as installed; an unprefixed name under the project's
  `.claude/skills/`, then `~/.claude/skills/`, then the installed
  plugins. An unprefixed name found in none of them is a built-in
  command and is skipped.
- **Rule files**: each `.md` file the loop opened with `Read` under a
  `rules/` or `skills/` directory.

What it leaves out is as deliberate:

- **Every `CLAUDE.md` and every file under `~/.claude/rules/`**, which
  the harness re-injects after a compaction on its own.
- **Agent definitions, and any file opened under an `agents/`
  directory.** An agent's definition is its own system prompt, and the
  briefs a loop writes for the agents it spawns are stated in that
  loop's skills, which are reloaded.
- **Another loop's files.** A subagent's compaction reloads what that
  subagent's transcript invoked and read, and the main conversation's
  reloads its own.
- **The files that serve only the opening of an `/sdlc:orchestrate`
  run** — the orchestrator's pre-flight and plan lib files — once an
  `Agent` call follows the loop's most recent `/sdlc:orchestrate`
  invocation. The orchestrator spawns no agent until pre-flight, the
  readiness gate and the plan are settled, so from that call on those
  files are spent, and reloading them would spend the budget on text
  the run never returns to. A later invocation makes them live again
  until its own first `Agent` call. The readiness skill is not among
  them, although its gate runs at the opening: the orchestrator's
  mid-run handling of a contradicted policy claim uses the terms that
  skill defines.

A file used before an earlier compaction is still a use at the next
one, although the tool call that used it has been summarized away. The
hook therefore records each loop's uses, in order of recency, in a
state file keyed by session and by loop, and merges them with what the
transcript shows at each compaction. It never reads the uses back out
of an earlier reload message, which is itself part of the conversation
the next compaction summarizes. Every earlier reload message is instead
removed from the compacted conversation, which then holds at most the
fresh one. A state file that cannot be read or written is named with
its error in the reload message, the error written on one line, and
the reload proceeds on the transcript alone.

The reload is bounded by `reload-after-compact-token-budget`, with
tokens estimated as characters ÷ 4. Files are appended whole, most
recently used first; the first file that does not fit, and every file
after it, is listed by absolute path with an instruction to read it
before acting on it. A file that cannot be read is listed with its
error, written on one line. The key defaults to `100000` and has a
floor of `64000`: an orchestrate run's own skill, lib and interface
files past its opening are about 52k tokens as the hook counts them.
Those files are not the run's whole working set. Any other skill the
run invokes, and the files its own work reads, are not counted, and the
floor's headroom above the counted files is what covers them.

**On screen, the reload message is one line.** It is an ordinary user
message, so Claude Code would draw it as if the human had typed it: a
row holding the full text of every reloaded file, after every
compaction. The hook module therefore also registers a `ui.render`
hook on the `UserMessage` component, which draws that row as one dim
summary line on every surface:

```text
sdlc: reloaded <A> files (<T>k tokens) after compaction; <B> not appended; <C> unreadable; state file failed
```

`<A>`, `<B>` and `<C>` count the files appended, past the budget and
unreadable, `<T>` is the appended text in tokens, rounded to the
nearest thousand, and each part after the first appears only when it
applies. Only the drawing changes: the model receives the message's
full text, as the compaction wrote it. Every other user message is
drawn as it would be without the hook, one that holds the reload
marker past its start included.

The summary is read off the message's own text, because the render
hook shares no state with the compaction hook. The message is written
so that it can be counted. Its list of files states each entry's
status ahead of its path — `- (appended below) <path>`,
`- (not appended: read it before acting on it) <path>` or
`- (could not be read: <error>) <path>` — and every path and error
text in that list, and every state-file error, is written on one line,
its lines joined with ` | `. No path or error text can then pass for
another entry's status, for the state-file paragraph or for the start
of the reloaded files.

The hook parses no YAML, so it accepts one shape of budget line and no
other spelling YAML would allow. A tier file holding any other line
that contains the key's name is invalid, a commented-out line or a
second budget line included. The exact shape is owned by
`skills/lib/sdlc-config.md`.

**A broken tier reloads nothing.** When a tier file exists and cannot
be read, fails the `schema-version` check, or holds an invalid budget
line, the hook appends no reload message, the compaction completes on
the summary alone, and one `$.ui.log` line tells the human the path and
the error. It never falls back to the default for such a tier, and
never puts a config error in text sent to the model. The loop's uses
are still recorded, so the first compaction after the tier is repaired
reloads them. A throw inside the hook after the compaction has resolved
leaves the compaction standing, with any reload message removed.

## A resolving install is approved at the plan and run by the orchestrator

A resolving install — one that may rewrite a lockfile, such as
`pnpm install` or a fresh `npm install` — runs only on the human's
explicit direction, and a task brief does not carry that direction.
`issue-developer` may run only the lockfile-honoring install, so a
batch whose change regenerates a lockfile used to fail there and
escalate after a full spawn, although the need was readable off the
issue before any agent ran.

So the plan asks. A batch needs a resolving install when a member
issue's files-affected section lists a lockfile or a package manifest
tagged `update` or `new`; that section alone decides it, never the
issue's prose. Such a batch is a decision item on the plan, stating the
command, the directory it runs in, and whether any external version can
move. The item is a problem of the plan's decision record, whose
options are running the install as stated and holding the batch out of
the run. The human's pick of the option that runs it is the direction
the install needs, and until it is given the batch does not spawn,
whatever else the plan confirm settles.

The developer of an approved batch is briefed with the command and the
directory. It commits and pushes the manifest changes, opens no PR, and
stops, reporting the install as due; it neither runs the install nor
escalates for it. The orchestrator then runs the command exactly as
approved, in that developer's worktree, commits and pushes the lockfile
change, releases the stopped developer's claim on the branch with
`git-branch-sync reclaim`, and spawns a fresh developer that continues
on the same branch from the commits it carries. A developer's return
ends its run, which is why a second one finishes the batch rather than
the first resuming. An install that exits non-zero, or that changes any
file but a lockfile, the agent-memory directory aside, goes to the
human as a Needs Your Attention row with its output verbatim, and
nothing more spawns for the batch.

The orchestrator running the install is a named exception to its rule
against doing agent-owned work, and the approval is the reason: it
makes the install the human's directed act, and the orchestrator is the
one party in the run that holds it.

| Slot | Owner |
| --- | --- |
| Which batches need a resolving install, what the decision item states, its options, and that the batch waits on the pick that runs the install | `skills/orchestrate/lib/plan.md` |
| The developer's checkpoint under an approved install, and how a developer continues on an existing branch | `agents/issue-developer.md` |
| Running the install, what sends it to the human, the fresh developer's brief, and the exception to the rule against agent-owned work | `skills/orchestrate/SKILL.md` |

## A dead agent's branch claim is reclaimed, not escalated

A teammate that commits checks its branch out through
`git-branch-sync checkout` and lets go of it with `release` at the end
of its run. An agent that dies in between leaves its worktree holding
the branch, and git lets one worktree at a time hold a branch, so the
agent re-spawned to continue fails at its first git step. Nothing in
the run could clear that: the orchestrator's rule against repairing an
escalating teammate's environment names the branch claim, and the
cleanup runs only once the PR has merged. Each such death cost the
human a turn spent on something that decided nothing.

The checkout now reports a held branch as exit 13, naming the holder's
worktree. Whoever spawned the reporting agent — the orchestrator, or
`pr-merge-readiness` for an agent it spawned — runs
`git-branch-sync reclaim` on the branch and re-spawns that agent once,
with the brief it had. A second exit 13 from the re-spawn, or a
`reclaim` that exits non-zero, goes to the human with the output
verbatim: as a Needs Your Attention row from the orchestrator, and as
its question from `pr-merge-readiness`, which never asks.

This is a named exception to the repair rule, and what makes it safe
sits in `reclaim` rather than in the spawner's judgment. `reclaim`
refuses a branch with a rebase in progress, uncommitted changes or
commits `origin` lacks, so releasing the claim discards nothing and
makes no decision that belongs to the human. The agent-memory directory
is left out of that check: its files are an agent's own and never
committed to the branch.

The one thing the spawner contributes is whether the holder has ended.
A harness lock naming a running process stops `reclaim` unless
`--holder-ended` is passed, and a spawner passes it only on knowledge
it holds itself: the holder's worktree path ends in the id of an agent
it spawned, and that agent's call has returned. A running process is
not a running agent — the lock names the session's process, and an
agent can die inside a live session — which is why the spawner's
knowledge may override the lock, and why it overrides nothing else.

| Slot | Owner |
| --- | --- |
| What `checkout` reports for a held branch, and what `reclaim` refuses and releases | the `git-tools` plugin's `git-branch-sync` skill |
| The orchestrator's response to exit 13, when it passes `--holder-ended`, and the exception to the repair rule | `skills/orchestrate/SKILL.md` |
| The same response to a spawn of the merge-readiness loop, and its return as the question | `agents/pr-merge-readiness.md` |

## A blessed PR is gated on merge readiness, and the gate never remedies

The human's blessing is the end of the PR's documentation loop: their
confirmation of it, or, under `docs-loop-end: auto-when-clean`, a clean
end they confirmed in advance. It authorizes the ready flip and nothing
past it, and the flip is not the next thing that happens. "Ready for review" is
a draft flag; it says nothing about whether the branch is current with
its base, merges cleanly, or passes its required checks, and a final
section written while the branch is behind its base describes commits
a rebase is about to rewrite. So a blessed PR goes through the
close-out's stages in order: the one agent that still puts a commit on
the branch, `agent-memory-scrubber`; then the **merge-readiness loop**
— the `pr-merge-readiness` agent, which runs
`github-prs:pr-ready-to-merge` and leaves only on a state its table
lets through; then the linear **close-out** — `pr-finalizer`, the In
Review flips, the ready flip, in that order because the finalizer
corrects the body's closing lines and the flips read the closing set
it leaves; then, unless `merge-wait` is
`skip`, the **monitor loop** — the `pr-monitor` agent, which polls
until the PR merges and re-runs the gate while it waits, returning when
the branch has fallen `BEHIND` or `DIRTY` so the merge-readiness loop
runs again; and, once per run after the last PR's stages end, the
**post-merge tail**, which runs the cleanup once for each PR the run
merged — the cleanup is what leaves the primary clone on the default
branch, fast-forwarded. One PR goes through the stages at a time,
because the first merge moves the base the next PR is measured
against.

The split that holds this together: the gate **reports**, and the
remedy is a teammate's. Neither the orchestrator nor a loop agent runs
`git rebase` or `git merge` or hand-edits a conflict in the primary
clone. A branch the gate finds `BEHIND` or `DIRTY` is handed by
`pr-merge-readiness` to `issue-fixer` through the same fixer-brief
comment the code loop uses, carrying the gate's report verbatim, and
the fixer's return is followed by the memory scrub, then the gate again
rather than a code review round — so `issue-fixer` performs
merge-readiness remedies as well as review fixes, and the two kinds of
brief are told apart by whether the brief carries findings. A remedy
that leaves documentation behind — an edit the fixer deferred, or a
rebase conflict it resolved in a documentation file — is the one
return the loop agent makes with no question to ask: it spawns no
`docs-writer`, because a documentation commit would reach the gate with
no round over it, and returns `documentation loop needed` instead; the
orchestrator runs the documentation loop, scrubs memory again, and
spawns the agent afresh. What each state drives is
owned by that loop agent's own file. The merge-readiness loop's wait
bounds are that file's too; the monitor loop's poll interval and
unchanged-poll bound reach it in its brief, as config keys whose
defaults the config contract owns. Each bound, in either place, is a
declared starting value rather than a measured one.

A loop agent never asks; it returns. The orchestrator is the only
party in a position to rule on a question or put it to the human, so a
state that needs a ruling ends the agent's run: it returns with the
gate's report verbatim as its question, the orchestrator rules on it
when the repo settles it and relays it to the human otherwise, and on
the ruling spawns the agent again with it in the brief, keyed to the
state and cause the question named. A merge conflict is not by
itself such a state: `BEHIND` and `DIRTY` both go to the fixer first,
ruling or not, because a conflict a repo rule already settles — a
plugin `version` line under the version-bump rule — would otherwise
cost the human a turn to restate that rule. Only a conflict the fixer
could not settle comes back as a question, with the fixer's report
naming it. A ruling answers only that
question: the re-spawn runs the gate afresh, and a ruling the new
report does not consume is discarded and named in the agent's report,
so whoever gave it learns that an earlier ruling lapsed rather than
took effect.

Because every failed gate means the close-out is run again, each of
its steps is safe to repeat: the status flips repeat harmlessly, the
ready flip no-ops on a PR already ready, and `pr-finalizer` posts only
the rounds above those the PR's complete detail chains cover, which is
nothing when no round ran since, finds its own
marked section in the body and overwrites it, so a reader never meets
a stale section before the current one, and reports a closing-line
correction the body already satisfies as satisfied rather than
applying it twice.

## A detail chain names its rounds, so a later close-out adds to it

The review detail has to reach the PR in full, because the PR is the
one place every reader can reach it: the state it is assembled from is
local to one machine, and gone from there once the human runs the
cleanup with `--review-state`. Each of these used to keep part of it
off the PR.

**A round run after a close-out.** A chain's marker once carried only
a chunk's position and the chain's total, so a complete chain said
nothing about which rounds it held, and the detail poster treated any
complete chain as the whole record. When the human reopened the review
loop after a close-out, the later rounds' detail stayed in state. The
marker now names the lowest and highest round its chain holds. The
highest round any complete chain covers is the covered round, and a
close-out posts one supplementary chain holding only the rounds above
it. Nothing is posted twice, because `pr-finalizer` deletes no comment
and a repeated chain would sit beside the first for good. A chain a
failed post left partial covers no round, so the re-run posts that
chain whole. A complete chain posted before markers named their rounds
covers none either: which rounds it held cannot be read off it, so the
next close-out posts a full chain beside it, and that duplication is
the price of losing no round.

**A piece too large for one comment.** Such a piece was replaced by a
placeholder naming its files under the PR's state root, which pointed
at nothing on any other machine, or once that state was deleted. It is
now split across consecutive
chunks of its chain, so every piece reaches the PR, and the final
section never names local state as where a round's detail is.

Only the human reopens the review loop after a close-out, at any point
before merge; the orchestrator never does on its own judgment. A PR
already marked ready goes back to draft first, so it cannot merge
while rounds are still running over it, and the close-out that follows
flips it ready again.

| Slot | Owner |
| --- | --- |
| The chunk marker, as a regex matching both its forms and a function printing the current one | `bin/lib/sdlc-pr-common.sh` |
| What makes a chain complete, and the lines reported for complete and partial chains | `skills/pr-read-cli-interface/SKILL.md` |
| The covered round, which rounds and records a chain holds, where a split piece breaks, and what happens to a code fence open at a break | `bin/sdlc-pr-post-theorem-records` |
| What each line of the detail post's report means, and that the final section lists each chain with its rounds | `agents/pr-finalizer.md` |
| Who may reopen the review loop after a close-out, and the return to draft before it reopens | `skills/orchestrate/lib/pr-lifecycle.md` |

## The issue is the ceiling of the fix loop

An issue's `## Code and instruction Markdown acceptance` section is
the ceiling of the code loop's fix loop, not its floor; its
`## Documentation acceptance` section sets no scope there, since what
that section asks for is `docs-writer`'s, in the documentation loop,
where that section and the documentation the diff made stale are the
ceiling in turn. A review finding whose fix lies outside the ceiling is
the orchestrator's ruling when the repo settles it, quoting the
sentence that settles it. One the repo leaves open is a decision of
class `outside-criteria-finding`: the standing ruling of that name
resolves it when its conditions hold, as `fix-in-pr` by default, and it
is the human's to admit or refuse otherwise.
A developer's diff that reaches a plugin the issue does not name or
renames or deletes a file the issue does not specify is the human's to
admit or refuse; the orchestrator never admits one on its own. The
issue's
files-affected section is no ceiling at all. It is a floor: the
implementer is expected to touch paths it does not list, so an
unlisted path is not a gate trigger, not a design decision, not a
theorem about what the change left alone, and not a report item — a
listed path grounds a claim about that path and nothing about the rest
of the tree. Treating the list as a fence produced "Needs Your
Attention" rows, escalations and theorems over work that was simply
part of the fix. The converse holds below the
ceiling: a finding the code and instruction Markdown criteria cover is
the orchestrator's to brief, and nothing the reviewer attaches to it —
an offered rejection, a request to confirm intent — turns it into a
question for the human, because the verification stage already closed
that question and the scope ruling answers the rest. Rejecting a
verified finding is
the human's unprompted move, never one the review invites.

A closing line the PR body gets wrong — a branch member with no closing
line and no deferral the body explains, or a line naming an issue
outside the branch's set — is about the PR rather than about any file,
so it is neither a finding nor a scope question. It used to be graded
as a finding with a verdict line of its own, which sent the loop back
over something no fixer could touch: the body is frozen until the
close-out. The reviewer now reports each as a **closing-line
correction**, `add <issue>` or `remove <issue>`, in a section outside
its findings that takes no part in any verdict, in every mode, and
every round reports it again because nothing changes the body. The
orchestrator hands the last round's section to `pr-finalizer`, which
makes the corrections at the close-out and reports each as applied,
satisfied or not applied; one not applied is the human's, raised before
the ready flip. That is why the finalizer runs before the In Review
flips, which read the closing set it leaves.

A claim in the frozen body that a later commit falsified waits for the
close-out too. The orchestrator collects the stale claims its
teammates' reports name, but a report names only what its author
noticed, and a fixer round that changed behaviour the body describes
used to ship a body misstating the change with nothing in the run
reporting it. So `pr-finalizer` also checks the body's factual claims
itself, against the branch at its head and the round records, both of
which it already reads to write its section, and lists each
contradicted claim in that section beside the ones the reports named.
It corrects only what the evidence contradicts: a claim the evidence
does not settle is left alone, and the text above its section is never
rewritten.

That boundary is enforced by slots that must be filled rather than by
prose asking for judgment, and each slot has one owner:

| Slot | Owner |
| --- | --- |
| The `Scope:` block that ends the developer's report | `agents/issue-developer.md` |
| The gate that reads that block before the first review round | `skills/orchestrate/SKILL.md` |
| The ruling every finding line of a fixer brief ends in — a scope ruling, the orchestrator's ruling quoting the repo sentence that settles the finding, the standing ruling that resolved a finding outside the issue, or the human's answer on a finding the orchestrator put to them — and what it is derived from | `skills/orchestrate/SKILL.md` |
| The cases in which a finding is put to the human at all — a finding outside the issue only when no standing ruling resolves it — and that an in-scope finding is never one of them | `skills/orchestrate/SKILL.md` |
| That a finding carries one recommendation, the fix, and no rejection alternative or intent question of its own | `agents/theorem-based-pr-reviewer.md` |
| What a fixer does with a ruled finding line, and with one that has no ruling | `agents/issue-fixer.md` |
| The rule that a finding class recurring on consecutive rounds is a `recurring-finding-class` decision, what makes two findings one class, and that a class recurring after a brief that covered it goes to the human | `skills/orchestrate/SKILL.md` |
| The grading of an issue body's structural instruction against the repo | `skills/orchestrate/SKILL.md` |
| How a finding dropped on a scope ruling reaches the next round and retires | `agents/theorem-based-pr-reviewer.md` |
| How a finding dropped on a scope ruling is worded in the PR's final section | `agents/pr-finalizer.md` |
| That a closing-line correction is reported outside the findings, in every mode, and takes no part in any verdict | `agents/theorem-based-pr-reviewer.md` |
| That a closing-line correction gets no ruling and no fixer, and that the last round's section is what reaches `pr-finalizer` | `skills/orchestrate/SKILL.md` |
| How `pr-finalizer` applies a correction, which it reports as satisfied, and which it refuses to apply | `agents/pr-finalizer.md` |
| Which claims in the body above the final section are checked against the branch and the round records, and what a contradicted one becomes | `agents/pr-finalizer.md` |
| That the stale claims the teammate reports name are collected and reach `pr-finalizer` as scope notes | `skills/orchestrate/lib/pr-lifecycle.md` |
| That the files-affected list is a floor, and that listing a path changes nothing about its class, owner, or review | `skills/orchestrate-readiness/SKILL.md` |
| That a listed path grounds no theorem about the rest of the tree | `agents/theorem-generator.md` |

The reviewer's own scope theorem, in `agents/theorem-generator.md`,
is unchanged by any of this: the slots make the orchestrator act on
the theorem's answer, and none of them changes how that answer is
produced. A scope ruling is the orchestrator's judgment, never the
human's, and the reviewer keeps the two apart by retiring a
scope-dropped theorem under its own label rather than as
human-refuted.

## A documentation edit an implementer owes is a handoff, not a failure

Every file in a run is in one of the classes the global Claude
configuration defines — code, instruction Markdown, documentation —
and the class alone decides who edits it: `issue-developer` and
`issue-fixer` edit code and instruction Markdown inside the code loop,
`code-documenter` corrects the comments in both, each against its own
class's style guide, and `docs-writer` edits documentation in the
documentation loop that follows. No file in this plugin defines a
class or says which paths fall in one: the definition once lived in a
skill of this plugin's own
as well, and two copies in two repositories drifted apart whenever
either changed, so an sdlc file that needs a file's class names the
class and nothing more. Instruction Markdown is a class of its own
rather than a kind of code because the style guides grade it by its
own guide, yet it is implemented, fixed, checked and reviewed exactly
as code is: a change to one changes what an agent does, so it cannot
wait for the loop that follows the code loop, as documentation does.
Whether an issue's files-affected list names a file never moves it
between classes.

The split leaves the implementers with edits they are barred from
making. A code change that makes a README wrong, or a review finding
whose remedy is a documentation edit, used to come back as "not
fixed" or as a design decision, and the orchestrator put each one to
the human — an escalation over work that was already assigned, by
design, to a later stage. So each implementer report carries a fixed
`Deferred to docs-writer:` line, `none` when empty, and the
orchestrator collects every entry into the `docs-writer` writing brief
and raises none of them. The same line runs through a merge-readiness
remedy: a fixer round there may defer an edit too, or resolve a rebase
conflict in a documentation file — the one documentation edit it
makes, named on its `Documentation conflicts:` line — and
`pr-merge-readiness` returns `documentation loop needed` for either, in
place of returning them as a question, so the orchestrator runs a
documentation loop whose writing brief carries the entries.

An issue's own acceptance criteria used to take the same wrong turn
from the other direction. Every criterion became a theorem the review
loop settled, so a criterion about documentation sent the implementer
at a file outside its reach, and the loop stopped for a human ruling
that relayed the edit to `docs-writer` by hand. So the issue-body
grammar splits the criteria by class into
`## Code and instruction Markdown acceptance`, which the code loop
settles and which alone grounds its criterion theorems and scope
rulings, and `## Documentation acceptance`, which the documentation
loop settles the same way, one theorem per criterion, and which no code
round makes a theorem of. The `docs-writer` writing brief carries the
latter's bullets, from every member issue, under a fixed
`Documentation criteria:` line beside the deferred entries;
`docs-writer` treats each one as a required edit and grades it `met` or
`not met` in its report, and a `not met` is a finding of the round. Each
piece has one owner:

| Slot | Owner |
| --- | --- |
| The `Deferred to docs-writer:` line in the developer's report | `agents/issue-developer.md` |
| The same line in the fixer's report, and that a documentation-remedy finding goes there rather than under not fixed | `agents/issue-fixer.md` |
| That a rebase conflict in a documentation file is the fixer's one documentation edit, and the `Documentation conflicts:` line that names each | `agents/issue-fixer.md` |
| The acceptance sections, which class of criterion each holds, and that a readiness gap is raised on a criterion filed under the wrong one | `skills/orchestrate-readiness/SKILL.md` |
| That a criterion is written into the section its subject's class names | `skills/orchestrate-ready/SKILL.md` |
| That a documentation criterion becomes no theorem in a code round, and one theorem per criterion in a documentation round | `agents/theorem-generator.md` |
| Collecting the deferred entries and the documentation criteria into the `docs-writer` writing brief, and that a criterion graded `not met` goes into the round's fixer brief | `skills/orchestrate/lib/pr-lifecycle.md` |
| The `documentation loop needed` return, and which fixer lines trigger it | `agents/pr-merge-readiness.md` |
| How `docs-writer` treats the entries and the criteria alongside the diff, and how it grades each criterion | `agents/docs-writer.md` |

## Documentation is reviewed in a loop of its own, after the code loop

Documentation describes code that has settled, so `docs-writer` writes
it once the code loop has ended — and until it had a loop of its own,
nothing read what it wrote. A `## Documentation acceptance` criterion
it missed, or a README restatement the change had made stale, reached
the merge unchecked, and an issue whose criteria were all documentation
had no path through the orchestrator at all. So the code loop's end
starts a **documentation loop** rather than the close-out. It takes the
code loop's round rules as they stand — the style-fix loop, the
reviewer spawn and its `Return:` line, the fix loop's decision points,
the review adjustments — and its end follows `docs-loop-end` as the
code loop's follows `loop-end`. Its implementer is `docs-writer`: it
writes on the
first round and, on each later one, fixes the fixer brief the
orchestrator posts on the PR, read off the PR's most recent comment as
`issue-fixer` reads its own. `code-documenter` does not run in it,
since a documentation file carries no comment for it to correct.

**One pipeline, two modes.** Every round of either loop runs under a
`--mode`, `code-and-instruction-markdown` or `documentation`, passed to
`style-checker`, to the reviewer, and by the reviewer to every theorem
agent it spawns, so one review pipeline grades either side of the class
split rather than a second pipeline duplicating the first. Under
`documentation` the generator works these sources and no other: one
theorem per documentation criterion of every member issue, with the
settle mode its sub-heading names, and one per restatement in
documentation of a fact the diff changed. Code and instruction Markdown
are read only for the facts a documentation file restates, so the
documentation-paths line that keeps a code round's children off
documentation files has nothing to exclude and is absent.
`style-checker` under the same mode checks only the documentation files
the diff touched, against the documentation style guide. A brief
carrying no `--mode` is a code round, so a standalone
`/sdlc:git-review-pr` reviews as it always did unless the user passes
one.

**Round types share a sequence and split their records.** The rounds
of both loops are numbered in one sequence per PR, under one state
layout: the first documentation round takes the number after the last
code round, and the reviewer's anchor call writes the mode into the
round's log as its type. A round carries only the records of its own
type, so the first documentation round carries nothing and generates
from the whole PR, as a first code round with no seed does, and a code
round after a documentation loop carries past it to the code round
below. Theorem ids do not split: they run in one sequence across both
types, so an id names one theorem across the whole PR, and the
generator's `leave` holds a documentation round's first new id to one
above the highest id any round holds. Each type has a records chain of
its own, so the detail poster posts the latest records of each whose
round no chain on the PR already covers, the
time report names the type on every round's row, and `pr-finalizer`
writes one sub-section per type.

**A bound per loop.** The documentation loop's round bound is a key of
its own, `docs-review-max-rounds`, counted on its own, so a PR that
spent its code rounds still gets its documentation rounds; the
summary's `Review Rounds` cell carries each loop's count.

**`docs-writer` grades the criteria, and the grade can be a finding.**
Its report marks each criterion in its brief `met` or
`not met — <reason>`, grading the branch rather than its intent, and a
`not met` goes into the round's fixer brief even when the review
approved, so the loop never ends on an approval the writer itself
disputes. Scope rulings in this loop read a finding against the issue's
`## Documentation acceptance` section and against the documentation
the diff made stale — the sources a documentation round generates from
— and a closing-line correction gets no ruling at all, per "The issue
is the ceiling of the fix loop".

**A merge-readiness remedy that touches documentation gets a
documentation loop over it.** `pr-merge-readiness` used to spawn
`docs-writer` itself when a fixer deferred an edit, and that commit
reached the gate with no round over it. It now spawns none: a fixer
round that defers a documentation edit or resolves a rebase conflict
in a documentation file ends its run with `documentation loop needed`,
the orchestrator runs the documentation loop with those entries in the
writing brief, scrubs memory again, and spawns `pr-merge-readiness`
afresh. That loop is the gate's own remedy, not a reopened review
loop: the orchestrator runs it without the human's word, and a PR
already marked ready stays ready through it.

**The documentation-only path.** A batch none of whose members carries
a `## Code and instruction Markdown acceptance` section has nothing for
the code loop to implement or review, so it skips the seed and the
developer: `docs-writer` creates the branch with
`git-tools:git-branch-create`, writes the documentation, opens the
draft PR with `github-prs:pr-create`, and the documentation loop runs
from its style check. Such an issue is grouped only with others like
it, so a batch takes one path or the other whole. Each piece has one
owner:

| Slot | Owner |
| --- | --- |
| Sequencing the documentation loop after the code loop and on a `documentation loop needed` return, its scope rulings, its separate bound, and skipping the code loop for a batch with no code to implement | `skills/orchestrate/SKILL.md` |
| The `docs-writer` briefs — writing, fixer address, new branch — how a documentation round's fixer brief is posted, and what ends the loop | `skills/orchestrate/lib/pr-lifecycle.md` |
| What `--mode` means to a theorem agent, and which brief carries it | `skills/theorem-agents-interface/SKILL.md` |
| Which classes a round reviews under each mode, and that the mode is the round's type | `agents/theorem-based-pr-reviewer.md` |
| The documentation-mode sources, and that no theorem under that mode is about code or instruction Markdown | `agents/theorem-generator.md` |
| Which files `style-checker` reads under each mode, and against which guide | `agents/style-checker.md` |
| The round type in the anchor, the same-type carry, the cross-type id sequence, and the type a round anchored before rounds had one is read as | `skills/agent-result-persist-interface/SKILL.md` |
| How `docs-writer` reads a fixer brief, grades a criterion, and creates the branch and PR on the documentation-only path | `agents/docs-writer.md` |
| The `documentation loop needed` return, and that no `docs-writer` is spawned for a remedy | `agents/pr-merge-readiness.md` |
| One final-section sub-section per round type, and which records each is read from | `agents/pr-finalizer.md` |
| When a chain carries a type's latest records, and in which order | `bin/sdlc-pr-post-theorem-records` |
| The type column on the time report's per-round rows | `bin/sdlc-orchestrate-analysis` |

## The theorem set is seeded from the issues before the developer runs

The first theorem list the human sees is generated from the issues
alone and settled — ruled on by the human, accepted whole under
`seed-review: accept-as-emitted`, or settled by the assessment's
recommendations under `accept-recommended` — before the batch's
developer is spawned,
so a developer that goes beyond the issues, or decides something they
do not, surfaces in the first review round as new theorems against a
list the human already owns. That seed is **round 0**: rounds count
implementer passes from 1, and 0 is the pre-loop stage.

Round 0 runs through `theorem-based-pr-reviewer`, as every other round
does. The orchestrator spawns the reviewer on its seed brief, which
names the batch's issues and the source branch and no PR, and the
reviewer picks the generator's tier by its own rubric, read against
the issue bodies where a review round reads a delta, then spawns the
generator on an issues-only brief and the assessor on the list it
emits. The seed used to be a path of its own outside the reviewer,
with the rubric applied by hand and nothing holding the result to the
rubric's cap, so a seed could run at a tier the rubric never picks
with no override given (issue #725). With one spawner there is one
place the tier is picked and one set of briefs.

The seed reviewer persists nothing and posts no review — every path
`bin/sdlc-agent-result-persist` composes is keyed on a PR reference,
and none exists yet. It reports the list, the assessment, the tier
that ran, and the agent ids of the generator and the assessor it
spawned back to the orchestrator, which holds them until the
developer's PR is open and
linked, when the ruled list is written as round 0's records file and
the tier the seed generator was spawned at as the generate-stage
`spawn` record in round 0's log. The seed reviewer ran no round, so
the time report counts its span as agent work rather than as a review
round. The report takes a reviewer for the seed's only when it was
spawned before the run's first `issue-developer`, so in a transcript
with no `issue-developer` spawn the seed reviewer's span counts as a
review round and no seed-ruling wait is measured. Round 0 holds that
file, that log
line and, under `accept-recommended`, a `seed-review` log line, and no
anchor, result file or review, and `--mode rounds` leaves
it out, so a walk over a PR's rounds never sees it, and a PR with no
round 0 — one reviewed outside the orchestrate loop, or one whose seed
was lost with the session that took it — is reviewed from its whole
diff, with the review saying so.
The seed is the code loop's: a documentation round carries only
records of its own type, so the first one reads no seed and generates
from the whole PR the same way, with the review saying so, and a batch
with no code to implement has no seed at all.

The candidates do not reach the human raw. `theorem-assessor` makes
the assessment: the seed reviewer spawns it on the seed generator's
list, so the assessment is in hand before the orchestrator asks, and
the agent judges each theorem against the
issues and the tree of the source branch. The seed reviewer applies
none of it; settling the seed stays the orchestrator's. The orchestrator once made
that assessment itself, in its own session with no spawn; it is an
agent's now so that the seed and every review round judge a list on
the same criteria, stated in one file. Across the set the assessor
names the code and instruction Markdown criteria no candidate tests,
each with a proposed theorem to add; a documentation criterion is never
a gap, since no seed theorem is made from one. It recommends one action
per theorem with a one-line reason, and the orchestrator presents the
theorems recommended for a change first, then the coverage gaps with
their proposed adds, then the "accept" group, so the human reads what
needs a decision first. The human's
ruling set is accept, reject, change settle mode, merge, split, rewrite
and add. The assessment is advice: a theorem the human does not name is
accepted as the generator emitted it, not as recommended, and a claim
the assessor proposed becomes a ruled claim only when the human
adopts it, all at once or by name. That keeps round 0 a transcription —
every claim in it is the generator's or the human's, so no round-0
record is marked as the assessor's — and keeps the
orchestrator from carrying review vocabulary on the human's behalf.

That adoption rule is a policy, and `seed-review: accept-recommended`
is its one exception: by choosing the value in config the human adopted
every recommendation in advance, so the orchestrator applies each one,
coverage-gap adds included, with no human step. Round 0 is still a
transcription, of the assessment rather than of a reply, and its
records say whose each ruling is: a theorem the assessment rejected or
merged away is retired as `assessor-rejected`, and a record whose claim
came from a merge, split, rewrite or add carries `minted-by: assessor`.

Those marks cannot say who accepted a candidate, because an accepted
candidate's record is the candidate as emitted under every value. So
under `accept-recommended` round 0's log carries one more record,
`seed-review <instant> accept-recommended`, marking the whole seed as
applied by recommendation. Where it is present, the time report lists
the seed's rulings as applied under config, quotes no human reply for
them and labels no wait as the seed ruling, and the PR's final
section attributes the seed's rulings to the recommendations. Under
`ask` and `accept-as-emitted` the record is not written, and a round-0
log without it is a seed the human ruled on or one accepted as emitted.

Each piece has one owner:

| Slot | Owner |
| --- | --- |
| The issues-only brief, and what the generator emits on it | `skills/theorem-agents-interface/SKILL.md` and `agents/theorem-generator.md` |
| The seed brief, the tier pick against the issue bodies, the seed generator's and the seed assessor's spawns, and what the seed reviewer reports back | `agents/theorem-based-pr-reviewer.md` |
| The seed reviewer's spawn, when a generator tier override rides it, the order the candidates are shown in, the ruling set the human chooses from, and the per-theorem ruling or what settles the list in its place under a `seed-review` value that does not wait | `skills/orchestrate/SKILL.md` |
| The assessment's criteria, the coverage gaps, the recommendations and the format they are written in | `agents/theorem-assessor.md` |
| The assessor's seed brief | `skills/theorem-agents-interface/SKILL.md` |
| The round-0 write — the record outcome of every ruling, what each one transcribes onto round 0's records, the record each recommendation becomes under `accept-recommended` and which of those carry `minted-by`, when the `seed-review` record is written, and the seed generator's `spawn` record carrying its tier | `skills/orchestrate/lib/pr-lifecycle.md` |
| Round 0 as a valid round number holding a records file and a log with the seed's `spawn` record and no anchor, read as a code round, and the `seed-review` mode and its record's grammar | `skills/agent-result-persist-interface/SKILL.md` |
| A record without `state`, the seed ruling as a `human-refuted` source and the applied seed assessment as an `assessor-rejected` one, and round 1's delta over the whole branch | `agents/theorem-based-pr-reviewer.md` |
| How the time report words a seed's rulings under the `seed-review` record, the report the seed-ruling wait is measured from, and which reviewer spans count as review rounds | `bin/sdlc-orchestrate-analysis` |
| Whose the seed's rulings are in the final section | `agents/pr-finalizer.md` |
| That the seed generator reads the files-affected section in place of a diff | `agents/theorem-generator.md` |

## Every generated list is assessed before a disprover runs

A review round's generator adds theorems, and only the seed list used
to be assessed, so a duplicate, a compound claim, or a claim that only
a live run of the merged change could settle reached a disprover
unchallenged. Every round whose generator ran now gets an assessment
too, in either mode, a fallback round and an adjustment-only round
included: the reviewer spawns `theorem-assessor` on what the generator
emitted, after the generate stage and before the disprovers fan out.
The assessor runs even when the generator emitted no theorem, because
naming the criteria no theorem tests is part of the assessment. An
empty-delta round spawns no generator and so no assessor, and a theorem
minted from an adjustment comment is never assessed, since its claim
quotes the human.

A round's assessment is applied with no human step, where the seed's
is advice the human rules on unless `seed-review: accept-recommended`
adopted it in advance. The reviewer transcribes every
recommendation onto the round's new records and assigns every id: a
rejected theorem is recorded as retired, a rewritten one keeps its id
under the proposed claim, a split keeps the id for its first part and
mints one for each further part, a merge retires its originals and
mints the merged claim, and each coverage gap's proposed theorem is
minted as an add. The round's review lists each recommendation applied
other than an accept, so the human reads what the assessor changed
after the fact rather than ruling on it before.

The carried records are context to the assessor, which reads them out
of the PR's state itself, as the generator does. It recommends nothing
on one, counts a carried theorem that passed a round as covering its
criterion, and treats a claim the human refuted as closed: it
recommends rejecting a new theorem that makes it and proposes no add
that would.

The assessment is a stage of the round log, `assess`, between
`generate` and `disprove`, settled by the assessor's result file.
`next` prints no disprover work until that stage is settled, so no
disprover spawns on an unassessed list, and a resumed reviewer applies
the stored assessment rather than spawning the assessor again.

Two marks on the records keep an assessor's ruling apart from a
human's and from the generator's:

- A theorem the assessor rejected, or merged away, is retired as
  `assessor-rejected`, never as `human-refuted`. A `--full` round
  leaves only `human-refuted` records off its live list, so it
  disproves an `assessor-rejected` theorem, one rejected in that same
  round included: a human's rejection is final, and an assessor's is
  re-tried by the same round that re-tries every other retirement.
- A record whose claim came from an applied merge, split, rewrite or
  add carries `minted-by: assessor`, every part of a split included,
  so the posted review and the PR's final section never attribute that
  claim to the generator or the human. Only a recommendation applied
  with no human step is stamped — a review round's, or the seed's
  under `seed-review: accept-recommended`; a seed claim the human
  adopted in reply is the human's.

Each piece has one owner:

| Slot | Owner |
| --- | --- |
| What each theorem is judged on, the coverage gaps, which carried records count as coverage, and the assessment's output format | `agents/theorem-assessor.md` |
| The assessor's review-round brief, and the `--base` parameter that names the tree before the change | `skills/theorem-agents-interface/SKILL.md` |
| Which rounds are assessed, which theorems the assessor is handed, the record each recommendation becomes, the order ids are assigned in, and which records carry `minted-by` | `agents/theorem-based-pr-reviewer.md` |
| The `assess` stage and its arm in `next`, the `minted-by` field, and which retired records a `--full` round's live list holds | `skills/agent-result-persist-interface/SKILL.md` |
| That a `minted-by: assessor` claim is the assessor's in the final section | `agents/pr-finalizer.md` |
| The assessor's phase in the time report | `bin/sdlc-orchestrate-analysis` |
| That a round's assessment follows the list it assesses in the review detail | `bin/sdlc-pr-post-theorem-records` |

## Carried records move through state, not a brief or an agent-built file

From round 1 on, `bin/sdlc-agent-result-persist` assembles the round's
records file; the reviewer never does. Its carry form reads the round
below the one under way, applies the reviewer's edits, appends the
records the round minted, and writes the result, and the reviewer
stages only its decisions — an edits file and a new-records file, each
written with `Write`. Building the whole file was a mechanical
transform the reviewer used to perform with a program of its own, and
the auto-mode classifier denies a per-instance program, so a round
whose build was denied stored nothing and posted nothing. The carry
form makes no decision: a carried record changes only where an edit
names it, and the state each edit stamps is the one `--mode dispose`
derived for the theorem, transcribed by the reviewer into the edits it
stages. Round 0's seed is the one records file still stored whole,
because it has nothing to carry.

The generator reads the carried records out of the PR's state itself,
on a delta round, with the repository, PR and round its brief already
carries; no brief carries the records. An inline copy grew with every
round, and a brief that outgrew its room handed the generator something
other than the records verbatim — a reused id, a missed retirement, a
theorem a human had rejected minted again.

Both reads are bounded by the round under way: the generator's read and
the carry pick the highest round **below** that number holding records,
through one selection function, so they can never disagree. The bound
is what lets a resumed reviewer store its round again through the same
call — it rebuilds from the input its predecessor built from, never
from its predecessor's output — and it is what makes a stale round
number fail at the read, before anything is generated against the
rounds below. A round whose previous head can no longer be fetched
still carries: its delta becomes the whole branch, but its ids continue
the sequence and its retired theorems stay retired.

Both reads select by the round's type as well, which the round's own
anchor names rather than a flag beside the round number: a
documentation round reads past the code rounds to the documentation
round below it, and a code round reads past the documentation rounds,
because a documentation round's verdicts answer none of a code round's
questions. The ids are what the split leaves whole. A new theorem's id
is one above the highest id any round below holds, of either type, so
an id names one theorem across the PR. A later detail chain can carry
an id an earlier one holds, because it posts its round type's latest
records again, and the record in the chain covering the higher rounds
is that theorem's latest state.

The ids a generator gives its new theorems are checked at its `leave`,
against the same carried records its read returned and the same id
floor, and a list whose
ids collide with a carried record or skip ahead of the sequence is
refused before any of it is stored. The carry form already refused such
a list, but it runs in the reviewer after the generator has returned,
so the generator that numbered from `T1` without reading the records
had already cost a round. Refusing at `leave` puts the check at the
one moment the generator can still renumber and try again, and the
refusal names the expected next id so that renumbering is mechanical.
The id rule is one implementation inside the script, loaded by the
`leave` check and the carry form alike, so the two cannot drift apart.

The same `leave` checks that the list is whole. A generator's list ends
with a count line, `COUNT: mechanical <m>, semantic <s>`, and a list
whose last line is not that line, or whose counts do not match the
settle modes of its records, is refused with nothing stored. The list
used to close with a count in no fixed format, which nothing read, so a
list with no count or a wrong one was stored like any other and the
round fanned out over it. A count-line refusal lands where an id refusal
does, while the generator can still correct the list, and draws on the
same bound of `leave` calls. Each piece has one owner:

| Slot | Owner |
| --- | --- |
| The carry form — its inputs, the edits grammar, the records-file shape, and each refusal | `skills/agent-result-persist-interface/SKILL.md` |
| The bounded read, its selection by the round's type, and the refusal that bounds it | `skills/agent-result-persist-interface/SKILL.md` |
| The id check a generator's `leave` makes, that the expected id is above the highest of either type, and what its refusal names | `skills/agent-result-persist-interface/SKILL.md` |
| What the reviewer stages as edits and as new records for the live list | `agents/theorem-based-pr-reviewer.md` |
| The stamps the reviewer transcribes into those files before it stores the round, and which form a fallback round stores through | `skills/lib/theorem-based-pr-reviewer/review-body.md` |
| That `--delta-commits` alone marks a delta brief, and the `print-records` line it carries | `skills/theorem-agents-interface/SKILL.md` |
| The generator's own read, and the stop when it fails or prints no records | `agents/theorem-generator.md` |
| The generator's renumbering on an id refusal, and the bound on its retries | `agents/theorem-generator.md` |
| The count check a generator's `leave` makes, which lines it counts, and what its refusal names | `skills/agent-result-persist-interface/SKILL.md` |
| That the list ends with the count line, where the line sits beside retirements, and the generator's correction on a count-line refusal | `agents/theorem-generator.md` |

## A child's hand-back is evidence of its `leave`, never a substitute

A child the reviewer spawns on a PR settles its theorem only through
the result file its `leave` call writes; its hand-back to the reviewer
carries the same text, but the reviewer never grades from it. That
rule left a gap: nothing tied the hand-back to the write, so a child
could end its turn with a verdict in its message and no file, and the
reviewer could not tell that child from one still running. It waited
out the child's deadline, wrote it off, and spawned a replacement, at
the cost of the whole deadline per occurrence. The repair ties the two
together. A child makes its `leave` call before it composes its
hand-back, the call prints the result file's path only once both the
file and the record have landed, and that path is the hand-back's
first line; a child whose call failed hands back a failure report
carrying no verdict, so nothing in it can be mistaken for the file
that was never written.

The path line says what a child wrote, and no hand-back says the child
has finished. The harness delivers one — a `<task-notification>`, or an
`Agent` tool result — whenever the child ends a turn, and a child can
end a turn and keep working: one that ends its turn over background
work of its own wakes when that work exits and carries on, so its
`leave` can still land after any hand-back. A child is therefore
finished only when it writes its own `leave`, and one with none stays
in flight until its `leave` lands or its enter deadline passes,
whatever it handed back; only then is it printed `overdue` and written
off. A child that ended with no file is thus still waited out to its
deadline, a cost accepted because every shortcut around it wrote off a
child that was still running. Two earlier versions of this rule ended a
child's flight sooner. The first read every
notification as final, and a generator mid-run was written off on its
interim one, its list landing minutes after the round had ended with
nothing posted. The second told a final notification from an interim
one by its meaning and wrote a child off at once when a final one
arrived with no `leave`, on the reasoning that a child that finished
without saving never would; the child went on to write its result
while its replacement ran. The reviewer still records a final
notification, as a `return` record, but the record is telemetry and
changes nothing `--mode next` prints. The write-off `TaskStop`s the
child first when the reviewer spawned it: a child past its deadline can
still be running, and its late `leave` and result file would overwrite
its replacement's, stopping the round on a list conflict. The deadline
is a figure the reviewer passes, not one the script holds.

A reviewer that only ends its turn and waits for a notification cannot
survive a child in the waiting state: a nested parent that ends its
turn while its only child has ended a turn over background work is
made to hand back, and the child's final report then goes to the main
session rather than to the parent. A parent holding a background
command of its own is not made to hand back. So before ending any turn
that waits on a stage, the reviewer ensures a
`sdlc-agent-result-persist --mode wait` it started over that stage is
running in the background. The command blocks until a `leave` lands in
the stage, the earliest awaited child's deadline passes, or no child is
left to wait on, and its exit resumes the reviewer like any
notification — which also wakes it at a deadline when no notification
ever arrives. The wait's deadline is the same figure the reviewer passes
`next`, measured from a child's `enter`, or from its theorem's last
`spawn` while it has not yet entered, so a wait started right after a
spawn does not exit before the child has written its `enter`. The
reviewer records every child it spawns with `--mode agent` by the id
its `Agent` call returned, so a child written off before its `enter`
still has a record naming its worktree for cleanup, and the `stopped`
that writes one off names it `-`.

Which children are in flight, and which are spawned and yet to enter,
is the script's answer, through `--mode print-in-flight`, `--mode next`
and `--mode wait`, rather than something the reviewer derives from the
log itself. A theorem is awaiting its child's `enter` exactly when its
last `spawn` in the stage is followed by neither an `enter` nor a
`stopped`, decided by the order of the records and never by comparing
counts of `spawn` and `enter` records: a count would let a `stopped`
for an earlier child, landing after a later `spawn`, cancel the
replacement's wait. The derivation used to be an
`awk` snippet in the interface skill, run by the reviewer by hand, which
the suite could not drive; it now lives beside the rest of the state
logic, where the suite does. Moving it into the script also fixed how a
`stopped` record is
matched to a child: it names the child's agent id, and a `stopped` is
matched to the `enter` carrying that id, never to whichever `enter` of
the theorem it happens to follow. A `stopped` keyed on the theorem
alone wrote off whichever child the theorem had when the record
landed — an original child's late `stopped` wrote off its replacement.
A `stopped` record written before the id was part of the record names
no child and so matches none; a child written off that way stays in
flight until its deadline comes round again, when the next `stopped`
names it. Each piece has one owner:

| Slot | Owner |
| --- | --- |
| What a `leave` prints, what `print-in-flight` reports and how it matches a `stopped` to a child, and that `stopped` names the child it writes off, or `-` for one that never entered | `skills/agent-result-persist-interface/SKILL.md` |
| The shape of a child's hand-back after a `leave` that succeeded, and after one that failed, that a hand-back is delivered whenever a child ends a turn, and that a missing `leave` is never final on one | `skills/agent-result-persist-interface/SKILL.md` |
| That each child calls `leave` before composing its hand-back, and never ends a turn over background work of its own | that child's own file under `agents/` |
| The `overdue`, `in-flight` and `spawned` lines `next` prints, what makes a child each, and that a `return` changes none of them | `skills/agent-result-persist-interface/SKILL.md` |
| What `wait` waits on, each line it exits with, and how often it reads the log | `skills/agent-result-persist-interface/SKILL.md` |
| The rule that a theorem awaits its child's `enter` by the order of its records, and which `stopped` ends that wait | `skills/agent-result-persist-interface/SKILL.md` |
| That only a final notification is recorded, with a `return`, and that the record is telemetry | `skills/lib/theorem-based-pr-reviewer/resume.md` |
| That a child that handed back without a `leave` stays in flight until its `leave` or its enter deadline, that the deadline write-off `TaskStop`s a child the reviewer spawned before re-spawning, and that the re-spawn counts as a resume pass | `skills/lib/theorem-based-pr-reviewer/resume.md` |
| That a `wait` the reviewer started is running whenever it ends a turn waiting on a stage, and that such a turn is not a hand-back | `skills/lib/theorem-based-pr-reviewer/resume.md` |
| That the reviewer records each child it spawns with `--mode agent`, and spawns nothing on a `spawned` line | `agents/theorem-based-pr-reviewer.md` |

`test/sdlc-test.sh` drives the script's records and round-log modes
against a state root of its own — the seed write, the carry form, each
refusal it makes, the bounded read, the generator's id check at
`leave`, the path `leave` prints and its refusal of a result path
carrying whitespace, the in-flight derivation with a
`stopped` landing after its replacement's `enter`, a child written off
before its `enter` named by its `agent` record, `repos`' refusal of
every flag but `--mode`, and the round types:
the type an anchor writes and the refusals around it, the `round-type`
line `print` ends with, a first documentation round carrying nothing
while its ids continue the code rounds', a code round carrying past a
documentation round, the carry's cross-type id floor, and
`print-records`' selection by type. It drives the detail poster
posting each type's records, and every round with a log where the logs
start above round 1 or skip a number; a supplementary chain over the
rounds above those the PR's complete chains cover, with an old-form
or partial chain covering none and a re-run with no new round posting
nothing; and a piece over the chunk limit split across chunks, with a
code fence open at the break and a line cut at a character boundary.
It drives the time report's type column, its row for the assess
stage, and a seed reviewer's span counted outside the review rounds,
against the same root, and the detail poster placing a round's
assessment after the list it assesses. The
same suite
drives the PR-read scripts against a stub `gh` that serves a PR's
reviews and comments — each script's output and exits; the round
number over stamped, unstamped, code-scanning and human reviews beside
round logs that start above 1, skip a number, hold a round begun and
not posted or a round with a log and no review file, or are absent, and
its exit on a failed state read; every case of
the adjustment cut, a code-scanning or human review that must not set
it among them; and that the adjustments read reaches the previous
round's log through the persist script and nothing else — and checks
that a command any executable under `bin/` does not handle exits
through that executable's own failure status. It drives
`sdlc-decision` against the same kind of root: each refusal `ask`
makes, a `command:` evidence that would leave a marker if run, a
record a ruling resolves and an `unclassified` one no ruling resolves,
the answer to a multi-problem record, a later answer to a problem a
reply left open, `pending` before and after a design gap is answered,
`question` on a record with and without a stored question, where a PR's
and an issue's
records are stored, and the `repo.yml` `ask` writes and its move of
old-layout state. And it drives the time report's Decisions table over
the records of a PR, of the issue it closes and of a member its branch
names that it does not close. It needs bash, `jq`, mikefarah `yq` v4
or later, the POSIX utilities and `git-tools`' `git-issue-branch` in
the same checkout, and reaches no network.

`bin/test/sdlc-agent-result-persist-test.sh` drives the derivation
modes the same way, each case against a state root of its own: every
arm `next` names and every child state it prints — a `stopped` after
its `enter`, a child `spawned` and yet to enter and one overdue from
its last `spawn`, a child with a `return` and no `leave` in flight
before its deadline and overdue past it, a `-` write-off before the
`enter` and a replacement
spawned after it, a duplicate `leave`, a moved head, a malformed
`DISPROVED` report that earns no verifier, a generator re-spawned at
another effort leaving a settled list settled, the `assess` arm with
no disprover line printed before the assessor's file settles it, a
stage past the arm printing its children in flight and spawned and none
of its outstanding or overdue theorems, a child spawned or entered for a
theorem no records file names printed in its stage and past the arm,
an empty assessment refused at
`leave`, a generator's list refused at `leave` for its count line or on
a failed read of its ids or count line, leaving no staging file, and the
live list under
`--edits`, `--from` and `--full`, with a theorem the assessor rejected
that round off a default round's list and on a `--full` round's;
`wait` over the `assess` stage, and ending on a `leave`, on the
earliest child's deadline with a child yet to enter included, and at
once with no child to wait on, and its refusal without
`--deadline-minutes`; every row of
`dispose`'s disposition table with the state it stamps, a
`class-underivable` finding, a human override, an `UNSETTLED` report
missing its `REASON` or its `CHECKED` taking the malformed row and a
`SUBJECT REMOVED` report missing either doing the same, a round
approving when its only theorem that did not survive is retired as
`subject removed`, an
unsettled theorem forcing `BLOCKED`, a member of `--issues` no record
tags, the refusal
without `--loop-exited`, the round that spawned nothing, and an
`assessor-rejected` theorem given a row on a `--full` round and none on
a default one; the
body `summary` renders, the stamp it opens with, its carried-forward
paths and its refusals; and `rounds` over a PR with no state and over
rounds with and without a log, round 0 and a voided round among them,
and its refusal of `--round`; and `progress` over a PR with no log, a
round mid-`disprove` beside a higher voided round, a round holding a
review file, a log with no child record and one with no anchor, and its
refusal of `--round`, `--from` and `--edits`. It reaches no network.

## A reviewer's in-progress hand-back is waited on before any re-spawn

The reviewer is a child too, and what holds for its children holds for
it: the harness hands its turn-end to its caller whether or not it has
finished. An in-progress `Return:` line is therefore not yet a stalled
round. The orchestrator used to re-spawn the reviewer on that line
while the first reviewer went on to post its review, and the second
spawn ran a needless round that counted against the PR's cap.

So a caller holding an in-progress line waits on the round log first.
It runs the stage-level `--mode wait` the reviewer itself runs, pass
after pass, until the round has posted its review or no child is in
flight in any stage, and re-spawns the reviewer only when the wait ends
with neither. A review the round posted is the round's result whenever
it posted, before the hand-back arrived or during the wait, and the
caller acts on its verdict. Such a review used to be put to the human,
to choose between letting the round stand and re-spawning over it.

The wait rests on these properties:

- `--mode next` prints the children in flight, and those spawned and
  yet to enter, in a stage past its arm and for a theorem no records
  file names yet, because the waiting caller asks whether any child is
  running anywhere in the round. A later stage's outstanding and
  overdue theorems stay unprinted: they would tempt a spawn or a
  write-off across the barrier between stages.
- Each pass reads `--mode next` before it re-derives the round, so a
  review posted while the last children leave is seen, rather than
  missed behind a read that already showed no child in flight.
- `/sdlc:git-review-pr` reads the round's number before it spawns the
  reviewer, since a read after the review has posted names the round
  above.
- The wait is the reviewer's own command, so the script has no mode
  that exists for a caller alone.

Each piece has one owner:

| Slot | Owner |
| --- | --- |
| The orchestrator's wait on an in-progress `Return:` line, the order of its reads, that a posted review is the round's result, and when the reviewer is re-spawned | `skills/orchestrate/SKILL.md` |
| The standalone review's wait, and that it reads the round before each spawn | `skills/git-review-pr/SKILL.md` |
| Which lines of a stage past the arm `next` prints | `skills/agent-result-persist-interface/SKILL.md` |
| When the reviewer hands back an in-progress status | `skills/lib/theorem-based-pr-reviewer/resume.md` |

## The round is derived from the log, never from memory

A fan-out wait ends the reviewer's turn, and nothing it merely
remembers survives the boundary. Rebuilding the round from memory on a
resume left returned disprovers uncrossed-off and burned a round's
budget on theorems that had already reported (issue #351); the log and
the result files are what every resume derives the round from since.
The saving is the settled set: a stalled round that had settled 4 of 24
theorems resumes with 20 to run, not 24, because a settled theorem's
report is on disk in full and no spawn can recover anything a record
left out.

The notification is not the thing to build a round on either. A child
that ran and did its work can still end without making its `leave`
call, and the harness can drop a notification outright. Every loss a
round has to survive is of that shape — never a child that failed to
run — so each child records its own entry and exit, and nothing the
reviewer derives depends on having heard back.

## The derivations are the script's, and the judgment calls the reviewer's

The reviewer used to carry a state machine in prose — which arm a
resumed round is in, which theorems are outstanding, in flight or past
their deadline, the disposition table, the class-to-severity
transcription, the per-issue and overall verdicts and the posted body's
shape — and the model ran it by hand on every resume, with the
interface skill's `awk` one-liners as its tools. Each run of a
derivation by a model is a fresh chance to get it wrong, and nothing
could test it. So the derivations moved into
`bin/sdlc-agent-result-persist`, as pure reads over the round's log,
records and result files: `--mode next` prints the arm and the work
left in each stage, `--mode dispose` prints each live theorem's
disposition, class, severity and the state to stamp, then the verdicts,
and `--mode summary` renders the posted body from the stored records
and review. The reviewer runs them and transcribes; the behavior each
derives is what the prose specified, now deterministic and driven by a
suite.

The invariants the reviewer used to hold as prose are now properties of
the script's output. **One child per theorem per stage**: `next` never
prints a theorem with a child in flight, or one spawned and yet to
enter, as `outstanding`, and the reviewer spawns only on `outstanding`
lines, so no instance can spawn beside a running child or beside one
that has not yet written its `enter`. **A verdict's only admissible
source is the child's own result file**: `dispose` reads verdicts from
result files and nothing else, so a theorem whose child wrote no report
has no verdict and takes its stage's no-verdict row, and a
`<task-notification>` can never be read as one.

What stays with the reviewer is what no script can decide: the tier
rubric, reading an adjustment comment into the edit it means, the
issue-set findings and their grading, the argued review's prose, the
briefs it writes, and raising a `NEEDS_CHANGES` to `BLOCKED` because a
fix lies outside the issue's scope and needs a human. Nothing lowers a
verdict `dispose` printed. The reviewer stages its decisions — an
edits file of this round's retirements and severity overrides, and a
new-records file of the theorems first recorded this round — and
`next` and `dispose` derive the live list from the carried records and
those two files, so the list is read from what the reviewer wrote down
and never from what it remembers.

The adjustments the reviewer used to make between the class table and
the human override were **deleted, not moved**: the floor that raised a
finding on an acceptance-criterion theorem to at least High, and the
cap that held a finding whose whole remedy was a comment change to at
most Low. Severity is a property of the consequence of merging the PR
as it stands, and both adjustments graded by something else — the
theorem's origin, the remedy's size — on top of a class an agent that
read the code had already assigned. A severity is now that class's, or
High where no class could be derived, or the human's override, and
nothing else.

The script being the classifier settled what a round does at its
edges. A `DISPROVED` report whose `CONSEQUENCE-CLASS` line holds no token is
**well formed with its class underivable**, where the disprover's own
output rule had counted it malformed: a report routed to "could not be
settled" on that line alone would never reach a verifier, and the
`class-underivable` finding — verifier malformed, disprover's proposal
no token — would be unreachable. And **a stalled stage posts**: when
the resume-pass loop exits with `disprove`- or `verify`-stage theorems
lacking a verdict, each takes its no-verdict row and the review posts,
because an unsettled theorem already forces `BLOCKED` and the round has
something to say. Only a loop exit in the `generate` or `assess` stage
is still an in-progress escalation, since a round with no settled
theorem list has nothing to post.

## A stall is reported as what the log shows, never as starvation

The concurrency ceiling is readable from
`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, but no documented tool,
environment variable or API exposes the slots in use or the queue
depth. Waves keep a round off that edge; starvation, if it happens
anyway, shows only as absence of progress — which the bound on resume
passes catches — and never as a cause the reviewer can name. That limit
is known and deliberate, not a gap to close by inventing a mechanism.

`No task found with ID` reads as gone, not as still occupying a slot.
When a resumed reviewer tried to stop its own children after a
suspension, every `TaskStop` returned that error. Whether those
children were dead or merely unreachable is unverified, and treating
their theorems as re-runnable assumes the former.

## A verifier's deadline reuses the disprover's figure

The disprover deadline is sized off a measured worst case, stated
beside the deadline in
`skills/lib/theorem-based-pr-reviewer/resume.md`. No verifier
measurement exists, and a verifier's work is a strict subset of a
disprover's: it reads one counterexample against one head tree and runs
no search. A shorter deadline derived from that subset relation would
be a guess, and what the guess costs when it is wrong is `TaskStop`ing
a verifier that was about to report, which drops a real check. So the
verifier reuses the disprover's figure until one is measured for it.

## A moved head voids the round, and the restart never mixes trees

The round's `anchor` record carries the head SHA its theorems were
generated against, and a head that differs from it — reported by
`--mode next` as `moved-head` at the anchor step, or found at the fetch
before the disprovers fan out — voids the round:
the records describe a tree that no longer exists, so they are set
aside and the review names both SHAs. This is not hypothetical; the
scheduled rebase sweep force-rebases open PR branches and can fire
mid-round. The restart runs the round fresh against the new head rather
than carrying verdicts from the old tree into it, and the restart's own
anchor call, carrying the new SHA, is what keeps the void from
repeating: the next instance to arrive reads an anchor naming the
current head and resumes normally.

## Every counterexample is re-checked before it becomes a finding

A counterexample nobody re-checked is one agent's word: the quote can
be misread, the excerpt can be cut against its own context, the
consequence can be overstated. So every `DISPROVED` theorem gets a
second, adversarial reader briefed to reject the counterexample, and a
counterexample becomes a finding only where that stage ran its course
without rejecting it. The same failure is why a finding must quote its
evidence verbatim: paraphrase produced fabricated findings, where the
"offending text" the reviewer claimed to see did not exist (issue #64).

The cheaper check runs first, and it is a check of shape. A `DISPROVED`
report that lacks the lines its template requires — a quote block under
its `EVIDENCE:` line among them — is malformed, never reaches a
verifier, and its theorem is left unsettled and live again next round:
spawning a verifier against it would waste the check on a report that
has already failed a cheaper one, and spawning a second disprover would
break the one-child-per-theorem invariant. Whether the quote is
**verbatim** is not a question of shape, so a `DISPROVED` report whose
quote is present but matches nothing at the head commit is well formed
and reaches a verifier, which is the reader briefed to reject it. The
canonical instance is a quote taken from another ref, such as `main` or
`origin/<base>`, which reads as real prose and matches nothing at the
head commit; a filesystem quote from the primary clone is the rarer
instance, because the permission gate denies a read naming a
primary-clone path.

## A claim the disprover cannot reach is unsettled, never survived

A survival is a claim checked against the tree or a command's output.
Some claims cannot be checked that way — settling them needs a live
run, a remote event, or a runtime the disprover cannot exercise — and
with only `DISPROVED` and `SURVIVED` to report under, a disprover that
reached the edge of what it could run reported a survival on general
knowledge of the runtime it never ran (issue #668). That survival
reached the posted review with the weight of a checked one, and the
theorem retired on it, so no later default round looked again.

So the disprover has a verdict for that edge, `UNSETTLED`, and it is
graded as a pipeline defect rather than as a result: the theorem is
stamped `unsettled`, which blocks the review and keeps it on the live
list for the next round, so the gap reaches a human instead of retiring
as checked. The report carries both why the claim is out of reach and
what was checked, so the human reading the block can tell a claim
nobody can settle from one the disprover gave up on.

## A claim whose subject is gone retires, unless the claim requires the subject

A carried theorem is about the tree as an earlier round saw it, and a
later commit can remove what it is about. The generator retires such a
theorem when it notices, by listing it under `RETIREMENTS`, and one it
missed used to stay live: its disprover found nothing at its pointers
to attack and reported `UNSETTLED`, so the round was `BLOCKED` on a PR
with no finding, and clearing it took a human rejection in an
adjustment comment and another full round (issue #728).

So the disprover has a verdict for that case, `SUBJECT REMOVED`, and a
carried theorem that gets it retires as `subject removed`, with no
severity and no part in any verdict. The retirement no longer depends
on the generator noticing; its `RETIREMENTS` path is unchanged, and
either route puts the theorem on the review's skipped line.

A verdict that retires a theorem with no finding is the dangerous one
to hand out, and the decisions around it are what keep it narrow:

- **What the claim requires decides, not how the subject went
  missing.** A claim that requires the PR to add or keep its subject —
  an acceptance criterion calling for text the branch does not carry —
  is `DISPROVED`, with the absence as its counterexample, whether the
  PR never added the subject or a later commit deleted it. Only a
  claim that merely describes the subject, such as how a function the
  branch has since dropped handles an input, is `SUBJECT REMOVED`.
  Keying the verdict on a commit that deleted the subject was tried
  and dropped: a force-rebase can drop that commit from history and
  leave the subject just as absent.
- **A claim that asserts the absence is not about a missing subject.**
  The absence is what it claims, so it is checked like any other claim
  and survives when the absence holds.
- **An absent subject is asked about first**, ahead of whether settling
  the claim needs something the disprover cannot run. Otherwise a
  claim that needed a live run while its subject existed would stay
  `UNSETTLED`, and block, after the subject was gone.
- **Only a carried theorem retires on it.** A theorem minted in the
  round that returns the verdict was written against the very head its
  disprover read, so no later change removed its subject. It is
  stamped `unsettled` and reported as a pipeline defect.
- **The report is graded like an `UNSETTLED` one.** It carries the
  claim's subject with why the claim does not require it, and the
  search that came back empty, and a report missing either is
  malformed and leaves the theorem unsettled.

Each piece has one owner:

| Slot | Owner |
| --- | --- |
| The order a disprover decides its verdict in, and the shape of a `SUBJECT REMOVED` report | `agents/theorem-disprover.md` |
| Which verdicts a disprover's report can carry | `skills/theorem-agents-interface/SKILL.md` |
| When the report is well formed, the row it takes on a carried theorem and on a minted one, and the state each row stamps | `skills/agent-result-persist-interface/SKILL.md` |
| That a subject-removed retirement is listed on the skipped line and outside the full theorem list | `skills/lib/theorem-based-pr-reviewer/review-body.md` |

## One disprover per theorem is a starting point

Each theorem gets exactly one disprover on a default round. If missed
counterexamples show up in practice, N disprovers per theorem is a
one-line change in the reviewer's fan-out.

## The PR body is never a delta source

A round's inputs are the channels that carry a timestamp to cut
against: the PR's own commits since the previous head, the comments
since the previous round, and the previous round's records. The body is
frozen for an orchestrate loop and amended only by `pr-finalizer` after
it, so detecting body edits buys nothing, and a round that diffed the
body would fan out on that amendment after the loop it belongs to had
already finished. The reviewer fetches the body once, for the deferral
check and the `References:` trailers, and nothing after that reads it
again.

## The delta is patch-equivalent, and a re-applied commit stays in it

The delta between rounds is the PR's own commits whose patch changed,
compared by git's `--cherry-pick` patch-id, so a clean rebase onto the
base yields an empty delta and a conflict-resolving one leaves exactly
the commits whose patch changed. Patch-id reads context lines as part
of the patch, so a PR commit re-applied over changed context — an
upstream edit within a few lines of its own — is not patch-equivalent
to its old self and stays in the delta, though the change it makes is
unchanged. That costs a round one already-seen commit in the
generator's read; the alternative is a mechanism deciding that two
different patches mean the same thing, which patch-id deliberately does
not.

## Retirement prices a round on its delta, and `--full` is the backstop

A theorem that survived its round retires and gets no disprover on a
later default round. That is the whole saving: the disprovers that do
run are unbounded, and only the list is smaller. Between a theorem's
retirement and a `--full` run a fix can silently break the retired
claim, and `--full` — the one round that puts retired theorems back on
the live list — is the bounded-cost check for that, priced once instead
of every round. A design that re-disproved everything every round would
have no gap and no saving either.

No rule forces a `--full` round, deliberately. Whether one becomes
mandatory before a merge blessing is a policy decision to take with
measured burn data, not a default to assume, and which round precedes
that blessing is not knowable at the moment the flag would be passed,
so no rule could name it either.

The empty-delta round is the same trade from the other side. A round
with no delta and no new adjustment comments spawns nothing and carries
every verdict forward, so an issue edited between rounds with no code
change goes unchecked until the next non-empty round or a `--full` run.

## A minted theorem's fields have fixed sources

An adjustment comment reporting a missed defect mints a new theorem,
and the comment carries only the defect and a location, so every field
of the record has a fixed source and none is the reviewer's to invent.
`settle-mode` is assigned `semantic` rather than judged: nothing in a
human's prose settles whether a grep would close the claim, the field
drives only the model routing, and `semantic` spawns each child at its
declared default — costlier than the `mechanical` route and never
weaker. Reading a mode out of the comment would need the human to write
review vocabulary the orchestrator is forbidden to supply on their
behalf. That rule's one exception, the seed under `seed-review:
accept-recommended`, where choosing the value adopted the assessment's
recommendations in advance, reaches no adjustment comment. `issues`
falls back to the whole resolved set because a theorem
tagged to no member is malformed, and on a batch that tags the minted
theorem to every member, which is the safe direction: each member's
verdict then reflects it.

## Skills

| Skill | Purpose | Where it runs |
| ------- | --------- | --------------- |
| `/sdlc:orchestrate-ready <issue>` | Groom one issue until the readiness check passes, then flip its status | main session, interactive |
| `/sdlc:orchestrate <issue>…` | Plan, delegate, and coordinate the end-to-end fix for one or more issues, refusing any that fails the readiness check | main session |
| `/sdlc:git-review-pr <PR> [--generator-effort <low\|medium\|high\|xhigh>] [--full] [--mode <mode>]` | Review one PR — a thin standalone wrapper that spawns the reviewer agent | main session |
| `/sdlc:orchestrate-cleanup <PR> [--review-state] [--dry-run]` | Remove what one merged or closed PR left behind — the worktrees of the agents its state records, its local head branch and the `.claude/tmp/` scratch of the issues it closes — asking nothing, then bring the default branch up to date; the PR's review state is kept, and removed too only with `--review-state`; `--dry-run` lists what would go and removes nothing | main session |
| `/sdlc:orchestrate-cleanup --all [--review-state] [--dry-run]` | Remove everything every run left in this repo — every worktree under `.claude/worktrees/`, every local branch but the default branch, all `.claude/tmp/` scratch and every other session's scratchpad — after showing the full list and asking one go-ahead; review state is kept, and every PR's is removed too only with `--review-state`; `--dry-run` shows the list and asks nothing | main session, interactive |
| `/sdlc:orchestrate-analysis <PR>` | Report where one orchestrate run's wall-clock time went, and how the human's picks compare with the recommendations put to them per decision class — a thin wrapper that runs `bin/sdlc-orchestrate-analysis` on a PR given in any form `/github-prs:pr-view` accepts and presents its output unchanged | main session |
| `/sdlc:sdlc-config-global` | Create or merge-update the global user sdlc config, the lowest tier | main session, interactive |
| `/sdlc:sdlc-config-repo` | Create or merge-update the shared, tracked repo sdlc config | main session, interactive |
| `/sdlc:sdlc-config-user` | Create or merge-update this user's repo sdlc config, the highest tier, and keep it gitignored | main session, interactive |
| `sdlc:theorem-agents-interface` | What a theorem agent's brief parameters and the consequence classes mean, and which brief the generator and the assessor each receive | preloaded into each theorem agent |
| `sdlc:agent-result-persist-interface` | What the `sdlc-agent-result-persist` CLI does — its modes, flags, paths and record grammar, and the tables and rules its derivation modes apply | preloaded into the reviewer, `theorem-generator`, `theorem-assessor`, the disprover, the verifier, `pr-finalizer` and `pr-merge-readiness` |
| `sdlc:pr-read-cli-interface` | What the PR-read CLIs — `sdlc-pr-round`, `sdlc-pr-adjustments`, `sdlc-fixer-brief`, `sdlc-records-chain` — take, exit with and print | preloaded into the reviewer, `issue-fixer`, `docs-writer` and `pr-finalizer` |
| `sdlc:orchestrate-readiness` | The bar an issue meets before the orchestrator runs on it, the issue-body grammar, the terms for a repo statement an issue contradicts, and the check that, given the statuses its caller allows, refuses an issue that is closed, closed by an open PR, named by a local branch or at a status not allowed, and otherwise returns what the body is missing as a gap list | invoked by the grooming skill and the orchestrator; preloaded into `theorem-generator`, `theorem-assessor`, `issue-developer` and `issue-fixer` |

The rows with no leading slash are not user verbs — each declares
`user-invocable: false`, which
keeps it out of the human `/` menu while leaving it invocable.
`orchestrate-readiness` is preloaded into `theorem-generator` and
`theorem-assessor`, which read the grammar, and into `issue-developer`
and `issue-fixer`, which use its terms for a contradicted repo
statement, through each agent's `skills:` frontmatter, and
`theorem-agents-interface` into every theorem agent —
`theorem-generator`, `theorem-assessor`, `theorem-disprover`, and
`counterexample-verifier` — the same way, and `pr-read-cli-interface`
into each agent that runs one of the PR-read scripts.
`theorem-based-pr-reviewer` reads `theorem-agents-interface` by name as
well, for what the parameters of the briefs it writes mean.

The review procedure is absent from that table because it is an agent
rather than a skill, per "Find the owner of a statement before you
edit it" above. Every caller spawns that one agent to run the fan-out,
so the procedure is its body: a skill wrapping a procedure only one
agent ever runs would split one contract across two files that must
agree, and an agent body is already loaded at spawn.

`/sdlc:orchestrate-ready` is the grooming step in front of the flow,
and `/sdlc:orchestrate` does not invoke it — the user runs it first,
per issue, and runs the orchestrator once the issues are ready. Both
invoke the same check, `orchestrate-readiness`, each with its own list
of allowed statuses: the grooming skill
rewrites the body until the check returns no gap, and the orchestrator
runs the check on every issue it is given before any analysis and
stops, before a branch or a PR exists, when any returns a non-empty gap
list, naming the grooming skill rather than running it — grooming is a
conversation with the human, and the orchestrator is not one. A
refusal stops either skill where a gap list does not: the orchestrator
ends the whole run on one, and the grooming skill ends its session
rather than rewriting toward it, per "An issue already done or already
in work is refused before its body is graded" above. The bar
and the grammar are owned by `skills/orchestrate-readiness/SKILL.md`;
why grooming is interactive rather than an agent is owned by
`skills/orchestrate-ready/SKILL.md`.

`/sdlc:orchestrate-cleanup` is the pass behind the flow, and its two
forms are two scopes of one script, `bin/sdlc-orchestrate-cleanup`.
The `<PR>` form is what `/sdlc:orchestrate`'s post-merge tail runs,
once for each PR the run merged, asking nothing: the worktrees, branch
and scratch that produced a merged PR go, and a PR the run did not see
merge keeps all of them. The `--all` form is the human's, for clearing
up after many runs, and it is the one form that asks — a single
question, put over the full list a dry run printed. The skill owns
which form asks and what it shows first; what each scope removes, the
lines it prints and its exits are the script's.

Neither form removes review state unless `--review-state` is passed,
and then the `<PR>` form deletes that PR's and the `--all` form every
PR's in the repository. Both forms once deleted it unconditionally, on
the reasoning that a merged PR's evidence is no longer needed to
diagnose a round. That reasoning missed the other reader: review state
is what `/sdlc:orchestrate-analysis` builds a run's time report from,
and a merged PR's run is as much that report's subject as any other,
so every merge and every `--all` sweep destroyed the evidence the
report needed. The post-merge tail never passes the flag, so a merged
PR's review state survives the run, and deleting it is a decision only
the human makes. Without the flag the script neither lists nor deletes
review state and prints no line for it, a dry run included.

The script replaces two step lists the model re-derived on every run,
which graded each item against a gate and asked the human to pick from
the result — a question the run could answer itself, since every item
either belongs to the PR or does not. The decisions that replaced the
grading:

- **A PR's worktrees are found by agent id, not by branch or HEAD.**
  A teammate releases its branch claim at end of run, so the worktree
  it leaves is detached, and the reviewer's children check out
  detached from the start; a sweep that matched worktrees by the PR's
  branch or its commits missed most of them. So every spawn made for a
  PR is recorded in the PR's state — the orchestrator,
  `pr-merge-readiness` and the reviewer record each one through
  `sdlc-agent-result-persist --mode agent`, and a review child also
  records itself at `enter`, so a child the reviewer writes off before
  its `enter` is still named — and the `<PR>` scope removes exactly the
  `.claude/worktrees/agent-<id>` worktree and the `worktree-agent-<id>`
  branch of each id the state names, nested worktrees included, plus
  any worktree under `.claude/worktrees/` still holding a branch it
  deletes. It reads those ids with or without `--review-state`, and
  before the flag deletes the state that names them. A spawn nobody
  recorded is left behind, and `--all` is the backstop that takes it.
- **Removal is forced.** The `<PR>` scope runs only for a merged or
  closed PR, so a worktree's uncommitted edit, unpushed commit or lock
  is leftover from a run that has ended, not work in flight; the
  `--all` scope is the human's deliberate reset. Checking for dirty or
  unpushed state was what the old sweep spent its gates on, and every
  such gate ended in a question.
- **Nothing on `origin` is ever deleted or pushed to**, in either
  scope; a remote branch is the human's.
- **The default branch is never removed**, and the script refuses to
  run at all when `git-default-branch` cannot name it — a sweep that
  does not know which branch is protected cannot safely delete any.
- **A PR in another repository is refused**, with exit 5 and nothing
  removed: every worktree, branch and scratch entry the script matches
  against the PR is this checkout's, so a PR from elsewhere would match
  nothing or, worse, something.
- **The primary clone is moved off the branches it deletes first.**
  A run that removes switches the primary clone to the default branch
  before it deletes any branch, or detaches it when another worktree
  holds the default branch, so the branch the clone happened to have
  checked out goes with the rest rather than failing. A branch a
  worktree outside `.claude/worktrees/` still holds is kept and
  reported, not failed: that worktree is nobody's leftover.
- **Every run ends with the default branch current**: worktree prune,
  fetch with prune, and a fast-forward in whichever worktree holds the
  default branch. The orchestrator's post-merge tail used to do that
  itself, after the sweep; now the script does it, and the tail only
  relays.

`test/sdlc-orchestrate-cleanup-test.sh` drives the script against a
primary clone holding dirty, unpushed, locked, detached and nested
worktrees, unrelated branches, scratch and session scratchpads, with
stub `git-default-branch`, `gh`, `pr-view`, `pr-closing-issues` and
`sdlc-agent-result-persist` executables and a logging `git` wrapper in
front of the real one, so it can assert that no run pushed and that
`origin`'s refs are unchanged.

## Executables

The plugin ships these, each callable by bare name once the plugin is
enabled. A PR that adds or removes an executable edits this roster.

| Executable | Purpose | Contract |
| ------- | --------- | --------------- |
| `bin/sdlc-agent-result-persist` | Writes and reads the review pipeline's state under XDG state, and derives from it the arm a round is in, each theorem's disposition and severity, the verdicts and the posted review body, and reports how far a PR's latest round has got; the one place that composes those paths | `skills/agent-result-persist-interface/SKILL.md` |
| `bin/sdlc-orchestrate-analysis` | Prints the Markdown time report behind `/sdlc:orchestrate-analysis`, reading review state only through `sdlc-agent-result-persist`, the orchestrator session's transcript, and the PR's GitHub timeline, and the per-class Decisions table, reading the decision records of the PR, of each issue it closes and of each issue its head branch names only through `sdlc-decision print`; writes nothing | its own header comment |
| `bin/sdlc-decision` | `ask` checks a decision record, stores it and prints the question, or a `resolved by` line for a problem a `--ruling` resolves; `answer` stores the human's pick per problem and the reply verbatim, and takes a record again while a problem of it is open; `question` prints one record's question again; `print` lists the records of one PR or one issue; `pending` exits 4 while a design gap of one PR or one issue waits on the human's answer; `ask`, and `question` on a record with no stored question, need mikefarah `yq` v4 or later; `ask` runs no `command:` evidence | its own header comment |
| `bin/sdlc-pr-round` | Prints the number of the review round under way, from the PR's pipeline reviews and its rounds' state: the round after the newest posted pipeline review, or a round above that one already begun | `skills/pr-read-cli-interface/SKILL.md` |
| `bin/sdlc-pr-adjustments` | Prints the comments posted since the previous round, less sdlc's own marker comments, cutting at the newest pipeline review, else at the newest instant in the previous round's log — never round 0's, so round 1 cuts at the PR's creation — else at the PR's creation | `skills/pr-read-cli-interface/SKILL.md` |
| `bin/sdlc-fixer-brief` | Prints the most recent comment when it is a fixer brief and exits 3 naming its first line when it is not; with `--all`, every brief the PR carries | `skills/pr-read-cli-interface/SKILL.md` |
| `bin/sdlc-records-chain` | Reports each complete chain of review-detail chunks posted on a PR, with the range of rounds the chain holds and its total, and which chunks are there when no chain is complete | `skills/pr-read-cli-interface/SKILL.md` |
| `bin/sdlc-pr-post-theorem-records` | Assembles a PR's review detail out of its state, chunks it under GitHub's comment cap, splitting a piece too large for one chunk across several, and posts it as one chain whose markers name the rounds it holds; a PR whose complete chains are missing later rounds gets a supplementary chain holding only those rounds, and one whose chains cover the latest round gets nothing posted | its own header comment |
| `bin/sdlc-readiness-check` | Takes an issue and one or more `--allow-status` names, and refuses the issue, exiting 4 with one line per refusal and the body ungraded, when it is closed, an open PR closes it, a local branch names it, or its status is none of those names; otherwise grades the `### Mechanical` bullets of the issue's acceptance sections against the tree, reading the issue through `issue-view`, and prints one gap line per failing bullet, per line under `### Mechanical` that is no bullet, per acceptance section with no bullet, one for a body with neither section, and a `mechanical:`-labelled one for an `## Acceptance` section and for a files-affected list under another level-2 heading; exits 3 on any gap and 0 on none | `skills/orchestrate-readiness/SKILL.md` for the keys, its own header comment for the rest |
| `bin/sdlc-pr-monitor` | Polls one ready PR in one background run, waiting the interval between polls, until it merges, closes unmerged, falls `BEHIND` or `DIRTY`, or sits unchanged for the bound's number of polls; prints one line per poll and ends on a terminal line, however long that takes; reads, and writes nothing | its own header comment |
| `bin/sdlc-orchestrate-cleanup` | Removes what runs left in the primary clone — worktrees, local branches, `.claude/tmp/` scratch and, for the whole repo, other sessions' scratchpads — for one merged or closed PR with `--pr`, or for the whole repo with `--all`, then brings the default branch up to date; keeps review state, and deletes it through `sdlc-agent-result-persist` only with `--review-state`; `--dry-run` prints the same items and acts on nothing; asks nothing, and never touches a branch on `origin` or the default branch | its own header comment |
| `bin/sdlc-pr-body` | `split` cuts a PR body file into the base above the finalizer's section and the tail below it, dropping the section; `join` writes a base, a section and a tail into one body file; reads and writes only the files it is given | its own header comment |
| `bin/sdlc-extract-lines` | Copies a line range of one file, verbatim, into another, refusing a range the source does not reach with nothing written; reads and writes only the files it is given | its own header comment |

`sdlc-readiness-check` is a script because the grading it replaces was
an injection path: a `### Mechanical` bullet used to name the command
that settled it, so the model ran text from an issue body — text anyone
with write access to the tracker can author — outside the permission
gate and auto mode's classifier. The script never runs a bullet's text.
It builds each check from the bullet's key, and `[no-match]` is the one
key it executes at all, through `grep` alone; every other key is settled
by whether the files-affected section lists the path, so the check never
runs a test, a linter or any code in the repo, and a bullet it cannot
place — no key, an unknown key, a path it cannot resolve to one file
inside the repo root — is a gap with nothing run, as is a line under
`### Mechanical` that is no bullet, a fence opening included: whatever
such a line carries is never read as grammar, so a command hidden in
one is a gap rather than a run. The same pass settles the shape of
the body — a section with no bullet, a body carrying neither
acceptance section, a forbidden `## Acceptance` section, or a
files-affected list under a heading other than
`## Files affected (floor)` — so the model's grading starts from a body
the script has already found well-formed. A mistitled list is detected
narrowly, and only in a body with no `## Files affected (floor)`: by a
level-2 heading naming files affected, over a section holding a list item
that opens with a backticked path or ends in a files-affected tag,
because the gap's repair is a retitle made without a question: a prose
section that merely mentions affected files must not be retitled into
the grammar. The script then reads that section's well-formed bullets
as the list, so one mistitled heading does not also fail every
`### Mechanical` bullet the list covers. The deterministic
grading around the old command — which reported site a files-affected
tag covers — moved into the script with it, so an unchanged body and an
unchanged tree get the same verdict on every invocation.
`bin/test/sdlc-readiness-check-test.sh` drives it against a scratch
repository and a stub `issue-view`, with `git-tools`' real
`git-issue-branch` decoding the scratch repository's branches; a bullet
it feeds that would write if run leaves a marker file, and each case
carrying one checks that none appeared. A stub `gh` leaves a marker
too, which is how a case shows that a refusal wrote nothing to the
tracker.

`sdlc-pr-monitor` is a script because the loop has to outlive any one
of the agent's turns without the agent carrying it. The agent starts
it once, in the background, and one run polls to a terminal line,
however long that takes. An earlier version ran in the foreground and
stopped short of the Bash tool's time limit, leaving the agent to call
it again with the unchanged-poll count and the last state; the agent
did not reliably make that call, and handed back with no outcome while
the PR went unwatched. With the count and the previous poll's state in
one process there is nothing to pass on, no per-call wall-time budget,
and so no ceiling on the interval: `merge-poll-interval-seconds` is any
positive integer, and every wait still sleeps in calls of at most 60
seconds. The state is compared as the text the `Polled` line prints.
`test/sdlc-pr-monitor-test.sh` drives it against stub `pr-view` and
`pr-ready-to-merge` executables serving a scripted poll sequence, and
a stub `sleep` that advances a fake clock, so a run of many intervals
finishes without waiting.

`sdlc-pr-body` and `sdlc-extract-lines` are scripts because the
permission gate's file-work redirect, on by default in every linked
worktree an agent runs in, denies the Bash spellings they replace: a
`cat` of several files redirected into one, which assembled the
finalizer's body, and a `sed -n '<start>,<end>p'` redirected into a
file, which lifted a function body out of a script for a test harness,
are each a covered read whose output no command consumes. Neither has a
file-tool equivalent — Write cannot take its text from other files —
so each shape became a program that reads and writes the files it is
named, under a contract its header states. `test/sdlc-pr-body-test.sh`
drives the body script against bodies of its own: a body with no
section, with a section and a tail, with an opening marker and no
closing one, with CRLF line endings, the base's trailing blank lines
dropped and its inner ones kept, a split and join re-run reproducing
the body byte for byte, the usage errors and a missing input.
`test/sdlc-extract-lines-test.sh` drives the extractor against a source
of its own: a range, a single line, the whole file, a destination
replaced, a last line with no newline, a range past the end refused
with nothing written, the usage errors and a missing source. Each
needs only bash, `mktemp` and the POSIX utilities, and reaches no
network.

The PR-read scripts and the detail poster share one sourced helper,
`bin/lib/sdlc-pr-common.sh`, which is not itself callable: it parses the
canonical PR reference they take, makes the one `gh pr view` read the
PR-read scripts share, and defines the fixer brief's first-line marker
as a literal, and the review-detail chunk's marker and the review-round
stamp each as both a regex that matches it and a function that prints
it.
It also holds the one test of whether a review is a pipeline review,
so the round number and the adjustments cut cannot disagree about
which reviews count. The helper also holds the state root's repository
layout — which directory is a repository's, the `repo.yml` that
identifies it, and the move of state written before the host was part
of the path — so `sdlc-agent-result-persist` and `sdlc-decision`, which
both write under that root, cannot lay it out differently. A move that
cannot remove a directory it emptied reports that and leaves the
directory in place, without failing the move.
`sdlc-agent-result-persist` sources the helper for the stamp and the
layout alone, keeping its own failure exits, and
finds it beside the path it was run by, so it runs from `bin/` or
through a wrapper that execs it there, never through a symlink placed
in another directory. `sdlc-decision` finds it the same way.
The PR-read scripts
read and cut and decide nothing: whether an adjustment is a rejection,
an override, a scope drop or a missed defect, and what a brief asks,
stay the reading agent's judgment. They exist as scripts because each
read is fixed — a `--jq` expression, a timestamp comparison, a
first-line match — and a model assembling one from prose assembled it
slightly differently each time, with no owner for its shape or its
failure wording. `sdlc-pr-adjustments` reaches the previous round's log
only through `sdlc-agent-result-persist --mode print`, the same rule
the time report follows, so where that state lives stays one
executable's concern.

A round's number comes from the PR's pipeline reviews and its rounds'
state, never from its review count. GitHub lists every review alike, so
counting them let a code-scanning review ahead of the first round
number that round 2, and a human review between two rounds leave a
number unused; the newest review of any kind likewise set the
adjustments cut, past comments no round had read. The stamp settles
which round a review posted without any local state, which is what
lets a machine holding none of
the PR's state still number the next round. A review posted before the
stamp existed is told by its `## Verdicts` and `## Review method`
headings instead, and its round by the review files the state holds;
where the state holds fewer of those than the PR has pipeline reviews,
the count of pipeline reviews is all there is to number from. Numbers
a PR already skipped stay skipped, so nothing that visits a PR's
rounds counts up from 1: the detail poster and `pr-finalizer` visit the
rounds
`sdlc-agent-result-persist --mode rounds` lists, where stopping at the
first number with no log used to drop every round above it.

Every executable under `bin/` turns a failure in a command it did not
handle into its own failure status with a line naming the command,
never the tool's own status — the PR-read scripts, the detail poster,
the readiness check, the PR monitor, the cleanup, the body script, the
line extractor and the decision script exit 1, the persist script and
the time report route
it through their existing exit 2 — so
a caller branching on an exit sees only the statuses each contract
documents.

The time report and the detail poster compose no state path of their
own: each reaches round logs, result files and transcripts only through
the paths `sdlc-agent-result-persist`'s read modes print, so a change
to where that state lives is a change to one executable. The time
report reaches decision records the same way, only through
`sdlc-decision print`. The detail
poster posts through github-prs' `pr-comment` executable, called by
name off `PATH`, so each chunk is re-read after it lands without the
poster spelling a `gh` call of its own. A source the time report cannot
reach is named in the report as missing, and no row that source would
have backed is printed — the report never reads a substitute, so a
missing row is evidence that a source is gone, not a guess about what
it held.

## Hooks

`hooks/hooks.json` names the one module `hooks/register.ts`, which
registers each file in the table. The engine refuses a `hooks.json`
whose `modules` holds more than one path, so a hook file is added by
exporting a `register` that `register.ts` calls, never by a second
path. A PR that adds or removes a hook edits this roster.

| Module | Event | Purpose |
| ------- | --------- | --------------- |
| `hooks/orchestrate-status.ts` | `session.start` | Registers the `/orchestrate-status` command, as immediate so that it runs while a turn is in flight |
| `hooks/orchestrate-status.ts` | `command.run` on `orchestrate-status` | Answers the command itself, with no model turn: turns the status line off or on and names the state it left, or prints the usage line |
| `hooks/orchestrate-status.ts` | `skill.prompt` | Starts a run in `readiness` at the `orchestrate` skill's prompt, and puts a run in `cleanup` at the `orchestrate-cleanup` skill's |
| `hooks/orchestrate-status.ts` | `tool.call` on `Read` | Puts a run in `plan` when the main loop reads the orchestrator's plan lib file |
| `hooks/orchestrate-status.ts` | `tool.call` on `Skill` | Records the issue a main-loop `sdlc:orchestrate-readiness` call names, as one of the run's issues the line leads with |
| `hooks/orchestrate-status.ts` | `agent.spawn` | Sets the phase a main-loop spawn's agent stands for, the PR its brief names and the issues a reviewer brief's `--issues` names, and starts a run at a spawn of any `sdlc:` agent but the reviewer on a PR |
| `hooks/orchestrate-status.ts` | `turn.complete` | Redraws the line during a run, and ends the run and clears the line when the main loop's turn ends in `cleanup` |
| `hooks/orchestrate-status.ts` | `session.end` | Clears the line and stops its timer |
| `hooks/reload-after-compact.ts` | `session.compact` | Lets the compaction run, removes every earlier reload message from the compacted conversation, and appends one fresh message holding the full text of the skills and rule files the compacted loop used, within the `reload-after-compact-token-budget` budget |
| `hooks/reload-after-compact.ts` | `ui.render` on `UserMessage` | Draws the reload message's row as one summary line, and leaves every other user message's row as it would be drawn without the hook |

Each module's test, `test/orchestrate-status.test.ts` and
`test/reload-after-compact.test.ts`, runs under `claude plugin test`.

## Files it writes

Everything the **review pipeline** persists is written by
`bin/sdlc-agent-result-persist` under XDG state, outside every
repository — a review round writes nothing to the branch it reviews. A
PR that adds or removes one of these edits this list, the same
convention "Executables" above sets. Which mode writes each, and the
record grammar the log holds, are part of that contract and are owned
by `skills/agent-result-persist-interface/SKILL.md`. The decision
records sit under the same repository directory and are written by
another script, `bin/sdlc-decision`: each record it asks, and the
reply to it.

The script never takes a payload — a child's report, a round's records
or review, the edits and new records a carried round is built from —
on its command line. The writer stages it with the `Write` tool in the
session scratchpad and names that file by path, with `--from` or, for
the carry form's edits, `--edits`; the
staging file is the pipeline's one write outside XDG state, it lies
outside every repository as well, and it dies with the session. The
derivation modes read the same staged files: `next` and `dispose` take
the round's edits and new records through `--edits` and `--from`, before
any state is stamped, so the live list they derive comes from the files
the reviewer later stores the round through, and from nothing it holds
in memory. That
staging is why the theorem children carry the file-writing tools while
the review pipeline stays non-mutating. Why a file rather than a heredoc, and how
the staging path is named, are owned by
`skills/agent-result-persist-interface/SKILL.md`.

`pr-finalizer` reads that state and writes none of it. The orchestrator
writes round 0's `records` — the seed settled before the developer ran,
transcribed through the same script — and the generate-stage `spawn`
record carrying the seed generator's tier into round 0's `log`, with
the `seed-review` record beside it under `seed-review:
accept-recommended`, and, like `pr-merge-readiness`, appends to the
PR's agents log for each agent it spawns — and for the generator and
the assessor the seed reviewer spawned, which that reviewer, having no
PR to key a write on, could not record itself; neither writes anything
else here. The `sdlc-config-*` verbs write the config files their contract
names, on the user's yes, and those are the user's files rather than
run state. The implementing agents are outside the claim entirely and
write nothing this list owns: those declaring `memory: project`
capture their agent memory with
`/cc-tools:agent-memory-inbox-capture`, each of them but
`style-checker` commits its work to the branch, and
`agent-memory-scrubber` commits what `/cc-tools:agent-memory-inbox-cleanup`
transfers.

Write `<repo-dir>` for
`${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/<host>/<owner>/<repo>`, the
PR's repository's directory, and `<round-dir>` for
`<repo-dir>/pr<pr>/round<round>`, the round's own directory:

| File | What it holds |
| ------- | --------------- |
| `<repo-dir>/repo.yml` | the host, owner and name of the repository whose state the directory holds, written when the directory is created, by whichever of `sdlc-agent-result-persist` and `sdlc-decision ask` runs first for the repository |
| `<round-dir>/log` | the round log, whose `anchor` line names the round's type beside the head it was generated against; round 0's holds the seed generator's `spawn` record, a `seed-review` record when the config applied the seed assessment, and no anchor |
| `<round-dir>/<theorem>-<agent>` | one child's full report |
| `<round-dir>/records` | the round's theorem records, which the next round of its type carries forward — built by the script from the round of that type below plus the reviewer's edits and new records; round 0's is the ruled seed, stored whole |
| `<round-dir>/review` | the round's argued review, from which `--mode summary` renders the posted review; the detail chain `pr-finalizer` posts at a close-out carries it whole, split across chunks when it is too large for one |
| `<round-dir>.voided-<instant>/` | the whole directory of a round whose branch moved under it, set aside rather than overwritten |
| `<repo-dir>/pr<pr>/agents` | the PR's agents log: one record per agent spawned for the PR, naming the definition and the agent id, beside the rounds because a spawn belongs to no round and a voided round's rename must not carry it away |
| `<repo-dir>/pr<pr>/decisions/<n>/` | one decision record put to the human about the PR, numbered in the order asked: `record.yml`, the record as the skill wrote it; `question`, the question as `ask` printed it; `log`, when it was asked, each problem's class and recommendation, which problems a ruling resolved, and each answer's pick per problem; and `reply`, the human's replies verbatim, oldest first, once answered |
| `<repo-dir>/issue<N>/decisions/<n>/` | the same, for a decision asked where no PR exists: a grooming session's, keyed on the issue it grooms, and one a run asks before a batch's PR is open, keyed on the batch's first member |

Neither the records file nor the review file is capped, quoted or
truncated: the 64 KB ceiling that once bounded what a round could
persist was a property of a PR comment, and none of these files is one.

The PR number keys the path because a PR is worked by one orchestrate
run, and the agent tree under it, at a time. Nothing in the path names
a session, so any reviewer spawned over that PR reads the round an
earlier instance left behind — the same run's re-spawn after an
in-progress return, and equally a spawn from a later session, such as
`/sdlc:git-review-pr <PR>`. Finding it is the reviewer's own job, per
`agents/theorem-based-pr-reviewer.md` → "Read the round log, then
anchor the round", which it runs on every spawn; no caller looks for
the log on its behalf.

The host keys the path above the owner because one machine holds state
for repositories on several GitHub hosts, and the same `owner/repo` on
two of them is two repositories. Every caller hands the script the PR
as one canonical reference, `--pr <host>/<owner>/<repo>#<N>` — the form
`/github-prs:pr-view <PR> --ref` prints — and a bare number or a
reference without a host is refused. The orchestrator resolves that
reference once, when the PR is created, and every brief it writes
carries it; the standalone reviewer resolves whatever form it was given
at the top of each round. No caller resolves the repository itself, so
no agent runs `gh repo view` only to hand the script what the reference
already says, and a PR of a repository the checkout's remote does not
name is addressed the same way as the checkout's own. The directory's
`repo.yml` is what identifies it, not its path: a reader that derived
the repository from segment position would misread the directory the
next time a segment was added, and where the file and the path disagree
the file wins. State written before the host was part of the path, at
`sdlc/<owner>/<repo>/`, is moved lazily — the first run of the script
for that repository moves it into place, host from `--pr` or from the
repository `--mode list` is given, and writes its `repo.yml`, so no
host is guessed and no network call is made. `sdlc-decision ask` makes
the same move before it stores a record, host from its `--pr` or
`--issue` reference, so a decision asked ahead of any review round
does not leave a repository's state split across both paths.
`--mode list` takes its
repository as an optional operand — `<host>/<owner>/<repo>`, its URL,
or a shorter form filled in from the current repository, which is also
what an omitted operand means — and prints each PR as the reference
`--pr` takes, so a caller hands each line on to `--mode delete` without
composing one. The script's `--mode repos` lists every repository
directory under the state root as its `repo.yml` names it, and a
directory of the old layout, which has none, as such. The identifying
flag, the `list` operand, `repo.yml`, the move and the modes are owned
by `skills/agent-result-persist-interface/SKILL.md`.

The `enter` record also carries a path outside that directory,
`~/.claude/projects/<project>/<session>/subagents/agent-<agent-id>.jsonl`
— the harness's own transcript of that child. The script **composes**
that path and writes nothing there; recording it is what lets a
post-mortem reach a child's transcript after its worktree is gone. The
agent id in that record, and in each `agent` record of the agents log,
is also the name of the child's worktree under `.claude/worktrees/`,
which is how `--mode print-agents` — every id the PR's state names,
across the agents log and every round log, voided rounds included —
tells the cleanup which worktrees were the PR's.

**Nothing removes any of it during a run, and that is deliberate.**
No mode that runs during a review deletes, and nothing expires: a
round log outlives the worktrees of every child it names, and the
voided copies outlive the round they describe. That accumulation is
the debugging trail — a stalled or voided round is diagnosed from
these files and from nothing else, since the reviewer holds no state
across a turn, and a finished run's time report is reconstructed from
them after every worktree that produced them is gone. The one `sdlc`
surface that deletes state is the script's `--mode delete`, which
removes a whole `pr<N>/`, and the only call of it that deletes is
`sdlc-orchestrate-cleanup --review-state`'s, which only the human
runs: the cleanup `/sdlc:orchestrate` runs for a merged PR passes no
such flag, and review state is kept unless it is passed. So a `pr<N>/`
outlives every round of its PR and the PR's merge, and goes only when
the human decides its evidence is no longer wanted. The PR's decision
records sit inside that directory and go with it. An `issue<N>/`
directory is removed by no `sdlc` surface.

The `reload-after-compact` hook's state is outside the review
pipeline's and is not written through that script. It lives under the
same root, at
`${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/reload-after-compact/<session>/<loop>.json`,
with `<loop>` reading `main` for the main conversation and
`agent-<agent-id>` for a subagent's own loop: one JSON file per loop,
holding the loop's uses oldest first and where its orchestrate run
stands. The hook rewrites it on every compaction of that loop. No
`sdlc` surface removes these files, `sdlc-orchestrate-cleanup`
included.

## Agents

Every agent but `pr-merge-readiness` and `pr-monitor` declares
`isolation: worktree`, so the harness creates a throwaway worktree per
spawn. Those two declare no `isolation` and run in the orchestrator's
primary clone, writing nothing to it but the refs a
`git-branch-sync reclaim` by `pr-merge-readiness` fetches or deletes
there: each is a loop over a gate, and
every change to the branch a loop drives is a commit by a teammate it
spawns or that the orchestrator spawns after it. Nothing removes a
worktree during a run: the reviewer leaves its children's worktrees
where the harness made them, and `sdlc-orchestrate-cleanup` removes
them once the PR has merged, finding each by the agent id the PR's
state names. That is why every spawn made for a PR is recorded there:
the orchestrator, `pr-merge-readiness` and the reviewer record each
agent they spawn through `sdlc-agent-result-persist --mode agent`, and
a review child also records itself when it enters a round, so one
written off before it enters is still named. The seed reviewer, the
generator and the assessor it spawns, and the batch's developer are
spawned before the PR has a reference, so the orchestrator holds their
ids — the two children's as the seed reviewer reported them — and
records each once the PR is linked.

| Agent | Purpose |
| ------- | --------- |
| `issue-developer` | Implements one batch of issues on one branch, stopping once it has pushed the manifest changes when briefed with an approved resolving install, and continuing on an existing branch when briefed with one |
| `issue-fixer` | Applies review findings, or a merge-readiness remedy — a rebase onto the base, resolving each conflict a ruling or its own resolvability conditions settle and escalating the rest — to an open PR's branch |
| `code-documenter` | Adds or corrects the comments in a round's code files, and corrects or deletes those its instruction-Markdown files carry where the diff contradicts them, each file against its own class's style guide, before its review |
| `style-checker` | Reports a round's style-guide violations in the files of the side of the class split its `--mode` names — code and instruction Markdown in the code loop, documentation in the documentation loop — each file graded against its own class's guide, which the orchestrator sends to the loop's fixer before its review |
| `docs-writer` | Writes a PR's documentation in the documentation loop that follows its code loop, fixes what that loop's rounds find in it, and for a batch with no code to implement creates the branch and opens the PR |
| `agent-memory-scrubber` | Curates the run's agent-memory inbox onto the PR |
| `pr-merge-readiness` | Drives one blessed PR through the merge-readiness gate, spawning `issue-fixer` then `agent-memory-scrubber` for each remedy, recording each spawn in the PR's state, reclaims the branch from a dead agent's worktree when a spawn's checkout finds it held and re-spawns that agent once, and returns a state that needs a ruling as a question and a remedy that left documentation to write or a documentation conflict resolved as `documentation loop needed` |
| `pr-finalizer` | Posts the run's assembled review detail to a finished PR and writes the run's final section into its body, one sub-section per round type, replacing the one an earlier run left, lists there each claim in the body above it that the branch or the round records contradict, and corrects the closing lines its brief names |
| `pr-monitor` | Runs `sdlc-pr-monitor` on one ready PR until it merges, closes unmerged, falls `BEHIND` or `DIRTY`, or sits unchanged long enough to ask whether to keep waiting; hands back the script's error verbatim when it fails instead, or the exit code and last line of a run that ended with no terminal or error line, which the orchestrator reports as needing the human's attention |
| `theorem-based-pr-reviewer` | Reviews one PR, spawning the generator, the assessor, the disprovers, and the verifiers from inside itself, and before a batch's PR exists seeds its theorem set from the issues, spawning the generator and the assessor and posting nothing |
| `theorem-generator` | Searches one PR — or, before one exists, the issues a batch will close — for claims worth trying to disprove, at the reasoning tier its spawner names |
| `theorem-assessor` | Assesses one generated theorem list against the issues it was drawn from — the seed's, or a review round's — recommending an action per theorem and a theorem for each criterion none tests |
| `theorem-disprover` | Tries to break exactly one theorem |
| `counterexample-verifier` | Tries to reject exactly one disprover's counterexample |

### What an agent's `tools:` line declares

The agents are directed to read and change files with the `Read`,
`Edit` and `Write` tools rather than through Bash, and an agent can
follow that only when its `tools:` frontmatter names those tools: a
tool the line omits is not available, whatever the body says. So every
agent that writes any file — a commit on the branch, a memory entry, a
staging file in the session scratchpad, scratch under `.claude/tmp/` —
declares all three, and an agent whose contract says it edits no
tracked file holds that contract in its body, not by leaving a tool out.
`theorem-assessor` is the exception: it writes one file, the staged
payload of its assessment, and changes none, so its line names `Read`
and `Write` and no `Edit`.
`pr-monitor` is the one agent that writes nothing; its line is
`Read, Bash, Monitor, TaskStop`. It runs `sdlc-pr-monitor` once, in
the background, and waits for that task to exit with `Monitor`, one
watch at a time. Each watch follows the task's output and ends on its
terminal or error line, or when the script's process is gone; a watch
that only paces time is forbidden, because such timers piled up
unstopped. A turn the agent ends while the script runs is not a
report: it carries no outcome, and the task's exit or a watch's event
resumes the agent on the same task. The orchestrator waits on such a
turn for the agent's next hand-back rather than re-spawning, so one
PR never has two monitors. Before it reports, on every outcome, it
stops with `TaskStop` every task and watch it recorded, one that would
expire on its own included, and confirms each has ended, because a
task that outlives the report keeps watching a PR the run has moved
past while the agent itself reads as completed, so nothing tells the
orchestrator the task is still running.

Two entries a reader might expect are absent or inert, each on purpose.
`Skill` is never listed, and an explicit `tools:` line that omits it
removes the Skill tool from the agent. That removal is the intent: a
skill named in `skills:` has its full content injected when the agent
starts, so the agent works from its preloaded skills without the tool,
and lacking the tool keeps it on task, since it cannot discover and
invoke a skill its definition did not preload. The constraint this puts
on the skills is that one carrying `disable-model-invocation: true`
cannot be preloaded, so an agent here never lists one in `skills:`.
`Glob` and `Grep` are listed but grant nothing while `Bash` is also
listed, which every agent here needs; they stay because they are
harmless and take effect the moment a harness restores them.

### The generator's tier is passed per spawn

`agents/theorem-generator.md` is one definition carrying the whole
generation procedure, and its reasoning tier is the `effort` of the
`Agent` call that spawns it. That call is always the reviewer's, the
seed's included, and the tier is picked by the reviewer's rubric —
read against the round's delta, or on the seed brief against the issue
bodies — or by the `--generator-effort` override. The orchestrator
picks no tier. Every generator spawn names its tier, `low` included, because
the `Agent` call's `effort` overrides the frontmatter `effort: low`,
which decides only a spawn that names none. No other agent's spawn
passes an `effort`.

The override is the human's to volunteer: the orchestrator never asks
for a tier, and one the human names unprompted, at the plan or later,
holds for the whole batch — passed as `--generator-effort` on the
reviewer's seed spawn when the seed has not yet spawned, and on every
reviewer spawn for the batch's PR.

The generator cannot be relied on to know the tier it runs at, so it
records none: the tier is written as the `effort` of the
generate-stage `spawn` record — `--agent theorem-generator --model
default --effort <tier>` — in the round's log. The reviewer writes it
on a review round. On the seed it has no PR to key a log on, so it
reports the tier and the orchestrator writes it to round 0's log once
the PR is linked.
That record is where the tier lives afterwards: the reviewer's Review
method section reads the tier that ran from it, the time report's
"Generator tiers" section lists every round's from it, and the generate
stage's result file is `list-theorem-generator` whatever the tier, so
its name carries none. The spawner's own memory of the call is no
source either: a resumed reviewer reads a `spawn` an earlier instance
made.

`theorem-assessor` takes no tier either: its spawn names no `model`
and no `effort`, at the seed and on a review round alike, so it runs at
its frontmatter's whatever tier the generator beside it ran at.

`theorem-disprover` and `counterexample-verifier` take no tier; each is
one definition with a `model` the reviewer routes per spawn by the
theorem's settle mode — a cheaper model for a `mechanical` theorem,
whose grep-shaped claim a cheap model settles as well as any other, and
none for a `semantic` one. A frontmatter `model:` is only the default
for an unrouted spawn, not a floor or a ceiling — the `Agent` tool's
`model` parameter may name a lower, higher or equal model for a single
spawn — and no file outside that frontmatter spells the value, which is
what keeps a model change a one-file edit. If a harness ever refuses to
route below the declared default, the mechanical spawn runs at that
default: costlier, never wrong.

## Dependencies

`plugin.json` declares `dependencies` on `issues`, `git-tools`,
`github-prs`, and `cc-tools`. Those edges are what guarantee the
cross-plugin skills this plugin invokes are installed and enabled
wherever it runs — the issue verbs, `git-branch-create`,
`git-issues-from-branch`, `git-range`, `git-branch-sync`, the PR verbs,
`agent-memory-inbox-capture`, and `agent-memory-inbox-cleanup` — and
that the executables the scripts here call off `PATH` are there to
call: `pr-comment` for the detail poster, `git-default-branch`,
`pr-view` and `pr-closing-issues` for the cleanup, and `pr-view` and
`git-issue-branch` for the time report's Decisions table, and
`issue-view` and `git-issue-branch` for the readiness check, which
exits 1 naming whichever is missing. The readiness check's
open-closing-PR refusal reads the `closed-by:` row `issue-view` prints
from `issues` 0.19.0. An older `issue-view` prints no such row, and the
check then exits 1 with a message naming the `issue-view` it needs,
whatever else is true of the issue: reading the missing row as no
closing PR would let an issue with an open one pass. The
unassigned follow-up issue relies on `/issue-create --no-assignee`,
which `issues` has from 0.15.0. `yq`, which `sdlc-decision ask` parses
a record with, and `question` too for a record with no stored question,
comes with no plugin: it is the mikefarah build, v4 or later, installed
on the machine, and either mode exits 1 without it. The
edge coordinates install and enablement, not file access: plugins are
file-sandboxed, so nothing here reads another plugin's files.

Every PR read or write an agent, a skill or a lib file in this plugin
makes goes through the `github-prs` verb that has one; none of those
files spells a `gh pr` or `gh api …pulls…` call of its own. That is a
policy this plugin chose, not a harness limit: a raw call works, but
then the call's shape and its failure wording have an owner per call
site, and a permission gate could never refuse raw `gh pr` use without
breaking one. The `github-prs` edge is what makes the policy safe to
hold. The executables under `bin/` are outside it: a script is already
the single owner of the call it makes.

The `github-prs` edge is also why the cleanup lives here rather than
in `git-tools`: its per-PR scope reads the PR's state and head branch
through `pr-view` and the issues it closes through
`pr-closing-issues`, `github-prs` already depends on `git-tools`, and
an edge back would be a cycle. What the cleanup needs from git alone —
the one branch no scope removes — it takes from `git-tools`'
`git-default-branch`, which the `git-tools` edge puts on `PATH`; the
script refuses to run when that call names no branch.
