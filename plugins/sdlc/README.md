# sdlc

Takes GitHub issues from a rough description to merged pull requests:
it grooms each issue until it can be implemented without stopping to
ask, implements the issues in parallel agents, reviews each PR by
trying to disprove claims about it, brings each PR you approve to the
point where it can merge, and removes what the run left behind once it
has.

## Why use it

- **You are asked only what is yours to decide.** Every choice the run
  puts to you arrives as numbered options with the evidence behind
  each and a recommendation, and a class of question you would answer
  the same way every time can be settled once, in config.
- **The review argues from evidence.** Each round states the claims the
  PR has to satisfy, as theorems, sends one agent to break each, and
  has a second agent re-check every counterexample before it becomes a
  finding.
- **Documentation is reviewed as well as code.** A PR's documentation
  is written once its code has settled and goes through review rounds
  of its own.
- **Several issues run at once.** Issues are grouped into batches, one
  branch and one PR each, and batches that do not depend on one another
  are implemented in parallel.
- **Ready means mergeable.** A PR is marked ready for review only after
  a gate has found its branch current with its base, free of conflicts
  and passing its required checks.
- **A run leaves a record.** The rounds, the findings and your rulings
  stay on disk after the merge, and one command turns them into a
  report of where the time went.

## What you need first

- Claude Code with this plugin enabled. Its dependencies, the `issues`,
  `git-tools`, `github-prs` and `cc-tools` plugins, are installed and
  enabled with it; `issues` has to be 0.20.0 or later and `cc-tools`
  0.12.0 or later.
- A repository whose pull requests are on GitHub. Every PR is opened,
  read, reviewed and commented on through `github-prs`, which works
  through `gh`.
- `.issues/repo-config.md` in the repository. Without it a run stops
  and names `/repo-config`, the command that creates it.
- The mikefarah build of `yq`, v4 or later, on the machine. The
  questions a run puts to you are checked with it.
- A session in the repository's primary clone. `/sdlc:orchestrate`
  stops when it is started from a worktree.
- For each issue you hand it: the issue is open, no open PR already
  closes it, no local branch in the clone names it, and, where the
  repository tracks a status, its status is one the config allows.

## Starting a run

Groom each issue, then run the orchestrator on the groomed issues:

```text
/sdlc:orchestrate-ready 101
/sdlc:orchestrate-ready 104
/sdlc:orchestrate 101 104
```

`/sdlc:orchestrate-ready` is a conversation about one issue. It ends
with the issue's body rewritten to the bar the orchestrator holds and
the issue's status set to Ready, or to Todo on a board with no Ready.

`/sdlc:orchestrate` takes one or more issues and runs unattended
except where it has something for you to decide.

Nothing has to be configured first: with no config file a run uses the
defaults listed under "Configuration". To change one, run
`/sdlc:sdlc-config-user`, `/sdlc:sdlc-config-repo` or
`/sdlc:sdlc-config-global`.

## What a run looks like

In order, `/sdlc:orchestrate`:

1. Prints the config it resolved, each value beside the tier it came
   from.
2. Checks every issue it was given, and stops before any branch or PR
   exists when one is unavailable or its body falls short of the bar.
3. Groups the issues into batches, shows you the plan, and waits for
   your confirmation where `plan-confirm` says to.
4. Sets each batch's issues to In Progress and assigns them.
5. Settles the seed theorem list for each batch.
6. Has `issue-developer` implement each batch on its own branch and
   open a draft PR.
7. Runs the code loop on each PR: review rounds over its code and
   instruction Markdown, each followed by fixes, until a round approves
   with no findings or the loop reaches its round cap.
8. Runs the documentation loop on each PR in the same way.
9. Takes each PR through merge readiness, marks it ready for review and
   sets its issues to In Review.
10. Watches each PR until it merges.
11. Cleans up after every PR it saw merge, and prints a summary.

While a run is under way a status line under the prompt names its
issues, its PR, the phase and the agents at work:

```text
PR #812 (#745 #746) · code loop r2 · theorem-based-pr-reviewer › disprove 15/31 theorems
```

`/orchestrate-status off` hides the line and `/orchestrate-status on`
restores it.

### Grooming

`/sdlc:orchestrate-ready` checks the issue against the readiness bar
and lists every gap it found, each with the answer it proposes, before
its first question. From there:

- A gap with one possible repair is repaired without a question, and
  the final report lists it. That covers a missing or mistitled
  acceptance or files-affected heading, a sentence that prescribes an
  implementation step the implementer can derive, which is restated as
  the outcome it was meant to produce, and a gap whose repair lies in a
  system the repository holds no source or config for, where the body
  states what the change assumes of that system. Out-of-repository
  work taken out of a body is offered as a separate issue, filed only
  on your yes.
- Every other gap is a design decision the body leaves open, and is put
  to you as a question, one per turn. Each names the place in the
  repository that already does the thing, or the search that found
  none.
- The acceptance criteria and the files-affected list are settled in
  one closing approval, which `ready-rewrite-approval: auto` skips.

The status is set only when the check returns no gap and every design
question has your answer. A session that ends with a question
open resumes on that question the next time you groom the issue.

### Re-checking an issue

A full readiness check grades the body against the bar and traces it
against the code. For each behavior the body specifies and each
acceptance criterion, the trace reads the code the body names or calls,
confirms that names, interfaces and validators behave as the body
assumes and that the criterion can pass for the change as specified,
and follows any state the change introduces through success, stop and
re-run.

A `ready` verdict is then recorded on the issue as a stamp, so that a
later check repeats only what could have changed. The stamp is one
comment headed `## Orchestrate readiness`. It holds a hash of the body
and the issue's blocked-by edges, the commit of the default branch that
was graded, the sdlc version that graded it, and the files the verdict
relied on, the body's files-affected paths among them. Any account's
stamp counts, so one person can groom an issue and another can run it.

Every check, stamped or not, first decides whether the issue is
available and grades its mechanical acceptance bullets against the
tree. A gap found there is followed by a full check. With none, the
stamp decides the rest:

| The issue's stamp | The rest of the check |
| --- | --- |
| Its hash and version match, and the default branch has changed none of its files since the stamped commit | Skipped: the verdict is `ready`. |
| Its hash and version match, and the default branch has changed one of its files | Narrowed: it grades only whether that diff breaks the body, and re-grades nothing the diff leaves unchanged. |
| There is none or it cannot be read, the body or a blocked-by edge changed, another sdlc version graded it, or its commit is not an ancestor of the default branch | Run in full. |

A file the diff renames counts as changed under its old and its new
path. A Jira tracker carries no stamp, so every check there runs in
full.

`/sdlc:orchestrate-ready` writes the stamp after its final `ready`
verdict, once no design question waits on your answer.
`/sdlc:orchestrate` writes it after a `ready` verdict from a narrowed
or full check. After a skipped check neither writes. The write is
refused unless the working tree is clean and at the tip of the freshly
fetched default branch, so a stamp never names a commit other than the
one that was read. A refused write is reported and leaves the verdict
`ready`.

### The plan

A batch is a set of issues implemented together on one branch and
delivered as one PR, holding at most `max-issues-per-batch` issues.
Batches with no dependency on one another form a wave and run in
parallel; a batch that depends on an earlier one waits for it. A batch
none of whose issues carries code or instruction Markdown criteria
skips the seed and the code loop: `docs-writer` creates its branch and
opens its PR, and the documentation loop runs from there.

### The seed theorem list

Before a batch's developer starts, `theorem-generator` writes a first
list of theorems from the issues alone, and `theorem-assessor`
assesses it: a recommended action per theorem, and a proposed theorem
for each acceptance criterion none tests. The first review round
starts from the settled list, so work that goes beyond the issues
shows up there as new theorems.

`seed-review` sets how the list is settled:

- `accept-recommended`, the default, applies every recommendation and
  does not wait.
- `accept-as-emitted` keeps the list as generated and does not wait.
- `ask` shows you the theorems recommended for a change, then the
  coverage gaps, then the rest, and takes your rulings: accept, reject,
  change settle mode, merge, split, rewrite or add. A theorem you do
  not name is accepted as generated.

The list and its assessment are shown under every value.

### Review rounds

A round of the code loop first checks whether the PR's base has moved
under it, per "A base that moves during the code loop" below. It then
runs `code-documenter`, which corrects the
comments in what changed, then `style-checker`, whose findings go to
`issue-fixer` before the review, then `theorem-based-pr-reviewer`. The
reviewer generates theorems for what changed since the last round,
carries forward those still standing, has each one attacked and each
counterexample re-checked, and posts a review on the PR. Findings go
to `issue-fixer` in a brief posted as a PR comment, and the next round
reviews its commits.

What you say about a round, such as rejecting a finding, changing its
severity or naming a defect it missed, is posted on the PR as an
adjustments comment, and the next round reads it.

A loop ends when a round approves with no findings, or at its round
cap, where every finding still open reaches you as one decision.
Whether a clean end waits for you is set by `loop-end` for the code
loop and `docs-loop-end` for the documentation loop.

### A base that moves during the code loop

The merge-readiness gate runs only after a PR's loops have ended, and
a review round measures the branch against its own merge base. Left to
the gate, a base that moved during the code loop would show up as a
conflict after the last review, and its resolution would bring in base
code no round had reviewed. The in-loop mergeability check finds the
moved base while rounds are still running.

The check runs after every round that puts commits on the branch,
before `code-documenter`. It fetches the base and the PR branch and
changes nothing:

- The base has **moved** when its tip is not an ancestor of the PR's
  head.
- On a moved base, the **overlap** is the set of paths that both the
  base and the PR changed since their merge base. Renames are detected,
  and a renamed path counts under its old and its new name, so a rename
  on one side overlaps an edit on the other.

A conflict needs both sides to change one path, so every conflict lies
inside the overlap. The check works from the fetched refs alone: it
does not ask GitHub whether the PR is mergeable, and it waits on no
running check.

With the base unmoved, or an empty overlap, the round goes on. A base
that moved under none of the PR's paths cannot conflict with it, and is
left to the merge-readiness gate.

A non-empty overlap starts a **rebase round**, whether or not the two
sides' changes conflict. The orchestrator lists the conflicts a trial
merge finds and posts a fixer brief on the PR carrying the overlapping
files and those conflicts, and `issue-fixer` rebases the branch onto
its base. Each conflict is resolved by the first of these that settles
it:

1. A ruling that names the conflict.
2. A rule the repository's instruction Markdown states, such as the
   one that settles a conflicting plugin `version` line.
3. Both sides kept together, where their changes edit different parts
   of the conflicting region or one already contains the other.

A conflict none of them settles is a design decision. The fixer aborts
the rebase, pushes nothing, and the conflict is put to you; your answer
travels in the next rebase-round brief. Any other stop, such as a
refused push, is an escalation: the orchestrator's ruling on it, or
yours where the question is yours, travels in the next brief likewise.

A rebase round that pushed is treated as a fix round: the check runs
again, and `code-documenter`, `style-checker` and the review run over
the rebased branch, so the base code the rebase brought in is reviewed
with the PR's own. A rebase round does not count against
`code-review-max-rounds`.

The check and the rebase round belong to the code loop. A base that
moves during the documentation loop, or after it, is the
merge-readiness gate's to find.

### The questions it asks you

A decision reaches you as a numbered record. Its problems are `P1`,
`P2` and on, and each problem's options `P1.1`, `P1.2` and on. Every
problem states what is wrong, where, and what it causes. Every option
states what it does, the evidence it rests on, as a quoted file line
or a command with its output, and what it costs you. One option is
recommended, with the reason.

Reply with option ids, or in your own words. A problem your reply does
not address stays open and is put to you again as first worded. Your
replies are stored with the record.

Some prompts are not records: the plan's confirmation, and the
per-theorem rulings on the seed list under `seed-review: ask`.

A **standing ruling** is a config key that answers one class of
decision in advance, so the run applies the answer and reports it
rather than asking:

- `outside-criteria-finding: fix-in-pr` fixes, in the PR at hand, a
  finding whose fix lies outside the issue's acceptance criteria, when
  every file the fix touches is in this repository, the PR is still a
  draft, and the fix leaves no choice open. A finding that fails any of
  those is put to you.
- `recurring-finding-class: fix-class` has the next fix cover every
  instance of a class of finding once that class has been filed on two
  consecutive rounds. A class that recurs after that is put to you.

Set to `ask`, either key puts every decision of its class to you. A
decision a standing ruling settled is named in the round's report and
recorded in the PR's final section as that key's ruling.

### The documentation loop

Once the code loop has ended, `docs-writer` writes the documentation
the change calls for, and the loop reviews it in rounds of its own:
`style-checker` over the documentation files the PR touched, then the
reviewer, working from the issues' `## Documentation acceptance`
criteria and from each place documentation restates a fact the PR
changed. `docs-writer` fixes what a round finds. Its report grades
each documentation criterion met or not met, and a criterion it grades
not met is fixed in the next round even when the review approved.

The loop has a round cap of its own, `docs-review-max-rounds`, which
no code round counts against.

### From approval to merge

A PR's documentation loop ending, on your confirmation or on a clean
end under `docs-loop-end: auto-when-clean`, is what lets it be marked
ready. One PR at a time then goes through these stages:

1. `pr-merge-readiness` runs the merge-readiness gate. A branch that is
   behind its base or conflicts with it goes to `issue-fixer` to
   rebase, and the gate runs again. A conflict the fixer cannot
   settle, or a required check that is not green, comes back as a
   question. A remedy that changed documentation gets a
   documentation loop over it before the gate runs again.
2. `pr-finalizer` posts the review detail on the PR and writes the
   run's final section into the PR body.
3. The PR's issues are set to In Review and the PR is marked ready for
   review.
4. Unless `merge-wait` is `skip`, `pr-monitor` polls the PR until it
   merges or closes. A PR that falls behind its base or into conflict
   while it waits goes back to the merge-readiness stage. One that sits
   unchanged for `merge-max-unchanged-polls` polls brings a question:
   whether to keep waiting.

   A poll that fails on a transient error is tried again after
   `merge-poll-error-retry-seconds`, without counting as an unchanged
   poll: a connection error, a timeout, a rate limit, or an HTTP 429
   or 5xx response. A poll that completes restarts the count of
   failures. One failure more than `merge-poll-error-max-retries` in a
   row ends the watch with that error. Any other failed poll ends it
   at once: a dropped connection says nothing about the PR, while an
   error such as a refused login would fail the same way on every
   retry.

### Cleanup and the summary

After the last PR's stages, `/sdlc:orchestrate-cleanup <PR>` runs for
each PR the run saw merge, asking nothing. It removes the worktrees of
the agents that worked on the PR, the PR's local branch once every
issue the branch names is closed, and the `.claude/tmp/` scratch of the
issues the PR closes, then brings the default branch up to date. A PR
the run did not see merge keeps all of them.

The run closes with a summary: the PRs that merged, those marked ready
and left unwatched under `merge-wait: skip`, those your pick at a loop
end left as drafts, anything that needs your attention, and the
batches still waiting on an earlier one. For each PR that reached
ready, its `In-loop Rebases` column counts the code loop's rebase
rounds, apart from `Readiness Remedies`, which counts only the
remedies the merge-readiness gate drove.

`/sdlc:orchestrate-cleanup --all` is for clearing up after many runs.
It lists every worktree under `.claude/worktrees/`, every agent
worktree's local branch, every issue branch whose issues are all
closed, all `.claude/tmp/` scratch and every other session's
scratchpad, asks for one go-ahead, and removes them. It deletes no
other local branch.

Neither form takes what a running agent may still use, because other
runs can be in flight in the same repository while a cleanup runs:

- A locked worktree is kept, and so is any branch a remaining worktree
  has checked out. Agents run in locked worktrees, so a lock is how
  cleanup tells that one may still be at work.
- A branch that names an open issue is kept, as is one naming an issue
  whose state cannot be read.
- While a locked worktree remains, `--all` removes no scratchpad and
  nothing under `.claude/tmp/`. The per-PR form holds back the PR's
  `.claude/tmp/` scratch only while one of the PR's own worktrees
  remains locked.

Each thing kept prints a `keep` line saying why, which is no failure.
The per-PR form, run from the session that spawned the PR's agents,
does remove their locked worktrees: that session runs it only once
every agent it spawned has returned.

With either form, `--stale-locks` also removes a locked worktree whose
agent's session is no longer running, `--dry-run` lists what would go
and removes nothing, and `--review-state` also deletes the review
state: the one PR's, or every PR's in the repository under `--all`. A
worktree locked for any other reason than an agent's run is kept
whatever the flags.

`/sdlc:orchestrate-analysis <PR>` reports where a run's wall-clock time
went and, per class of decision, how your picks compared with the
recommendations.

## What it does not do

- **It merges nothing.** A PR merges by your hand or by the
  repository's own auto-merge; the run watches for it.
- **`/sdlc:orchestrate` does not groom.** It stops on an issue that
  falls short of the readiness bar and names `/sdlc:orchestrate-ready`.
- **It does not make an unavailable issue available.** A closed issue,
  one an open PR already closes, one a local branch names, or one at a
  status the config does not allow is refused. Reopening it, closing
  the PR, deleting the branch and moving the status are yours.
- **It does not resume on a leftover branch.** An open issue is refused
  while a local branch an abandoned run left still names it, and
  cleanup keeps that branch, since it cannot tell an abandoned branch
  from one in use. Once no run is using it, delete it with
  `git branch -D <branch>` before the issue is run again.
- **It changes no other repository.** A fix that belongs in another
  repository, or to a PR that has left draft, is put to you.
- **The readiness check runs nothing from an issue body.** It runs no
  test, no linter and no command an issue names.
- **A review round writes nothing to the branch it reviews.** Every
  change to a branch is a commit by an implementing agent.
- **Cleanup touches nothing on `origin`.** It deletes no remote branch
  and pushes nothing, never removes the default branch, and refuses a
  PR of another repository. Its per-PR form runs only for a merged or
  closed PR.
- **Review state is not deleted for you.** It outlives the merge and
  goes only when you pass `--review-state`.
- **Under `merge-wait: skip` nothing watches a ready PR.** One that
  falls behind its base or into conflict afterwards is yours to remedy.

## Configuration

The config is YAML, in tiers. A higher tier wins per key, so a team
can commit a value to the shared file and one user can override it for
themselves. From lowest to highest:

| Tier | File | Tracked in git | Written by |
| --- | --- | --- | --- |
| Global user | `${XDG_CONFIG_HOME:-$HOME/.config}/sdlc/user-config.yml` | no | `/sdlc:sdlc-config-global` |
| Shared repo | `<repo-root>/.sdlc/repo-config.yml` | yes | `/sdlc:sdlc-config-repo` |
| Repo user | `<repo-root>/.sdlc/user-config.yml` | no, gitignored | `/sdlc:sdlc-config-user` |

A key set at no tier takes its default.

| Key | Values | Default | What it sets |
| --- | --- | --- | --- |
| `plan-confirm` | `ask`, `auto`, `auto-single-batch` | `auto-single-batch` | Whether the run waits for you to confirm the plan. `ask` always waits. `auto` waits only for a plan carrying a decision. `auto-single-batch` waits for that plan and for one of more than one batch. |
| `max-issues-per-batch` | positive integer | `8` | The most issues one batch holds. A larger grouping is split into more batches. |
| `seed-review` | `ask`, `accept-as-emitted`, `accept-recommended` | `accept-recommended` | How the seed theorem list is settled. `auto-accept` is a deprecated alias for `accept-as-emitted`. |
| `loop-end` | `ask`, `auto-when-clean` | `auto-when-clean` | Whether the end of the code loop waits for you. |
| `docs-loop-end` | `ask`, `auto-when-clean` | `auto-when-clean` | Whether the end of the documentation loop, before the PR is marked ready, waits for you. |
| `code-review-max-rounds` | positive integer, `unlimited` | `10` | The most review rounds the code loop runs per PR. |
| `docs-review-max-rounds` | positive integer, `unlimited` | `5` | The most review rounds the documentation loop runs per PR. |
| `merge-wait` | `monitor`, `skip` | `monitor` | Whether the run watches a ready PR until it merges. |
| `merge-poll-interval-seconds` | positive integer | `60` | The wait between two polls of a ready PR. |
| `merge-max-unchanged-polls` | positive integer | `720` | How many consecutive polls with no change pass before the run asks whether to keep waiting. |
| `merge-poll-error-retry-seconds` | positive integer | `30` | The wait before a poll that failed on a transient error is tried again. |
| `merge-poll-error-max-retries` | positive integer | `15` | How many consecutive polls failing on a transient error are retried before the next one ends the watch. |
| `ready-rewrite-approval` | `ask`, `auto` | `ask` | Whether grooming asks you to approve the acceptance criteria and the files-affected list before it rewrites the issue's body. |
| `orchestrate-statuses` | list of status names | `[Todo, Ready]` | The statuses an issue may be at for `/sdlc:orchestrate` to run on it. |
| `orchestrate-ready-statuses` | list of status names | `[Backlog, Todo, Ready]` | The statuses an issue may be at for `/sdlc:orchestrate-ready` to run on it. |
| `follow-up-issue-type` | `repo-default`, `ask`, a type name | `repo-default` | The type a follow-up issue you order is filed with. |
| `follow-up-issue-priority` | `repo-default`, `ask`, an option name | `repo-default` | Its priority. |
| `follow-up-issue-status` | `repo-default`, `ask`, an option name | `repo-default` | Its status. |
| `follow-up-issue-assignee` | `repo-default`, `ask`, `@me`, `none`, a login | `repo-default` | Its assignee. `none` files it unassigned. |
| `outside-criteria-finding` | `ask`, `fix-in-pr` | `fix-in-pr` | The standing ruling on a finding whose fix lies outside the issue's acceptance criteria. |
| `recurring-finding-class` | `ask`, `fix-class` | `fix-class` | The standing ruling on a class of finding filed on two consecutive rounds. |
| `reload-after-compact-token-budget` | integer, at least `64000` | `100000` | How much text the `reload-after-compact` hook appends after a compaction. |

- `auto-when-clean` skips the wait only for a clean end: a last round
  that approved with no open finding of any severity. A loop at its
  round cap, and one your ruling ended, still asks. Under `unlimited` a
  loop has no cap and runs until a round approves with no findings.
- A plan that does not wait says so, naming the value that let it
  through.
- A status list is replaced whole by a higher tier's, never merged with
  it. A status name is matched ignoring case, and a name the board
  lacks matches nothing. An issue with no status is refused. A
  repository that tracks no status skips the status check.
- A `follow-up-issue-*` key applies to a field your order named no
  value for. `repo-default` files the issue with the target
  repository's own default and asks nothing, except for a priority or
  status the target configures with no default, which is asked.

## Skills

The verbs you run:

| Skill | Purpose |
| --- | --- |
| `/sdlc:orchestrate-ready <issue>` | Groom one issue until the readiness check passes, then stamp the verdict on the issue and set its status. Interactive. |
| `/sdlc:orchestrate <issue>…` | Plan, implement, review and bring to merge one or more issues, refusing any that fails the readiness check. |
| `/sdlc:git-review-pr <PR> [--generator-effort <low\|medium\|high\|xhigh>] [--full] [--mode <mode>]` | Review one PR outside an orchestrate run. `--mode` is `code-and-instruction-markdown`, the default, or `documentation`. |
| `/sdlc:orchestrate-cleanup <PR> [--stale-locks] [--review-state] [--dry-run]` | Remove what one merged or closed PR left behind, keeping what a running agent may still use, then bring the default branch up to date. |
| `/sdlc:orchestrate-cleanup --all [--stale-locks] [--review-state] [--dry-run]` | Remove what every run left in the repository, keeping what a running agent may still use, after one go-ahead. |
| `/sdlc:orchestrate-analysis <PR>` | Report where one run's wall-clock time went, and how your picks compare with the recommendations per class of decision. |
| `/sdlc:sdlc-config-global` | Create or update the global user config. Interactive. |
| `/sdlc:sdlc-config-repo` | Create or update the shared repo config. Interactive. |
| `/sdlc:sdlc-config-user` | Create or update your repo user config, and keep it gitignored. Interactive. |

The skills the plugin's own agents and skills load, which are absent
from the `/` menu:

| Skill | Purpose |
| --- | --- |
| `sdlc:orchestrate-readiness` | The bar an issue meets before the orchestrator runs on it, the grammar of an issue body, and the check that refuses an unavailable issue or traces the body against the code, skipping or narrowing that grading when the issue's readiness stamp allows, and returns what the body is missing. |
| `sdlc:theorem-agents-interface` | What the parameters of a theorem agent's brief mean, and the classes a finding's consequence falls into. |
| `sdlc:agent-result-persist-interface` | What `sdlc-agent-result-persist` does: its modes, flags, paths and record grammar. |
| `sdlc:pr-read-cli-interface` | What the PR-read executables take, print and exit with. |

## Agents

| Agent | Purpose |
| --- | --- |
| `issue-developer` | Implements one batch of issues on one branch and opens its draft PR. |
| `issue-fixer` | Applies a round's findings to an open PR's branch, or rebases it onto its base, with the conflicts resolved or escalated: in a rebase round of the code loop, or as a merge-readiness remedy. |
| `code-documenter` | Corrects the comments in the files a round changed, before its review. |
| `style-checker` | Reports a round's style-guide violations: in code and instruction Markdown in the code loop, in documentation in the documentation loop. |
| `docs-writer` | Writes a PR's documentation in the documentation loop and fixes what that loop's rounds find in it; for a batch with no code to implement, also creates the branch and opens the PR. |
| `pr-merge-readiness` | Drives one PR through the merge-readiness gate, sending a branch that is behind or in conflict to `issue-fixer`, and returns a state that needs a ruling as a question. |
| `pr-finalizer` | Posts the run's review detail on a finished PR and writes the run's final section into its body. |
| `pr-monitor` | Watches one ready PR until it merges, closes unmerged, falls behind or into conflict, or sits unchanged long enough to ask whether to keep waiting. |
| `theorem-based-pr-reviewer` | Reviews one PR, spawning the generator, the assessor, the disprovers and the verifiers; before a batch's PR exists, seeds its theorem list from the issues. |
| `theorem-generator` | Searches one PR, or before one exists the issues a batch will close, for claims worth trying to disprove. |
| `theorem-assessor` | Assesses one generated theorem list against the issues, recommending an action per theorem and a theorem for each criterion none tests. |
| `theorem-disprover` | Tries to break exactly one theorem. |
| `counterexample-verifier` | Tries to reject exactly one disprover's counterexample. |

Every agent but `pr-merge-readiness` and `pr-monitor` runs in a
throwaway worktree under `.claude/worktrees/`, locked while the agent
runs. Those worktrees stay in place during a run and are removed by
the cleanup.

`issue-developer`, `issue-fixer`, `code-documenter`, `style-checker`
and `docs-writer` declare `memory: project`, so with memory turned on
in Claude Code each reads and writes its own entries under
`.claude/agent-memory/` in its worktree. The plugin commits none of
them and copies none out, so an entry is removed with the worktree
unless something outside the plugin recorded it.

`theorem-generator` runs at a reasoning tier the reviewer picks per
round. You can name one yourself: `--generator-effort` on
`/sdlc:git-review-pr`, or a tier you state during an orchestrate run,
which then holds for the whole batch.

## Executables

Each is callable by bare name once the plugin is enabled.

| Executable | Purpose |
| --- | --- |
| `sdlc-agent-result-persist` | Writes and reads the review pipeline's state, and derives from it where a round stands, each theorem's disposition and severity, the verdicts and the posted review. |
| `sdlc-decision` | Checks and stores a decision record and prints its question, stores your answer, prints a record or its question again, and reports whether a design question still waits on you. |
| `sdlc-readiness-check` | Refuses an issue that is closed, closed by an open PR, named by a local branch or at a status not allowed; otherwise grades the mechanical acceptance bullets of its body against the tree and prints one line per gap. |
| `sdlc-readiness-stamp` | `check` reads an issue's readiness stamp and prints whether a re-check can be skipped, narrowed to a diff, or has to run in full; `write` records a `ready` verdict as the stamp, refusing unless the working tree is clean and at the tip of the default branch. |
| `sdlc-orchestrate-cleanup` | Removes worktrees, local branches and scratch for one merged or closed PR, or for the whole repository, keeping what a running agent may still use, then brings the default branch up to date. |
| `sdlc-orchestrate-analysis` | Prints the time report and the per-class decisions table behind `/sdlc:orchestrate-analysis`. Writes nothing. |
| `sdlc-pr-monitor` | Polls one ready PR until it merges, closes unmerged, falls behind or into conflict, or sits unchanged for the configured number of polls, retrying a poll that fails on a transient error. Changes nothing on GitHub or in the repository; its one write is a temporary file it removes on exit. |
| `sdlc-pr-round` | Prints the number of the review round under way on a PR. |
| `sdlc-pr-adjustments` | Prints the comments posted on a PR since the previous round, less the plugin's own. |
| `sdlc-fixer-brief` | Prints a PR's most recent comment when it is a fixer brief; with `--all`, every brief the PR carries. |
| `sdlc-records-chain` | Reports each complete chain of review-detail comments posted on a PR, and the rounds it holds. |
| `sdlc-pr-post-theorem-records` | Posts a PR's review detail as a chain of comments, each within GitHub's comment size limit, covering the rounds no earlier chain holds. |
| `sdlc-pr-body` | Splits a PR body file around the final section, and joins the parts back into one file. |
| `sdlc-extract-lines` | Copies a line range of one file, verbatim, into another. |

## Hooks

| Hook | What it does |
| --- | --- |
| `orchestrate-status` | Draws the status line of an `/sdlc:orchestrate` run under the prompt, and registers `/orchestrate-status [on\|off]`, which hides or restores the line and with no argument flips it. |
| `reload-after-compact` | After a compaction, in an orchestrate run or outside one, appends one message holding the full text of the skills the conversation invoked and of the rule files it read, within `reload-after-compact-token-budget`, replacing any earlier such message. The message shows as one summary line. |

## Files it writes

In the repository: each batch's branch and its commits, pushed to
`origin`; agent worktrees under `.claude/worktrees/`; scratch under
`.claude/tmp/`; and the repo tiers' config files, when you run their
verbs.

On GitHub: each draft PR, its reviews, the fixer-brief, adjustments
and review-detail comments on it, the final section of its body, the
status and assignee of its issues, and the readiness stamp, one comment
on each issue a check found ready.

Outside every repository, the review state. With `<repo-dir>` for
`${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/<host>/<owner>/<repo>` and
`<round-dir>` for `<repo-dir>/pr<pr>/round<round>`:

| File | What it holds |
| --- | --- |
| `<repo-dir>/repo.yml` | The host, owner and name of the repository the directory is for. |
| `<round-dir>/log` | The round's log: when each agent of the round started and finished, and the commit the round reviewed. |
| `<round-dir>/<theorem>-<agent>` | One agent's full report. |
| `<round-dir>/records` | The round's theorem records, which the next round carries forward. Round 0's is the settled seed list. |
| `<round-dir>/review` | The round's full review, of which the review posted on the PR is a summary. |
| `<round-dir>.voided-<instant>/` | The whole directory of a round whose branch moved under it, set aside. |
| `<repo-dir>/pr<pr>/agents` | One record per agent spawned for the PR, which is how the cleanup finds the PR's worktrees. |
| `<repo-dir>/pr<pr>/decisions/<n>/` | One decision put to you about the PR: the record, the question as printed, a log of what was asked and picked, and your replies verbatim. |
| `<repo-dir>/issue<N>/decisions/<n>/` | The same, for a decision asked before a PR exists: a grooming session's, or a batch's before its PR is open. |

A PR's directory is kept through the merge and is deleted only by
`/sdlc:orchestrate-cleanup --review-state`. No command of this plugin
removes an `issue<N>/` directory.

Also outside every repository:

- The global user config, when you run `/sdlc:sdlc-config-global`.
- `${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/reload-after-compact/<session>/<loop>.json`,
  the `reload-after-compact` hook's record of what each conversation
  loaded. No command of this plugin removes these files.
- Staging files in the session's scratchpad, which go with the
  session.

## Where it finds Claude Code's own files

Claude Code keeps the global `CLAUDE.md`, your rules and skills, the
installed plugins and the session transcripts in its config directory.
The plugin takes that directory to be `CLAUDE_CONFIG_DIR` when the
variable is set and not empty, and `$HOME/.claude` otherwise. A session
started under another account's config directory therefore gets that
account's rules, skills and plugins, and a session with the variable
unset finds everything where it always was.

| What looks | What it finds there |
| --- | --- |
| Every agent | The global `CLAUDE.md`, which it reads before anything else. |
| `reload-after-compact` | A skill invoked without a plugin prefix, under `skills/`, after the project's own `.claude/skills/`; the installed plugins, through `plugins/installed_plugins.json` and `plugins/cache/`. It reloads no file under `rules/`, since Claude Code restores those itself. |
| `sdlc-agent-result-persist` | The transcript of each review agent, under `projects/`, whose path it records in the round's log. |

An agent does not work the directory out itself: it runs `claude-home`,
which `cc-tools` puts on `PATH`, and reads `CLAUDE.md` in the directory
that prints, so no agent spells the rule for choosing the directory.
`reload-after-compact` and `sdlc-agent-result-persist` do not run
`claude-home`: each applies the same rule in its own code, and their
tests and the prose describing them spell it again. A change to the rule is
therefore made in `claude-home` and in every file of this plugin that
spells it. Each of those names `CLAUDE_CONFIG_DIR`, so a search of the
plugin for that name finds them all.

## Dependencies

| Plugin | What sdlc uses from it |
| --- | --- |
| `issues` | The issue verbs, `issue-view` for the readiness check, and `issue-comment` for the readiness stamp. Version 0.20.0 or later, the first whose `issue-comment` takes `--marker`. |
| `git-tools` | Branch creation, branch sync, the branch-name grammar and the default-branch lookup. |
| `github-prs` | Every PR read and write. |
| `cc-tools` | `claude-home`, which prints Claude Code's config directory. Version 0.12.0 or later, the first with `claude-home`. |

`yq`, the mikefarah build at v4 or later, comes with no plugin and is
installed on the machine. Without it `sdlc-decision` exits with an
error in place of asking a question.
