# sdlc

End-to-end issue orchestration: groom an issue until it can be
implemented without stopping to ask, plan and delegate the
implementation of one or more issues across parallel teammate agents,
review the resulting PRs through a theorem-based pipeline, hand the
human a set of PRs to bless, watch each blessed PR until it merges,
and remove what each merged PR left behind — its review state, the
worktrees its agents ran in, its local branch and its scratch — or,
when the human asks, everything every run left in the repo.

## Find the owner of a statement before you edit it

This plugin's hazard is duplication. Its behavior is described across
an agent file, a skill body, the lib files beside that body and this
README, and nothing tests prose, so a change made in one place leaves
the others asserting the opposite. Every fact has exactly one owner:
edit the owner, repair pointers elsewhere, and never let a second file
restate the fact.

| Fact | Owner |
| --- | --- |
| Which skills, agents and executables the plugin ships, and its `dependencies` edges | this file |
| What one agent does | that agent's own file under `agents/` |
| What a review checks and how it is reported | `agents/theorem-based-pr-reviewer.md` |
| Which generator tier a round gets | `agents/theorem-based-pr-reviewer.md` |
| How the orchestrator sequences the flow, what it branches on when a teammate returns, and how it briefs the teammates it spawns during the code loop | `skills/orchestrate/SKILL.md` |
| The procedure the orchestrator runs at one moment of the flow, and the briefs it spawns at that moment | the file for that moment under `skills/orchestrate/lib/` |
| What the merge-readiness loop does on each state the gate reports, which of those it returns as a question, how a ruling is matched to the question it answered, and the bounds on its waits | `agents/pr-merge-readiness.md` |
| What ends the monitor loop | `agents/pr-monitor.md` |
| Where the sdlc config tiers live, which keys they hold with what values and defaults, how the tiers resolve, what a read aborts on, and how a writer merge-updates one | `skills/lib/sdlc-config.md` |
| What a merge-readiness brief asks of the fixer | `agents/issue-fixer.md` |
| How the finalizer's section is found and replaced on a re-run | `agents/pr-finalizer.md` |
| How the finalizer reaches a round's review state, and what each report of the detail post means for its section | `agents/pr-finalizer.md` |
| In what order the review detail is assembled, how it is chunked under GitHub's comment cap, and what a piece too large for one comment becomes | `bin/sdlc-pr-post-theorem-records` |
| How a generator turns a PR — or, before one exists, the issues a batch will close — into theorems, and what may be emitted at all | `skills/theorem-generation/SKILL.md` |
| The bar an issue meets before the orchestrator runs on it, the issue-body grammar that bar keys on — which keys a `### Mechanical` bullet may open with, what each asserts, and which of them is executed — and how a body is graded against the rest of the bar | `skills/orchestrate-readiness/SKILL.md` |
| How the `### Mechanical` lines of both acceptance sections are graded: how a body is split into its sections and their bullets, which lines under `### Mechanical` are refused as no bullet, which paths are refused with nothing run, how a section's presence and its bullet count are settled, what each gap line says, and what the check exits with | `bin/sdlc-readiness-check` |
| What a brief parameter and a consequence class mean | `skills/theorem-agents-interface/SKILL.md` |
| Which file class a path falls in — code, instruction Markdown, or documentation | the global Claude configuration, outside this repository; no file in this plugin restates it |
| Which classes one agent edits, checks or reviews | that agent's own file under `agents/` |
| How a payload reaches `sdlc-agent-result-persist`, and where a writer stages it | `skills/agent-result-persist-interface/SKILL.md` |
| What the PR-read CLIs — the round under way, the adjustment comments and their cut, the fixer brief, the records chain — take, print and exit with | `skills/pr-read-cli-interface/SKILL.md` |
| Which sources a run's time report reads, how it attributes each second, and what it names as missing | `bin/sdlc-orchestrate-analysis` |
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
| `plan.md` | grouping the issues into batches and waves, and the plan the human confirms |
| `issue-lifecycle.md` | every issue-status transition, and the `/issue-*` verbs the orchestrator runs |
| `pr-lifecycle.md` | a PR from the developer's report to the ready flip: the link to its issues, the round-0 write, the body freeze, the documentation loop's briefs and round mechanics, the one spawn on the human's confirmation that the documentation loop is done, the close-out, and the briefs for the two loop agents |
| `wrap-up.md` | after the last PR's monitor loop ends, or its ready flip when the run monitors nothing: the post-merge tail and the summary |

A step the orchestrator runs is run by exactly one of the body, a lib
file, `pr-merge-readiness` or `pr-monitor`; a PR that moves a step
edits the surface it leaves and the one it lands in, and this table
when a lib file's moment changes.

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
  `skills/orchestrate/SKILL.md`; and `skills/theorem-generation/SKILL.md`,
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

## The run's waits are configured in tiers only the orchestrator reads

Two moments of the flow are waits on a human: the ruling on the seed
theorem list before a batch's developer runs, and the monitor loop
after a PR's ready flip. Those two, and the monitor's poll interval and
unchanged-poll bound, are what sdlc's config turns — `seed-review`,
`merge-wait`, `merge-poll-interval-seconds` and
`merge-max-unchanged-polls`. Every default is the unconfigured
behaviour, so a repo with no config file at any tier waits for the
ruling and monitors exactly as before the keys existed. A PR that adds
a key edits this list.

The config is three YAML files — a global user file outside every
repository, a shared repo file that is tracked, and a repo user file
that is gitignored — and the higher tier wins per key, so a team can
commit `auto-accept` to the shared file and one user can put the ruling
back for themselves. The paths, the keys' values and defaults, the read
aborts and the writer procedure have one owner,
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

What the two switches leave alone is as deliberate as what they skip:

- `seed-review: auto-accept` skips only the wait. The candidate list
  and the orchestrator's assessment of it are still shown, with none of
  the assessment's recommendations applied, and the list is still
  written as round 0 of the PR's state as the generator emitted it, so
  the first review round starts from the same records whichever way the
  seed was settled; the setting changes who settled it, not what is
  recorded.
- `merge-wait: skip` ends the PR's stages at the ready flip, and the
  summary lists the PR under its own table as ready and unmonitored.
  Nothing re-runs the merge-readiness gate after that flip, so a PR
  that falls `BEHIND` or `DIRTY` while it waits is the human's to
  remedy, not the run's.

## A blessed PR is gated on merge readiness, and the gate never remedies

The human's blessing — the confirmation that ends the PR's
documentation loop — authorizes the ready flip and nothing past it,
and the flip is not the next thing that happens. "Ready for review" is
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
party in a position to put a question to the human, so a state that
needs a ruling ends the agent's run: it returns with the gate's report
verbatim as its question, the orchestrator relays the question, and on
the answer spawns the agent again with the ruling in the brief, keyed
to the state and cause the question named. A merge conflict is not by
itself such a state: `BEHIND` and `DIRTY` both go to the fixer first,
ruling or not, because a conflict a repo rule already settles — a
plugin `version` line under the version-bump rule — would otherwise
cost the human a turn to restate that rule. Only a conflict the fixer
could not settle comes back as a question, with the fixer's report
naming it. A ruling answers only that
question: the re-spawn runs the gate afresh, and a ruling the new
report does not consume is discarded and named in the agent's report,
so the human learns that an earlier answer lapsed rather than took
effect.

Because every failed gate means the close-out is run again, each of
its steps is safe to repeat: the status flips repeat harmlessly, the
ready flip no-ops on a PR already ready, and `pr-finalizer` finds a
detail chain a previous run posted and leaves it alone, finds its own
marked section in the body and overwrites it, so a reader never meets
a stale section before the current one, and reports a closing-line
correction the body already satisfies as satisfied rather than
applying it twice.

## The issue is the ceiling of the fix loop

An issue's `## Code and instruction Markdown acceptance` section is
the ceiling of the code loop's fix loop, not its floor; its
`## Documentation acceptance` section sets no scope there, since what
that section asks for is `docs-writer`'s, in the documentation loop,
where that section and the documentation the diff made stale are the
ceiling in turn. A review finding whose fix lies outside the ceiling is
the human's to admit or refuse, and so is a developer's diff that
reaches a plugin the issue does not name or renames or deletes a file
the issue does not specify; the orchestrator never admits either on its
own. The issue's
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

That boundary is enforced by slots that must be filled rather than by
prose asking for judgment, and each slot has one owner:

| Slot | Owner |
| --- | --- |
| The `Scope:` block that ends the developer's report | `agents/issue-developer.md` |
| The gate that reads that block before the first review round | `skills/orchestrate/SKILL.md` |
| The ruling every finding line of a fixer brief ends in — a scope ruling, or the human's answer on a finding the orchestrator put to them — and what it is derived from | `skills/orchestrate/SKILL.md` |
| The cases in which a finding is put to the human at all, and that an in-scope finding is never one of them | `skills/orchestrate/SKILL.md` |
| That a finding carries one recommendation, the fix, and no rejection alternative or intent question of its own | `agents/theorem-based-pr-reviewer.md` |
| What a fixer does with a ruled finding line, and with one that has no ruling | `agents/issue-fixer.md` |
| The rule that a finding class recurring on consecutive rounds is a design question | `skills/orchestrate/SKILL.md` |
| The grading of an issue body's structural instruction against the repo | `skills/orchestrate/SKILL.md` |
| How a finding dropped on a scope ruling reaches the next round and retires | `agents/theorem-based-pr-reviewer.md` |
| How a finding dropped on a scope ruling is worded in the PR's final section | `agents/pr-finalizer.md` |
| That a closing-line correction is reported outside the findings, in every mode, and takes no part in any verdict | `agents/theorem-based-pr-reviewer.md` |
| That a closing-line correction gets no ruling and no fixer, and that the last round's section is what reaches `pr-finalizer` | `skills/orchestrate/SKILL.md` |
| How `pr-finalizer` applies a correction, which it reports as satisfied, and which it refuses to apply | `agents/pr-finalizer.md` |
| That the files-affected list is a floor, and that listing a path changes nothing about its class, owner, or review | `skills/orchestrate-readiness/SKILL.md` |
| That a listed path grounds no theorem about the rest of the tree | `skills/theorem-generation/SKILL.md` |

The reviewer's own scope theorem, in `skills/theorem-generation/SKILL.md`,
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
| That a documentation criterion becomes no theorem in a code round, and one theorem per criterion in a documentation round | `skills/theorem-generation/SKILL.md` |
| Collecting the deferred entries and the documentation criteria into the `docs-writer` writing brief, and that a criterion graded `not met` goes into the round's fixer brief | `skills/orchestrate/lib/pr-lifecycle.md` |
| The `documentation loop needed` return, and which fixer lines trigger it | `agents/pr-merge-readiness.md` |
| How `docs-writer` treats the entries and the criteria alongside the diff, and how it grades each criterion | `agents/docs-writer.md` |

## Documentation is reviewed in a loop of its own, after the code loop

Documentation describes code that has settled, so `docs-writer` writes
it once the code loop has ended — and until it had a loop of its own,
nothing read what it wrote. A `## Documentation acceptance` criterion
it missed, or a README restatement the change had made stale, reached
the merge unchecked, and an issue whose criteria were all documentation
had no path through the orchestrator at all. So the human's
confirmation that the code loop is done starts a **documentation loop**
rather than the close-out. It takes the code loop's round rules as they
stand — the style-fix loop, the reviewer spawn and its `Return:` line,
the fix loop's decision points, the review adjustments, the end-of-loop
confirmation — with `docs-writer` as its implementer: it writes on the
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
its own, so the detail poster posts the latest records of each, the
time report names the type on every round's row, and `pr-finalizer`
writes one sub-section per type.

**A bound per loop.** The documentation loop's round bound is the code
loop's value, counted on its own, so a PR that spent its code rounds
still gets its documentation rounds; the summary's `Review Rounds`
cell carries each loop's count.

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

**A merge-readiness remedy that touches documentation re-opens the
loop.** `pr-merge-readiness` used to spawn `docs-writer` itself when a
fixer deferred an edit, and that commit reached the gate with no round
over it. It now spawns none: a fixer round that defers a documentation
edit or resolves a rebase conflict in a documentation file ends its
run with `documentation loop needed`, the orchestrator runs the
documentation loop with those entries in the writing brief, scrubs
memory again, and spawns `pr-merge-readiness` afresh.

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
| The documentation-mode sources, and that no theorem under that mode is about code or instruction Markdown | `skills/theorem-generation/SKILL.md` |
| Which files `style-checker` reads under each mode, and against which guide | `agents/style-checker.md` |
| The round type in the anchor, the same-type carry, the cross-type id sequence, and the type a round anchored before rounds had one is read as | `skills/agent-result-persist-interface/SKILL.md` |
| How `docs-writer` reads a fixer brief, grades a criterion, and creates the branch and PR on the documentation-only path | `agents/docs-writer.md` |
| The `documentation loop needed` return, and that no `docs-writer` is spawned for a remedy | `agents/pr-merge-readiness.md` |
| One final-section sub-section per round type, and which records each is read from | `agents/pr-finalizer.md` |
| That the latest records of each type are posted, and in which order | `bin/sdlc-pr-post-theorem-records` |
| The type column on the time report's per-round rows | `bin/sdlc-orchestrate-analysis` |

## The theorem set is seeded from the issues before the developer runs

The first theorem list the human sees is generated from the issues
alone and settled — ruled on by the human, or accepted whole under
`seed-review: auto-accept` — before the batch's developer is spawned,
so a developer that goes beyond the issues, or decides something they
do not, surfaces in the first review round as new theorems against a
list the human already owns. That seed is **round 0**: rounds count
implementer passes from 1, and 0 is the pre-loop stage. The generator
runs on an issues-only brief and its return is held, not persisted —
every path `bin/sdlc-agent-result-persist` composes is keyed on a PR
reference, and none exists yet — until the developer's PR is open and
linked, when the ruled list is written as round 0's records file.
Round 0 holds that one file, so a walk that starts at round 1 never
sees it, and a PR with no round 0 — one reviewed outside the
orchestrate loop, or one whose seed was lost with the session that
took it — is reviewed from its whole diff, with the review saying so.
The seed is the code loop's: a documentation round carries only
records of its own type, so the first one reads no seed and generates
from the whole PR the same way, with the review saying so, and a batch
with no code to implement has no seed at all.

The candidates do not reach the human raw. The orchestrator assesses
the list before it asks — in its own session, with no spawn, because
it already holds the issue bodies and the source branch the judgment
needs — judging each theorem against the issues and the source branch:
whether an issue requires it or it reaches past the batch, which
acceptance criterion or stated behavior it tests, whether a
counterexample would matter, what it duplicates, whether its settle
mode and wording fit a disprovable claim, whether it asserts more than
one thing and should be split, whether it already holds or fails before
the developer runs, and whether its pointers exist. Across the set it
names the code and instruction Markdown criteria no candidate tests,
each with a proposed theorem to add; a documentation criterion is never
a gap, since no seed theorem is made from one. From that it recommends
one action per theorem with a one-line reason, and presents the
theorems recommended for a change first, then the coverage gaps with
their proposed adds, then the "accept" group, so the human reads what
needs a decision first. The human's
ruling set is accept, reject, change settle mode, merge, split, rewrite
and add. The assessment is advice: a theorem the human does not name is
accepted as the generator emitted it, not as recommended, and a claim
the orchestrator proposed becomes a ruled claim only when the human
adopts it, all at once or by name. That keeps round 0 a transcription —
every claim in it is the generator's or the human's — and keeps the
orchestrator from carrying review vocabulary on the human's behalf.
Each piece has one owner:

| Slot | Owner |
| --- | --- |
| The issues-only brief, and what a generator emits on it | `skills/theorem-agents-interface/SKILL.md` and `skills/theorem-generation/SKILL.md` |
| The seed spawn, the tier pick against the issue bodies, the assessment's dimensions and recommendations, and the per-theorem ruling or its `auto-accept` skip | `skills/orchestrate/SKILL.md` |
| The round-0 write, and how each ruling — a rewrite, split or add included — is transcribed onto round 0's records | `skills/orchestrate/lib/pr-lifecycle.md` |
| Round 0 as a valid round number holding only a records file, read as a code round | `skills/agent-result-persist-interface/SKILL.md` |
| A record without `state`, the seed ruling as a `human-refuted` source, and round 1's delta over the whole branch | `agents/theorem-based-pr-reviewer.md` |
| That the seed generator reads the files-affected section in place of a diff | `skills/theorem-generation/SKILL.md` |

## Carried records move through state, not a brief or an agent-built file

From round 1 on, `bin/sdlc-agent-result-persist` assembles the round's
records file; the reviewer never does. Its carry form reads the round
below the one under way, applies the reviewer's edits, appends the
records the round minted, and writes the result, and the reviewer
stages only its decisions — an edits file and a new-records file, each
written with `Write`. Building the whole file was a mechanical
transform the reviewer used to perform with a program of its own, and
the auto-mode classifier denies a per-instance program, so a round
whose build was denied stored nothing and posted nothing. The script
makes no decision: a carried record changes only where an edit names
it, and which state each theorem takes stays the reviewer's judgment.
Round 0's seed is the one records file still stored whole, because it
has nothing to carry.

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
an id names one theorem across the PR and the detail chain never holds
the same id twice.

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
Each piece has one owner:

| Slot | Owner |
| --- | --- |
| The carry form — its inputs, the edits grammar, the records-file shape, and each refusal | `skills/agent-result-persist-interface/SKILL.md` |
| The bounded read, its selection by the round's type, and the refusal that bounds it | `skills/agent-result-persist-interface/SKILL.md` |
| The id check a generator's `leave` makes, that the expected id is above the highest of either type, and what its refusal names | `skills/agent-result-persist-interface/SKILL.md` |
| What the reviewer stages as edits and as new records, and which form a fallback round stores through | `agents/theorem-based-pr-reviewer.md` |
| That `--delta-commits` alone marks a delta brief, and the `print-records` line it carries | `skills/theorem-agents-interface/SKILL.md` |
| The generator's own read, and the stop when it fails or prints no records | `skills/theorem-generation/SKILL.md` |
| The generator's renumbering on an id refusal, and the bound on its retries | `skills/theorem-generation/SKILL.md` |

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
that was never written. Because the record lands before the child
returns, a `<task-notification>` arriving for a child the log still
shows in flight is final rather than a race, and the reviewer writes
that child off at once and re-spawns its theorem.

Which children are in flight is the script's answer, through
`--mode print-in-flight`, rather than something the reviewer derives
from the log itself. The derivation used to be an `awk` snippet in the
interface skill, run by the reviewer by hand, which the suite could not
drive; it now lives beside the rest of the state logic, where the suite
does. Moving it into the script also fixed how a `stopped` record is
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
| What a `leave` prints, what `print-in-flight` reports and how it matches a `stopped` to a child, and that `stopped` names the child it writes off | `skills/agent-result-persist-interface/SKILL.md` |
| The shape of a child's hand-back after a `leave` that succeeded, and after one that failed | `skills/agent-result-persist-interface/SKILL.md` |
| That each child calls `leave` before composing its hand-back | that child's own file under `agents/`, and `skills/theorem-generation/SKILL.md` for the generator variants |
| The immediate write-off of a child that handed back without a `leave`, and that it counts as a resume pass | `agents/theorem-based-pr-reviewer.md` |

`test/sdlc-test.sh` drives the script's records and round-log modes
against a state root of its own — the seed write, the carry form, each
refusal it makes, the bounded read, the generator's id check at
`leave`, the path `leave` prints, the in-flight derivation with a
`stopped` landing after its replacement's `enter`, and the round types:
the type an anchor writes and the refusals around it, the `round-type`
line `print` ends with, a first documentation round carrying nothing
while its ids continue the code rounds', a code round carrying past a
documentation round, the carry's cross-type id floor, and
`print-records`' selection by type. It drives the detail poster
posting each type's records and the time report's type column against
the same root. The same suite
drives the PR-read scripts against a stub `gh` that serves a PR's
reviews and comments — each script's output and exits, every case of
the adjustment cut, and that the adjustments read reaches the previous
round's log through the persist script and nothing else — and checks
that a command any executable under `bin/` does not handle exits
through that executable's own failure status. It needs only bash,
`jq` and the POSIX utilities, and reaches no network.

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
that ran, finished and reported can still skip its own last call, and
the harness can drop a notification outright. Every loss a round has to
survive is of that shape — never a child that failed to run — so each
child records its own entry and exit, and nothing the reviewer derives
depends on having heard back.

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
beside the deadline in the reviewer. No verifier measurement exists,
and a verifier's work is a strict subset of a disprover's: it reads one
counterexample against one head tree and runs no search. A shorter
deadline derived from that subset relation would be a guess, and what
the guess costs when it is wrong is `TaskStop`ing a verifier that was
about to report, which drops a real check. So the verifier reuses the
disprover's figure until one is measured for it.

## A moved head voids the round, and the restart never mixes trees

The round's `anchor` record carries the head SHA its theorems were
generated against, and a head that differs from it — at the anchor
step, or at the fetch before the disprovers fan out — voids the round:
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

The cheaper check runs first. A `DISPROVED` report whose counterexample
is not a verbatim quote from the PR head never reaches a verifier. The
canonical instance is a quote taken from another ref, such as `main` or
`origin/<base>`, which reads as real prose and matches nothing at the
head commit; a filesystem quote from the primary clone is the rarer
instance, because the permission gate denies a read naming a
primary-clone path. Spawning a verifier against such a report would
waste the check on evidence that has already failed a cheaper one, and
spawning a second disprover would break the one-child-per-theorem
invariant, so the theorem is left unsettled and live again next round.

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
claim, and `--full` — which re-disproves every recorded theorem the
human has not ruled on — is the bounded-cost check for that, priced
once instead of every round. A design that re-disproved everything
every round would have no gap and no saving either.

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
behalf. `issues` falls back to the whole resolved set because a theorem
tagged to no member is malformed, and on a batch that tags the minted
theorem to every member, which is the safe direction: each member's
verdict then reflects it.

## Skills

| Skill | Purpose | Where it runs |
| ------- | --------- | --------------- |
| `/sdlc:orchestrate-ready <issue>` | Groom one issue until the readiness check passes, then flip its status | main session, interactive |
| `/sdlc:orchestrate <issue>…` | Plan, delegate, and coordinate the end-to-end fix for one or more issues, refusing any that fails the readiness check | main session |
| `/sdlc:git-review-pr <PR> [--generator <name>] [--full] [--mode <mode>]` | Review one PR — a thin standalone wrapper that spawns the reviewer agent | main session |
| `/sdlc:orchestrate-cleanup <PR> [--dry-run]` | Remove what one merged or closed PR left behind — its review state, the worktrees of the agents its state records, its local head branch and the `.claude/tmp/` scratch of the issues it closes — asking nothing, then bring the default branch up to date; `--dry-run` lists what would go and removes nothing | main session |
| `/sdlc:orchestrate-cleanup --all [--dry-run]` | Remove everything every run left in this repo — all review state, every worktree under `.claude/worktrees/`, every local branch but the default branch, all `.claude/tmp/` scratch and every other session's scratchpad — after showing the full list and asking one go-ahead; `--dry-run` shows the list and asks nothing | main session, interactive |
| `/sdlc:orchestrate-analysis <PR>` | Report where one orchestrate run's wall-clock time went — a thin wrapper that runs `bin/sdlc-orchestrate-analysis` on a PR given in any form `/github-prs:pr-view` accepts and presents its output unchanged | main session |
| `/sdlc:sdlc-config-global` | Create or merge-update the global user sdlc config, the lowest tier | main session, interactive |
| `/sdlc:sdlc-config-repo` | Create or merge-update the shared, tracked repo sdlc config | main session, interactive |
| `/sdlc:sdlc-config-user` | Create or merge-update this user's repo sdlc config, the highest tier, and keep it gitignored | main session, interactive |
| `sdlc:theorem-generation` | How a generator turns a PR, or the issues a batch will close, into disprovable theorems | preloaded into each generator agent |
| `sdlc:theorem-agents-interface` | What a theorem agent's brief parameters and the consequence classes mean | preloaded into each theorem agent |
| `sdlc:agent-result-persist-interface` | What the `sdlc-agent-result-persist` CLI does — its modes, flags, paths and record grammar | preloaded into the reviewer, each generator variant, the disprover, the verifier, `pr-finalizer` and `pr-merge-readiness` |
| `sdlc:pr-read-cli-interface` | What the PR-read CLIs — `sdlc-pr-round`, `sdlc-pr-adjustments`, `sdlc-fixer-brief`, `sdlc-records-chain` — take, exit with and print | preloaded into the reviewer, `issue-fixer`, `docs-writer` and `pr-finalizer` |
| `sdlc:orchestrate-readiness` | The bar an issue meets before the orchestrator runs on it, the issue-body grammar, and the check that returns what a body is missing as a gap list | invoked by the grooming skill and the orchestrator; preloaded into each generator variant |

The rows with no leading slash are not user verbs — each declares
`user-invocable: false`, which
keeps it out of the human `/` menu while leaving it invocable.
`theorem-generation` and `orchestrate-readiness` are preloaded into
each `theorem-generator` variant through that agent's `skills:`
frontmatter, and `theorem-agents-interface` into every theorem agent
— the generator variants, `theorem-disprover`, and
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
invoke the same check, `orchestrate-readiness`: the grooming skill
rewrites the body until the check returns no gap, and the orchestrator
runs the check on every issue it is given before any analysis and
stops, before a branch or a PR exists, on the first non-empty gap
list, naming the grooming skill rather than running it — grooming is a
conversation with the human, and the orchestrator is not one. The bar
and the grammar are owned by `skills/orchestrate-readiness/SKILL.md`;
why grooming is interactive rather than an agent is owned by
`skills/orchestrate-ready/SKILL.md`.

`/sdlc:orchestrate-cleanup` is the pass behind the flow, and its two
forms are two scopes of one script, `bin/sdlc-orchestrate-cleanup`.
The `<PR>` form is what `/sdlc:orchestrate`'s post-merge tail runs,
once for each PR the run merged, asking nothing: a merged PR's evidence
is no longer needed to diagnose a round, so its review state goes with
the worktrees, branch and scratch that produced it, and a PR the run
did not see merge keeps all of it. The `--all` form is the human's, for
clearing up after many runs, and it is the one form that asks — a
single question, put over the full list a dry run printed. The skill
owns which form asks and what it shows first; what each scope removes,
the lines it prints and its exits are the script's.

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
  PR is recorded in the PR's state — the orchestrator and
  `pr-merge-readiness` record each one through
  `sdlc-agent-result-persist --mode agent`, and a review child records
  itself at `enter` — and the `<PR>` scope removes exactly the
  `.claude/worktrees/agent-<id>` worktree and the `worktree-agent-<id>`
  branch of each id the state names, nested worktrees included, plus
  any worktree under `.claude/worktrees/` still holding a branch it
  deletes. A spawn nobody recorded is left behind, and `--all` is the
  backstop that takes it.
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
| `bin/sdlc-agent-result-persist` | Writes and reads the review pipeline's state under XDG state; the one place that composes those paths | `skills/agent-result-persist-interface/SKILL.md` |
| `bin/sdlc-orchestrate-analysis` | Prints the Markdown time report behind `/sdlc:orchestrate-analysis`, reading review state only through `sdlc-agent-result-persist`, the orchestrator session's transcript, and the PR's GitHub timeline; writes nothing | its own header comment |
| `bin/sdlc-pr-round` | Prints the number of the review round under way: the PR's review count plus one | `skills/pr-read-cli-interface/SKILL.md` |
| `bin/sdlc-pr-adjustments` | Prints the comments posted since the previous round, less sdlc's own marker comments, cutting at the newest review, else at the newest instant in the previous round's log, else at the PR's creation | `skills/pr-read-cli-interface/SKILL.md` |
| `bin/sdlc-fixer-brief` | Prints the most recent comment when it is a fixer brief and exits 3 naming its first line when it is not; with `--all`, every brief the PR carries | `skills/pr-read-cli-interface/SKILL.md` |
| `bin/sdlc-records-chain` | Reports whether the review-detail chunks posted on a PR form one complete chain, and which chunks are there when they do not | `skills/pr-read-cli-interface/SKILL.md` |
| `bin/sdlc-pr-post-theorem-records` | Assembles a finished PR's review detail out of its state, chunks it under GitHub's comment cap and posts it as one marked chain, unless the PR already carries a complete one | its own header comment |
| `bin/sdlc-readiness-check` | Grades the `### Mechanical` bullets of an issue's acceptance sections against the tree, reading the body through `issue-view`, and prints one gap line per failing bullet, per line under `### Mechanical` that is no bullet, per acceptance section with no bullet, and one for a body with neither section; exits 3 on any gap and 0 on none | `skills/orchestrate-readiness/SKILL.md` for the keys, its own header comment for the rest |
| `bin/sdlc-pr-monitor` | Polls one ready PR, waiting the interval between polls inside the call, until it merges, closes unmerged, falls `BEHIND` or `DIRTY`, or sits unchanged for the bound's number of polls; prints one line per poll and ends on a terminal line, or on a `continue` line before a call could reach the Bash tool's time limit; reads, and writes nothing | its own header comment |
| `bin/sdlc-orchestrate-cleanup` | Removes what runs left in the primary clone — review state through `sdlc-agent-result-persist`, worktrees, local branches, `.claude/tmp/` scratch and, for the whole repo, other sessions' scratchpads — for one merged or closed PR with `--pr`, or for the whole repo with `--all`, then brings the default branch up to date; `--dry-run` prints the same items and acts on nothing; asks nothing, and never touches a branch on `origin` or the default branch | its own header comment |

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
the body — a section with no bullet, or a body carrying neither
acceptance section — so the model's grading starts from a body the
script has already found well-formed. The deterministic
grading around the old command — which reported site a files-affected
tag covers — moved into the script with it, so an unchanged body and an
unchanged tree get the same verdict on every invocation.
`test/sdlc-readiness-check-test.sh` drives it against a scratch
repository and a stub `issue-view`; a bullet it feeds that would write
if run leaves a marker file, and each case carrying one checks that
none appeared.

`sdlc-pr-monitor` is a script because the wait between polls has to
happen inside the agent's turn. `pr-monitor` used to wait on a Monitor
watch, which ended its turn after every poll; the harness forced a
hand-back on each such turn, the orchestrator read that hand-back as the
monitor's final report and spawned another monitor on the same PR, and
the watch kept waking the first one. With the loop in a foreground Bash
call, the agent's turn runs from its spawn to its report and nothing it
hands back is interim. The call's length is bounded by the Bash tool's
600-second limit, so the script budgets 540 seconds of wall time per
call, counting the gate's own retry waits, and exits with
`continue <unchanged-count> <last-state>` before a wait that would pass
it; the agent calls it again with those values, in the same turn, and
the resumed call starts with the wait the previous one skipped, so no
two polls run closer than the interval. The state crosses that boundary
as a checksum of the poll's compacted gate report, which is what lets a
multi-line report travel as one argument; the readable state stays on
the `Polled` lines. An interval the budget cannot hold is refused before
anything is polled, which is where `merge-poll-interval-seconds`'s
maximum comes from. `test/sdlc-pr-monitor-test.sh` drives it against
stub `pr-view` and `pr-ready-to-merge` executables serving a scripted
poll sequence, and stub `sleep` and `date` executables that advance and
read a fake clock, so the budget cases run without waiting; reading wall
time through `date +%s` is what makes that stub possible without a hook
in the script.

The PR-read scripts and the detail poster share one sourced helper,
`bin/lib/sdlc-pr-common.sh`, which is not itself callable: it parses the
canonical PR reference they take, makes the one `gh pr view` read the
PR-read scripts share, and spells the two comment markers sdlc writes —
the fixer brief's first line, and the review-detail chunk's in both the
regex that filters on it and the printf form that writes it — as the
only place under `bin/` that does, so every script that filters on or
writes a marker reads it from there. The detail chunk's marker is
written nowhere else; the brief's is spelled once more, by whatever
writes a brief. The PR-read scripts
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

Every executable under `bin/` turns a failure in a command it did not
handle into its own failure status with a line naming the command,
never the tool's own status — the PR-read scripts, the detail poster,
the readiness check, the PR monitor and the cleanup exit 1, the persist
script and the time report route it through their existing exit 2 — so
a caller branching on an exit sees only the statuses each contract
documents.

The time report and the detail poster compose no state path of their
own: each reaches round logs, result files and transcripts only through
the paths `sdlc-agent-result-persist`'s read modes print, so a change
to where that state lives is a change to one executable. The detail
poster posts through github-prs' `pr-comment` executable, called by
name off `PATH`, so each chunk is re-read after it lands without the
poster spelling a `gh` call of its own. A source the time report cannot
reach is named in the report as missing, and no row that source would
have backed is printed — the report never reads a substitute, so a
missing row is evidence that a source is gone, not a guess about what
it held.

## Files it writes

Everything the **review pipeline** persists is written by
`bin/sdlc-agent-result-persist` under XDG state, outside every
repository — a review round writes nothing to the branch it reviews. A
PR that adds or removes one of these edits this list, the same
convention "Executables" above sets. Which mode writes each, and the
record grammar the log holds, are part of that contract and are owned
by `skills/agent-result-persist-interface/SKILL.md`.

The script never takes a payload — a child's report, a round's records
or review, the edits and new records a carried round is built from —
on its command line. The writer stages it with the `Write` tool in the
session scratchpad and names that file by path, with `--from` or, for
the carry form's edits, `--edits`; the
staging file is the pipeline's one write outside XDG state, it lies
outside every repository as well, and it dies with the session. That
staging is why the theorem children carry the file-writing tools while
the review pipeline stays non-mutating. Why a file rather than a heredoc, and how
the staging path is named, are owned by
`skills/agent-result-persist-interface/SKILL.md`.

`pr-finalizer` reads that state and writes none of it. The orchestrator
writes round 0's `records` — the seed settled before the developer ran,
transcribed through the same script — and, like `pr-merge-readiness`,
appends to the PR's agents log for each agent it spawns; neither writes
anything else here. The `sdlc-config-*` verbs write the config files their contract
names, on the user's yes, and those are the user's files rather than
run state. The implementing
agents are outside the claim entirely and write nothing this
list owns: those declaring `memory: project` capture their agent memory
with `/cc-tools:agent-memory-inbox-capture`, each of them but
`style-checker` commits its work to the branch, and
`agent-memory-scrubber` commits what `/cc-tools:agent-memory-inbox-cleanup`
transfers.

Write `<repo-dir>` for
`${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/<host>/<owner>/<repo>`, the
PR's repository's directory, and `<round-dir>` for
`<repo-dir>/pr<pr>/round<round>`, the round's own directory:

| File | What it holds |
| ------- | --------------- |
| `<repo-dir>/repo.yml` | the host, owner and name of the repository whose state the directory holds, written when the directory is created |
| `<round-dir>/log` | the round log, whose `anchor` line names the round's type beside the head it was generated against |
| `<round-dir>/<theorem>-<agent>` | one child's full report |
| `<round-dir>/records` | the round's theorem records, which the next round of its type carries forward — built by the script from the round of that type below plus the reviewer's edits and new records; round 0's is the ruled seed, stored whole |
| `<round-dir>/review` | the round's argued review, which the posted review summarises; the detail chain `pr-finalizer` posts once the loop concludes carries it whole, or names it by path when it is too large for one comment |
| `<round-dir>.voided-<instant>/` | the whole directory of a round whose branch moved under it, set aside rather than overwritten |
| `<repo-dir>/pr<pr>/agents` | the PR's agents log: one record per agent spawned for the PR, naming the definition and the agent id, beside the rounds because a spawn belongs to no round and a voided round's rename must not carry it away |

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
host is guessed and no network call is made. `--mode list` takes its
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
removes a whole `pr<N>/`, and its only caller is
`sdlc-orchestrate-cleanup`, which `/sdlc:orchestrate` runs for a PR
once that PR has merged and the human runs otherwise; so a `pr<N>/`
outlives every round of its PR, and goes when the PR has merged — its
evidence is no longer needed to diagnose a round — or when the human
decides it is no longer wanted.

## Agents

Every agent but `pr-merge-readiness` and `pr-monitor` declares
`isolation: worktree`, so the harness creates a throwaway worktree per
spawn. Those two declare no `isolation` and run in the orchestrator's
primary clone, writing nothing to it: each is a loop over a gate, and
every change to the branch a loop drives is a commit by a teammate it
spawns or that the orchestrator spawns after it. Nothing removes a
worktree during a run: the reviewer leaves its children's worktrees
where the harness made them, and `sdlc-orchestrate-cleanup` removes
them once the PR has merged, finding each by the agent id the PR's
state names. That is why every spawn made for a PR is recorded there:
the orchestrator and `pr-merge-readiness` record each agent they spawn
through `sdlc-agent-result-persist --mode agent`, and a review child
records itself when it enters a round. The orchestrator's seed
generator and the batch's developer are spawned before the PR has a
reference, so their ids are held and recorded once the PR is linked.

| Agent | Purpose |
| ------- | --------- |
| `issue-developer` | Implements one batch of issues on one branch |
| `issue-fixer` | Applies review findings, or a merge-readiness remedy — a rebase onto the base, resolving each conflict a ruling or its own resolvability conditions settle and escalating the rest — to an open PR's branch |
| `code-documenter` | Adds or corrects the comments in a round's code files, and corrects or deletes those its instruction-Markdown files carry where the diff contradicts them, each file against its own class's style guide, before its review |
| `style-checker` | Reports a round's style-guide violations in the files of the side of the class split its `--mode` names — code and instruction Markdown in the code loop, documentation in the documentation loop — each file graded against its own class's guide, which the orchestrator sends to the loop's fixer before its review |
| `docs-writer` | Writes a PR's documentation in the documentation loop that follows its code loop, fixes what that loop's rounds find in it, and for a batch with no code to implement creates the branch and opens the PR |
| `agent-memory-scrubber` | Curates the run's agent-memory inbox onto the PR |
| `pr-merge-readiness` | Drives one blessed PR through the merge-readiness gate, spawning `issue-fixer` then `agent-memory-scrubber` for each remedy, recording each spawn in the PR's state, and returns a state that needs a ruling as a question and a remedy that left documentation to write or a documentation conflict resolved as `documentation loop needed` |
| `pr-finalizer` | Posts the run's assembled review detail to a finished PR and writes the run's final section into its body, one sub-section per round type, replacing the one an earlier run left, and corrects the closing lines its brief names |
| `pr-monitor` | Runs `sdlc-pr-monitor` on one ready PR until it merges, closes unmerged, falls `BEHIND` or `DIRTY`, or sits unchanged long enough to ask whether to keep waiting; hands back the script's error verbatim when it fails instead, which the orchestrator reports as needing the human's attention |
| `theorem-based-pr-reviewer` | Reviews one PR, fanning out the generator, the disprovers, and the verifiers from inside itself |
| `theorem-generator` | Searches one PR — or, before one exists, the issues a batch will close — for claims worth trying to disprove |
| `theorem-generator-medium` | The same generator at a higher reasoning tier |
| `theorem-generator-high` | The same generator at a higher reasoning tier still |
| `theorem-generator-xhigh` | The same generator at the highest reasoning tier |
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
`pr-monitor` is the one agent that writes nothing; its line is
`Read, Bash, Monitor`. Its body puts nothing on `Monitor`: every wait
between polls runs inside a foreground `sdlc-pr-monitor` call, because
a wait on a Monitor watch ends the agent's turn, and a turn that ends
without a report is handed back as one and read as final.

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

### The generator skeletons are copies of one file

`agents/theorem-generator.md`, `-medium`, `-high` and `-xhigh` are
byte-identical except the frontmatter `name:` and `effort:` lines, the
tier phrase in `description:`, and the one body sentence stating the
definition's own name and tier as literals — the name each passes as
`--agent` on its `leave` call. Generation instructions live in
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

Only those lines and that sentence may differ. A skeleton must not
carry generation guidance, and must not *enumerate* what the skill
supplies — a list of the skill's sections is byte-identical across all
four skeletons, so the `diff` passes while every copy names a section
set the skill no longer has. Point at the whole file instead.

`theorem-disprover` and `counterexample-verifier` are deliberately not
skeleton sets: one definition each, no tiers, and a `model` the
reviewer routes per spawn by the theorem's settle mode — a cheaper
model for a `mechanical` theorem, whose grep-shaped claim a cheap model
settles as well as any other, and none for a `semantic` one. A
frontmatter `model:` is only the default for an unrouted spawn, not a
floor or a ceiling — the `Agent` tool's `model` parameter may name a
lower, higher or equal model for a single spawn — and no file outside
that frontmatter spells the value, which is what keeps a model change a
one-file edit. If a harness ever refuses to route below the declared
default, the mechanical spawn runs at that default: costlier, never
wrong.

## Dependencies

`plugin.json` declares `dependencies` on `issues`, `git-tools`,
`github-prs`, and `cc-tools`. Those edges are what guarantee the
cross-plugin skills this plugin invokes are installed and enabled
wherever it runs — the issue verbs, `git-branch-create`,
`git-issues-from-branch`, `git-range`, `git-branch-sync`, the PR verbs,
`agent-memory-inbox-capture`, and `agent-memory-inbox-cleanup` — and
that the executables the scripts here call off `PATH` are there to
call: `pr-comment` for the detail poster, and `git-default-branch`,
`pr-view` and `pr-closing-issues` for the cleanup. The
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
