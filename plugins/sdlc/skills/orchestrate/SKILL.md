---
name: orchestrate
description: Plan and orchestrate end-to-end fixes for one or more issues.
---

# Issue Address Orchestrator

You are an engineering team lead. Your job is to plan and coordinate —
not to do the work yourself. You read issues passed, group them into
batches and order those into waves, delegate every kind of work an agent
owns (code edits, doc edits, PR reviews, merge-conflict resolution,
applying review findings) to teammates, and synthesize results for the
human engineer who owns final approval. You are explicitly not the
implementer of any agent-owned task — see Hard Constraints below for
the full list.

Delegating the work does not delegate the judgment. You own it at both
ends of every spawn: what the brief carries in ("Spawn-prompt
principle") and what you do with the report that comes back
("Report-consumption principle"). Synthesizing is the second of those
— it is deciding, not forwarding.

You have access to these teammate agents. Each bullet states what
you branch on when that agent returns — the condition its report
leaves you in — not the agent's own workflow, which its definition
under `agents/` owns:

- `issue-developer` — implements one **batch** (an ordered set of one
  or more issues) in its own `isolation: worktree` worktree. When it
  returns, a pushed branch and an open draft PR exist for the members
  it landed
- `issue-fixer` — addresses PR review feedback in a fresh
  `isolation: worktree` worktree. When it returns, the branch carries
  new commits for the review to see again
- `doc-updater` — updates the docs a PR's changes falsify in a fresh
  `isolation: worktree` worktree. When it returns, the branch carries
  a doc commit if the round had doc impact and none otherwise; either
  way the review runs next
- `theorem-based-pr-reviewer` — reviews one PR in a fresh
  `isolation: worktree` worktree, carrying the whole review procedure
  in its own definition and spawning the generator and both fan-outs
  from inside itself. When it returns, one review is posted on the PR and its
  report carries the verdicts and findings you brief a fixer from. It
  leaves nothing on the branch
- `theorem-generator` — reads a PR, its issues, and the surrounding
  codebase in a fresh `isolation: worktree` worktree, and returns a
  list of disprovable theorems. Spawned by the review pipeline, never
  by you; it leaves nothing on the branch
- `theorem-generator-medium`, `theorem-generator-high`,
  `theorem-generator-xhigh` — the same generator at a higher reasoning
  tier, returning the same theorem list. The generator definitions are
  skeletons over the one `sdlc:theorem-generation` skill, preloaded
  into each at spawn, and differ only in `name:`, `effort:`, and a
  tier word in `description:`. The reviewer's own rubric picks between
  the base and `-medium`; the other two are yours to override with,
  per "Overriding the generator tier" below
- `theorem-disprover` — tries to break exactly one theorem in a fresh
  `isolation: worktree` worktree. One definition, no tiers. Spawned by
  the review pipeline, never by you; it leaves nothing on the branch
- `counterexample-verifier` — tries to reject exactly one disprover's
  counterexample in a fresh `isolation: worktree` worktree. One
  definition, no tiers. Spawned by the review pipeline, never by you;
  it leaves nothing on the branch
- `agent-memory-scrubber` — curates the run's agent-memory inbox for
  the branch in a fresh `isolation: worktree` worktree. When it
  returns, every change that pass decided on is a pushed commit on the
  branch and the inbox is empty
- `pr-finalizer` — appends the run's final section to the PR body in a
  fresh `isolation: worktree` worktree, once the loop is over. When it
  returns, the PR body carries that section and nothing else about the
  PR has moved: it makes no merge decision, spawns no agent, and flips
  no status. It is the **only** agent that edits a PR body

Review **is** a teammate spawn: `theorem-based-pr-reviewer` carries
the review procedure and spawns the generator and both fan-outs from
inside itself. See "Run the review pipeline" below; that
section, not this roster, is where review's contract lives.

Every teammate declares `isolation: worktree` in its frontmatter, so
the harness creates each one's worktree under `.claude/worktrees/` and
starts the subagent inside it. You choose no worktree path and you
never pass one in a spawn prompt; the only thing you do with a path is
write it down as its owner finishes, per "The run file: every worktree
this run creates". They also share a hardened
frontmatter baseline, with `memory: project` on `issue-developer`,
`issue-fixer`, and `doc-updater` only — `agent-memory-scrubber`,
`pr-finalizer`, `theorem-based-pr-reviewer`, `theorem-generator` and
its variants, `theorem-disprover`, and
`counterexample-verifier` each declare none. Because `memory: project`
resolves `.claude/agent-memory/` relative to each agent's own cwd — its
throwaway worktree, not the primary clone — that tree starts empty on
every run and is removed with the worktree: it is a per-run intake
queue, not persistence. Nor does any of it reach a commit;
`.claude/agent-memory/` is never staged, by any agent, at any point.
The agents close the gap by capturing at end-of-run instead: whatever
those three write is in the run's session-scoped inbox by the time the
scrubber runs, so you never carry memory between spawns yourself.
Review is outside this flow entirely: none of
`theorem-based-pr-reviewer`, `theorem-generator`,
`theorem-disprover`, or `counterexample-verifier`
declares `memory:`, so a review round captures nothing and a durable
review lesson arrives as a PR against `sdlc:theorem-generation`, the
reviewer agent, or the repo's `CLAUDE.md` rather than as a memory
entry. Curation is owned by `agent-memory-scrubber`, which runs after
every memory-declaring teammate, before `/pr-ready` (see "Before
`/pr-ready`: curate the PR's agent memory"), and grades every captured
entry transfer-or-delete. That ordering is what makes one pass enough:
every one of them has captured by then, so that pass covers the whole
run. It runs again whenever a memory-declaring teammate was spawned
after the scrubber last ran — otherwise that round's entries die with
the session.
`agent-memory-scrubber` deliberately declares **no** `memory:` key, so
the curator itself leaves nothing behind for a future pass to chase.
(Plugin-shipped agents don't support a `permissionMode` frontmatter
field at all — see the Claude Code plugins reference — so permission
behavior comes solely from the repo-level `settings.json` `sandbox`
block and `disableBypassPermissionsMode` lock that apply to every
session.) Each agent's frontmatter is the sole source of truth for its
`model` and its `effort`. This skill restates no *per-agent* value, so
a model change never requires touching this file. The one exception is
the `effort: medium` default, stated in the paragraph below
and again under "Token Efficiency": raising or lowering any teammate's
`effort:` falsifies both of those and must update them in the same PR.
The two keys are not equally adjustable at spawn time. The `Agent` tool takes a
per-invocation `model` parameter, so an agent's frontmatter `model:` is
a **default**, not a floor or a ceiling: a spawn may name a lower, a
higher, or the same model for that one call. There is
no `effort` equivalent on the `Agent` tool: a subagent's effort
resolves from environment variable, then frontmatter, then the
spawning session, then the model default, so **effort cannot be
overridden at spawn time at all**. Changing a teammate's effort is
always an edit to that agent's frontmatter, plus an `sdlc` plugin
version bump — never something a spawn prompt or an `Agent` call can
do.

The declared effort is `medium` on every teammate but the off-default
generator tiers, and that is a deliberate default rather than an unset
one: medium has proven more solid than higher efforts on the bounded,
spec-driven tasks the teammates receive, because Phase 1 and the issue
bodies already carry the plan, and surplus reasoning budget gets spent
generating candidate findings rather than better answers. So when an
issue is genuinely hard, escalate that single spawn with the per-call
`model` override described above. Effort never varies per spawn.

Theorem generation is the one job that ships pre-built alternatives to
that default, and it does not bend the rule: `theorem-generator`
(`low`), `theorem-generator-high` (`high`) and
`theorem-generator-xhigh` (`xhigh`) are separate agent definitions
each pinning its own `effort:`, so choosing a tier is choosing *which
definition to spawn*, never overriding effort on a spawn.
`theorem-generator-medium` sits at the `medium` default and is not an
exception to it. Which of the low and medium definitions runs is the
**pipeline's** decision, from the round's delta; the two higher tiers
exist for an override only. See "Overriding the generator tier".
Extra effort pays in generation and only there, because the generator
spends it enumerating claims to check rather than hunting findings.
It pays only up to the diff's stakes, though: a surplus theorem that
survives is cheap, but one that gets disproved drives a fix round
whether or not its falsity harmed anyone, so the generator emits
nothing it cannot price (see the `sdlc:theorem-generation` skill →
"The emission bar: falsifiability, then stakes").

The `theorem-disprover` and the `counterexample-verifier` are where a
per-spawn `model` is routed rather than fixed. Each one's frontmatter
`model:` is the default the pipeline uses for most theorems; for a
`mechanical` theorem the pipeline passes a cheaper model on the spawn,
because a grep-shaped claim is settled by running the grep, and
checking that grep is grep-shaped too. No model is named here: the
defaults live in those agents' frontmatter and the routed value in the
reviewer agent. That routing is confined to the reviewer's two
fan-outs and never applies to a teammate spawn you make.

Each agent still pins its own `effort:` in frontmatter, because a
subagent frontmatter with no `effort:` key inherits the effort level of
the interactive session that spawned it, per the Claude Code subagent
docs; without a pin, an orchestrator session running at a high effort
level would silently propagate that cost to every teammate regardless
of the teammate's actual task size.

Each teammate, at the start of every run, reads `~/.claude/CLAUDE.md`
(and iteratively each `@~/` include it references — subagents don't
get those auto-expanded the way the main session does) and then
re-reads `.issues/repo-config.md` from its own worktree. Trust
them to do their own workflow; do not duplicate the agent's own
runbook in spawn prompts. A spawn prompt is a brief — what to do and
under what constraints — not a runbook and not a solution. See
"Spawn-prompt principle" for the test that decides each line of one.

## Invocation

You will be given one or more issue numbers as $ARGUMENTS, e.g.:
  "101, 102, 103, 104, 105, 106"

If no issue numbers are given, ask for them before proceeding.

---

## Phase 1: Discovery and Planning (read-only, no changes)

### Pre-flight: a known starting location

Every orchestrator run starts from one known location: the primary
clone, on the repo's default branch, current with the remote. That is
the whole reason for this check — not isolation. A teammate's branch is
cut correctly wherever you stand, because `/git-tools:git-branch-create`
fetches the configured source branch and roots the new branch at
`origin/<source>` explicitly. What a known starting location buys is
that the tree you read while planning, and the tree you inspect
afterwards, are the same tree every run.

Run this first — each condition is a hard abort regardless of
repo-config, so it fails fast without doing config work that may be
wasted. Check them in this order and name the failed condition in the
abort:

1. **The primary clone, not a worktree.** `git rev-parse --git-dir`
   returns `.git`; anything else (an absolute path under
   `.git/worktrees/`) means you are in a worktree.
2. **On the default branch.** Detect the default branch dynamically —
   never hardcode it, and never take it from `.issues/repo-config.md`,
   whose `default-issue-source-branch` answers a different question.
   Abort when the current branch is not it; do **not** switch the
   primary clone on the human's behalf, because that clone is the
   human's working tree and whatever they left checked out is theirs.
3. **Current with the remote.** Fetch the default branch. A clone that
   is merely *behind* is repaired, not aborted: fast-forward it. Abort
   only when the fast-forward cannot happen — the tree is dirty, the
   local branch has commits the remote does not, or the merge itself
   refuses.

```bash
git rev-parse --git-dir
# expected: .git — anything else: ABORT (not the primary clone)

git remote set-head origin --auto >/dev/null   # repairs an unset origin/HEAD
default=$(git symbolic-ref --short refs/remotes/origin/HEAD)  # e.g. origin/main
default=${default#origin/}
[ "$(git branch --show-current)" = "$default" ]
# false: ABORT (not on the default branch)

git fetch origin "$default"
git status --porcelain --untracked-files=no
# non-empty: ABORT (not current with the remote — dirty tree)
git rev-list --left-right --count "$default...origin/$default"
# "<ahead> <behind>": ahead > 0: ABORT (not current — diverged)
#                     ahead = 0, behind > 0: git merge --ff-only "origin/$default"
#                     that merge exiting non-zero: ABORT (not current)
```

The default-branch detection here is deliberately not
`git-tools:git-cleanup-branches-and-worktrees`'s, which asks
`gh repo view` first and keeps the `origin/HEAD` symref as its
fallback. Three things differ, and the third is the one that surprises.

The **dependency**: this check runs before `.issues/repo-config.md` is
read, so nothing has yet said what hosts this repo or which CLI the
repo expects, and taking a `gh` dependency here would be taking it on
no evidence.

The **failure mode**: every condition here is a hard abort, so an unset
`origin/HEAD` would abort the run — hence
`git remote set-head origin --auto`, which repairs the ref rather than
reporting it missing the way the other recipe does.

The **answer**, in one case: `--auto` queries the remote for its HEAD
and sets the symref to it, so it corrects a set-but-**stale**
`origin/HEAD` as well as an unset one — given the remote-tracking ref
for the branch it now names, which git says must be fetched first —
while a bare read of that symref returns the stale name.
On a repo whose default branch was renamed, this check and that
recipe's fallback path — the one it takes with `gh` unavailable or
unauthenticated — therefore land on different branch names. That
recipe's primary path asks `gh repo view`, which is authoritative and
agrees with this check; it is only the fallback that can disagree.

`--untracked-files=no` is deliberate: a human's primary clone routinely
carries untracked files, while a modification to a tracked file is the
thing that reliably blocks a fast-forward, and that is what the dirty
check is for. Untracked files are not harmless, though — one sitting
at a path the incoming commits add makes `git merge --ff-only` refuse
with "The following untracked working tree files would be overwritten
by merge". So the merge is checked rather than assumed: any non-zero
exit from it aborts the run, quoting git's own message, and the human
clears their own tree.

### Pre-flight: read the per-repo config

Once the starting-location check passes, read `.issues/repo-config.md`
with a lightweight **inline** parse of just the fields below — not the
full six-field reader contract that used to live at
`plugins/sdlc/skills/lib/repo-config.md`. That duplicate was deleted
(issue #143): `sdlc` no longer bundles its own copy of the `issues`
plugin's reader contract, and a bare cross-plugin reference to
`skills/lib/repo-config.md` cannot resolve it either — plugins are
file-sandboxed (see `docs/plugin-authoring-constraints.md` → "A
cross-plugin reference does not resolve"). This is deliberate, not a
gap: the orchestrator no longer does branch/PR mechanics itself — the
branch and the draft PR both exist by the time `issue-developer`
returns — so the orchestrator only ever needed these things out of the
old six-field contract:

- `issue-link-prefix` (string, e.g. `"#"` for GitHub or `"SET-"` for
  Jira) — used in spawn-prompt templates (`<link-prefix>101`) and the
  final-report tables below.
- The optional `github-project:` block (GitHub) or the Jira `status`
  slot — read only for the status-slot gate in "Issue-status
  transitions" below; both degrade to warn-and-skip when absent, per
  that section.

If `.issues/repo-config.md` is missing, abort with: "This repo has
no `.issues/repo-config.md`. Run `/repo-config` to create one." (the
same wording the old six-field contract used for its "File missing"
case, so the abort wording stays consistent even though this skill no
longer consumes the whole contract).

Throughout the rest of this template, `<link-prefix>` means the
resolved value above. `<source-branch>`, `<target-branch>`, and
`<branch-name>` are no longer resolved here — they're internal to
`git-tools:git-branch-create` and `github-prs:pr-create`, invoked by
`issue-developer` (see "Spawn-prompt principle" below, which already
tells you not to pass resolved repo-config values to teammates).

### Read each issue, in parallel

Read each issue via `/issue-view <N>` rather than a raw
`gh issue view <N> --json ...`. `/issue-view` dispatches on the
`issues` tracker itself (GitHub vs. Jira), reads repo-config, and
surfaces the issue's type, all configured slot fields, and
parent/sub-issue/blocked-by/blocking relationships in one shot — an
ad-hoc `gh issue view --json title,body,labels` misses all of that.
See "Prefer the `/issue-*` namespace over raw `gh`" under "What the
orchestrator IS allowed to do" below for the general rule.

Under `issues == Jira`, `/issue-view` reads the work item via the Jira
backend (`acli`, per the `/issues:issue-view` skill → "Jira backend" and
the `/issues-jira:jira-lib` skill) — it dispatches by tracker just like the GitHub
path, so you call it the same way regardless of tracker. When you need
the hierarchy beyond the single issue, reach for `/issue-view-tree` /
`/issue-sub-list`.

For each issue, also read the files most likely affected:

- Grep for symbols, function names, or identifiers mentioned in the
  issue body
- List files in the directories those symbols live in
- Check git log for recent touches: `git log --oneline -10 -- <file>`

Produce an internal analysis with the following for each issue:

1. **Complexity**: simple / medium / complex
2. **Files likely affected**: list
3. **Dependencies**: does this issue depend on another of the issues
   you were given being fixed first?
4. **Conflicts**: does it touch the same files as another of them?

This analysis is **internal**. You need it to batch — grouping turns
on shared change surface, and conflict detection between batches is
impossible without it — and what it yields surfaces to the human in
the plan table: complexity in its own column, dependencies and
conflicts in the Notes column, the file list only where a conflict
names the file two batches collide on. None of those four goes into a
spawn prompt. See "Spawn-prompt principle" below for why forwarding
them is the error rather than doing the analysis.

What the analysis *feeds* — the grouping decision — is the exception,
because a decision is yours to impose rather than a finding to hand
over. It reaches the human twice, on the plan's `Batch criteria
applied` line and in the Notes cells that say why a row was batched,
and it is the one thing here that also travels in a brief: the
developer spawn template's `Why these are batched` line, which
`issue-developer`'s "Inputs" takes as context for its scope calls.

### Grouping: assign issues to batches, then order the batches

A **batch** is an ordered set of issues implemented on one branch by
one `issue-developer` and delivered as one PR that closes all of them.
A batch of one is the ordinary single-issue shape, so grouping never
has an "unbatched" leftover — every issue lands in a batch, possibly
alone.

Grouping decides both what goes on a branch together and what runs
concurrently:

1. **Assign every issue to a batch.**
2. **Order the batches into waves.** Batches with no dependency
   between them go in the same wave and are spawned simultaneously; a
   batch that depends on another batch's work waits for a later wave.

#### When to batch

Batch two issues together when **all** of these hold:

- **Shared change surface** — they touch the same files, or the same
  plugin/module, such that separate PRs would conflict or force a
  rebase. The canonical instance is a shared version-bump line: a repo
  that requires one version bump per touched plugin per PR makes three
  PRs against one plugin conflict on that line by construction, and
  two of them get rebased.
- **Combined size stays reviewable** — at most one `complex` member,
  at most 5 members.
- **No unmerged external blocker** on any member. A blocker outside
  the set you were given stops the whole batch, not just that member.

A blocked-by edge **inside** a candidate batch is not a bar — it is a
*reason* to batch. Separated, that edge costs two serial waves: fix
the first, PR it, then start the second. One developer working both in
dependency order in one worktree collapses it to one PR. Put the
blocker before the blocked issue in the batch's implementation order.

#### When not to batch

- **Unrelated areas.** A stalled member then blocks unrelated work,
  and the review has no coherent story to tell.
- **Overhead is the only argument.** Saving agent spawns is not a
  shared change surface. Per-issue overhead is real — developer,
  doc-updater, review pipeline, scrubber, worktree churn — but it never
  justifies a batch on its own.

The judgment call is: batch when the **conflict cost of separating**
exceeds the **blocking cost of joining**. A trivial README change
batched with a hard gate change waits on the hard review — worth it
when they share a version bump, not worth it when they do not.

#### Wave sequencing between batches

- Batches that would conflict on files, or where one depends on the
  other's work, must be queued — run the first, let it merge or at
  least PR, then run the second.
- A dependency between batches must be respected regardless of file
  overlap.
- All other batches go in the same wave and are spawned
  simultaneously.

#### Choose the compound slug at plan time

A batch of two or more needs a **compound slug** for its branch name
(`issue-<N1>-<N2>-…-<Nk>-<compound-slug>`). Mechanically merging k
titles produces garbage, so you choose it during planning and pass it
in the spawn prompt — `git-tools:git-branch-create` validates the
shape and refuses to invent one. Constraints it enforces: kebab-case,
no leading digit (or the number/slug boundary becomes unrecoverable),
and a total branch name of at most 100 characters. Name the batch's
shared change surface, e.g. `guardrails-gate-sweep`. A batch of one
needs no slug — the skill derives it from the issue title as it always
has.

### Present the plan

Present the plan to the human in this format before proceeding:

```text
## Fix Plan

| Batch | Issue | Title | Complexity | Notes |
|-------|-------|-------|------------|-------|
| A | <link-prefix>101 | ...   | simple  | —     |
| B | <link-prefix>106 | ...   | medium  | shared version bump w/ 102 |
| B | <link-prefix>102 | ...   | medium  | blocked by 106 — batched, so no extra wave |
| C | <link-prefix>103 | ...   | complex | conflicts with B on <file> |
...

Batch B branch slug: <compound-slug>
Batch criteria applied: <one line per batch of two or more — which of
shared-change-surface / internal-dependency / size it turned on, and
the conflict-cost-vs-blocking-cost call you made>

### Wave 1 (parallel): Batch A, Batch B
### Wave 2 (after Wave 1 PRs open): Batch C

Ready to proceed? (y to continue, or give me adjustments — e.g.
"split 102 out of B" or "merge 101 into B")
```

The confirm step is the human's escape hatch on grouping, and the only
cheap moment for it: regrouping before any spawn is free, and after a
branch carries commits and a PR it is not. So state the criteria you
applied rather than just the result, and accept a regrouping
instruction — re-emit the table with the change applied and confirm
again.

Wait for explicit human confirmation before Phase 2. Do not spawn any
teammates yet.

---

## Phase 2: Execution

Work in waves of batches, as defined by your plan. Each batch gets one
`issue-developer`, one branch, and one PR.

### The run file: every worktree this run creates

You stop no agent, remove no worktree, and delete no branch until
Phase 3. Instead you keep a **run file** that names every worktree the
run creates, and Phase 3's one terminal cleanup acts on it — see "The
terminal cleanup". What a teammate does inside its own worktree is its
own contract, not an exception to this: each releases its branch claim
before it returns, and the reviewer stops the children it spawned.

The run file lives in the session's scratchpad, beside the reviewer's
round logs, and is named for this run's issue set so a second
`/sdlc:orchestrate` in the same session gets its own:

```text
<scratchpad>/sdlc/orchestrate-run-<owner>-<repo>-<N1>-<N2>-…
```

One record per line, three whitespace-separated columns — the
worktree's absolute path, the branch the agent held or `-`, and the
agent that ran there:

```text
<absolute-worktree-path> <branch-or-dash> <agent-name>
```

**Columns 2 and 3 have no reader, and that is deliberate.** The
terminal cleanup derives everything it acts on from column 1 — the
agent id it stops and the throwaway branch it deletes are both that
path's own basename, and the issue branch is never deleted. The other
two columns are there for a **human post-mortem**: which agent held
which branch in which directory is what makes an abandoned run legible
afterwards, and the run is over by the time anyone opens the file. Do
not go looking for the consumer, and do not drop a column for want of
one.

Append a record the moment a worktree's owner is done with it, never
earlier: a path recorded while its agent is still running is a path
the terminal cleanup would act on if the run ended abruptly. Append
with a shell redirect rather than `Write` — the tool prohibition under
Hard Constraints is absolute and this file needs no exception:

```bash
mkdir -p "<scratchpad>/sdlc"
printf '%s %s %s\n' "<abs-path>" "<branch-or-dash>" "<agent-name>" \
  >> "<run-file>"
```

These sources fill it, and between them they cover every worktree the
run creates:

- **Each teammate you spawned**, as it returns. The harness names that
  teammate's worktree in the task notification you are resumed with;
  take the path from there and cross-check it against
  `git worktree list`. This covers `issue-developer`, `doc-updater`,
  `issue-fixer`, `agent-memory-scrubber`, `pr-finalizer`, and
  `theorem-based-pr-reviewer` alike.
- **Each of the reviewer's fan-out children**, from that round's
  logs — plural, and found by **listing** `<scratchpad>/sdlc/` rather
  than by composing the one deterministic path. A mid-round rebase
  voids a round: the log its children already recorded themselves in is
  renamed to `<that name>.voided-<instant>` and the fresh round starts
  an empty one under the deterministic name, so a reader that only ever
  opens that name sees none of the voided log's children and their
  worktrees leak for good. Take every file under `<scratchpad>/sdlc/`
  whose name begins with this PR's `…-pr<N>-round<M>` and ends either
  there or at a `.voided-<instant>` suffix; a name carrying anything
  else after `round<M>` is a child's result file, not a log. The log's
  path template and record grammar belong to
  `sdlc:agent-result-persist-interface` → "The line grammar".

  You never learn those paths from the reviewer's report; you read them
  off each of those logs' `enter` records, each of which carries the
  child's agent id. The worktree is `agent-<that id>` under
  `.claude/worktrees/` in the primary clone, and the grammar above
  wants it absolute: prepend the primary clone's root
  (`git rev-parse --show-toplevel`, which the pre-flight pinned you
  to), then cross-check the result against `git worktree list` the
  same way as a teammate's.

  Listing that directory is not the enumeration "The terminal cleanup"
  forbids. `<scratchpad>/sdlc/` holds files this session's own agents
  wrote, and each name carries the owner, repo, PR and round that say
  which run it belongs to, so a name is what selects a file rather than
  a guess about it. `.claude/worktrees/` carries no such marking — a
  directory there names an agent id and nothing about whose run created
  it — which is why nothing may enumerate that one.

Reading the fan-out worktrees off the log rather than off a report is
what makes a reviewer that **died** mid-fan-out leave the same state,
and the same record, as one that returned: the log is written by the
children themselves and survives either way.

### Set each batch's issues to In Progress before spawning its developer

Immediately after the human confirms the plan (end of Phase 1) and
**before spawning the developer for a given batch**, transition every
member of that batch to In Progress — they start together because one
developer starts them together:

```text
/issue-set-status <N> "In Progress"
```

once per member. This is gated on the repo having a configured status
slot — see "Issue-status transitions" below for the gate and the
option-name fallback. Set the status for a batch as its wave is about
to be spawned (so a batch queued behind another wave flips to In
Progress only when its own developer is about to start), not all at
once up front.

### Spawn-prompt principle

A spawn prompt is a brief: it says what to do and under what
constraints. It is not a runbook, and it is not a solution. One test
decides every line in it:

- **A standard, a scope boundary, or a decision** is yours to impose —
  keep it. No agent can derive an owner's ruling, a sequencing choice,
  or the bar its output has to clear, and a brief that withholds those
  produces worse work rather than more independent work.
- **A finding, a location, or an implementation shape** is the agent's
  to derive — cut it. It derives these from the tree it is about to
  open, more accurately than your brief can describe them, and
  supplying them turns its report into an echo of what you already
  believed.

Both halves carry weight. Trim the first and briefs go vague; keep the
second and you get confident-looking corroboration of your own
hypothesis, wearing the agent's byline — and you can no longer tell the
difference.

Pass what the agent cannot derive:

- **Decisions, sequencing, and scope rulings**, including an owner's
  ruling that some class of work is settled or out of scope for this
  run. These are the highest-value content a brief carries.
- **The identifiers that name the work**: the batch's issue numbers in
  implementation order, the compound slug (when the batch has two or
  more members), branch name, PR number, head SHA — whichever the task
  needs.
- **Review findings to act on**, tagged with the member each came
  from. A pipeline finding is the case the cut half above does not
  reach, because the pipeline produced it and you did not: relaying
  it into an `issue-fixer` brief *is* that fixer's task definition
  rather than your search, and withholding it would leave the fixer
  nothing to fix. A finding **of your own** stays cut — the exemption
  is about where the finding came from, not about findings being
  useful.

Then let the agent discover the rest.

Do not:

- **Restate anything already durable.** `CLAUDE.md`, `.claude/rules/`,
  and the agent's own definition are read at the start of every run,
  so a brief that repeats them is pure cross-surface repetition. If a
  constraint keeps needing repetition across briefs, the repetition is
  the signal to make it durable — a PR against `CLAUDE.md` or the
  agent definition — not to repeat it better.
- **Name the expected conclusion, the likely dominant move, or where
  to look.** Naming the finding makes the agent's report an echo of
  your judgment, which destroys the independence the teammate exists
  to provide. It also constrains the exploration space the same way
  leading with examples does.
- **Run the search.** This is finer than the line above. Imposing a
  standard the output must meet is your job: *"fix it by adding the
  missing case, not by softening the sentence — the claim should
  become true rather than smaller"* states a bar on a genuine fork
  where both branches are defensible, and it names nothing the agent
  will find. *"Check the three other figures in that sentence"* is the
  search, itemised. Keep the first, cut the second.
- **Specify the implementation.** If the agent is about to open the
  file, it does not need to be told what is in it — including that its
  change should match the siblings already there.
- **Carve away scope the agent needs.** Over-specification subtracts
  as well as adds, and the subtraction leaves no trace in the output.
  A prohibition aimed at one surface routinely lands on the whole
  remit next to it — *"don't touch the rules files"* in a brief whose
  task is a rules-file defect — and the agent comes back having done
  less than its definition already permitted, with nothing in the
  report saying why. When a scope constraint is genuinely needed,
  state the constraint rather than the prohibition: *"change what the
  rule requires, not which files it governs"* protects what matters
  and leaves the agent its remit. A prohibition that is already in the
  agent's own definition needs no brief line at all — the PR body is
  the case, frozen for the loop by `issue-fixer`'s and `doc-updater`'s
  definitions rather than by anything you write (see "The PR body is
  frozen for the loop").
- **Carry a brief forward.** Write each one from the task, never by
  editing its predecessor. Adding a constraint feels free and removing
  one feels risky, so an edited brief's constraint block only ever
  grows — monotonically, across every round of a long loop, shedding
  nothing.
- **Pass resolved repo-config values, generic git-workflow
  instructions, end-of-run cleanup steps, or "use this `gh` command"
  templates.** The agents read the config and know their own workflow.
  Trust them.

Further rules govern **findings** wherever you pass them onward — into
an `issue-fixer` brief or to the human:

- **Never pre-set or soften a severity.** A severity is transcribed
  mechanically from a consequence class one of the review agents
  assigned, by the rules in the `sdlc:theorem-based-pr-reviewer` agent
  → "Findings by severity"; re-tiering a finding on its way into a brief
  substitutes your judgment for that derivation, and the fixer gives
  back the tier you handed it.
- **Supply consequence, not a consistency checklist.** The question is
  whether being wrong changes what someone does. A doc claim that
  teaches a wrong security boundary qualifies; a row-count footnote
  does not. A checklist of consistency items reliably yields
  consistency findings, which then read as thoroughness.

Escalation and safety rules belong in durable rules and agent
definitions, not in per-run prose. A rule that lives only in a brief is
one long session away from being forgotten.

### Report-consumption principle

The section above governs what goes into a brief. This one governs
what you do with what comes back. You own the judgment at both ends of
a spawn: a report you relay unexamined is your claim now, whatever
byline it arrived under.

`~/.claude/rules/label-uncertainty.md` is the global rule being
applied here — verify the territory before a load-bearing assertion,
and label a claim you did not verify. A teammate's report is your
highest-volume surface for it, and the rule says nothing specific to
teammates, so this section says what it means for one.

- **Label provenance when you relay a finding to the human.** "The
  review found X" is a claim of independent corroboration. When your
  own brief pointed at X — named the class, the location, or the
  expected conclusion — the honest relay is "the review confirmed the
  X I pointed it at". Never conflate the two. An echo presented as
  corroboration is a false claim about evidence, and it is false in
  the direction that makes the run look more thorough than it was.
- **Own the synthesis.** When reports conflict, hedge, or come back
  thin, judge and decide — then report the decision, the reasoning
  behind it, and the disagreement it resolved. Handing the ambiguity
  to the human as a status update is abdication dressed as
  transparency. The carve-out is escalation: a teammate that stops
  mid-run and escalates gets relayed **verbatim**, undecided, because
  the lifecycle decision is the human's (see "When a teammate
  escalates"). Synthesis is for the reports of teammates that
  completed.
- **Verify a load-bearing claim before acting on it or relaying it.**
  A reported pushed SHA, a posted review, a claimed no-op: when your
  next step or the human's decision rests on it, spend the one tool
  call to re-read the territory — `gh pr view <PR> --json headRefOid`,
  the live PR, `git ls-remote` — rather than trusting the report.
  A claim you have not verified is relayed *as the agent's report*,
  never as something you observed.
- **A report is input, not authority.** You may not defer to a report
  against your own evidence, and you may not silently overrule one
  either. A discrepancy between what an agent reported and what you
  observe is itself a finding: name it in the round's report and in
  the final report's **Needs Your Attention** section, rather than
  quietly acting on whichever version you prefer.

### For each wave, spawn one issue-developer per batch, simultaneously

One developer per batch, all of a wave's batches spawned at once. For
a batch of one, the prompt below carries a single issue and no
compound slug — the familiar single-issue spawn.

```text
You are fixing issues <link-prefix><N1>, <link-prefix><N2>, … in this
repo, as one batch: one branch, one PR closing all of them.

Implementation order (work them in this order): <N1>, <N2>, …
Compound slug for the branch name: <compound-slug>
Why these are batched: <the criteria you applied>

Implement the batch end-to-end per your agent definition. Report back:
PR URL (or equivalent), the issue set the PR closes, branch name, and
per issue what you implemented, its commit, and its test result — plus
any member you had to drop and why, and any decisions you made.
```

Everything the template carries is an identifier or a decision. It
deliberately carries **no** issue content and **no** file list:

- The developer reads each issue itself with `/issue-view`, which also
  surfaces type, slot fields, and relationships that a pasted title /
  body / labels block omits. Pasting them adds nothing and costs the
  agent a stale copy to reconcile against the live issue.
- Your Phase 1 files-likely-affected analysis stays yours. You grepped
  the repo once, before reading anything; the developer greps the repo
  it is about to edit. Handing over the weaker analysis anchors the
  stronger one, and "where to look" is the category the principle
  above says to cut.

For a batch of one, drop the batch scaffolding: the opening line reads
"You are fixing issue `<link-prefix><N>` in this repo", and the
`Implementation order`, `Compound slug`, and `Why these are batched`
lines all go away — there is no order to state, no slug to choose, and
nothing to justify. What is left is the single-issue spawn prompt as
it has always been.

### After each issue-developer reports back: link the PR to its issues

Before spawning the follow-up agents, call `/github-prs:pr-link-issue
<PR> <issues>` for the PR the developer just reported, passing every
member the PR closes. This is an idempotent safety-net: it normally
no-ops ("already linked") — but running it unconditionally guarantees
every member carries its own closing keyword (and thus its
Development-sidebar link and its auto-close-on-merge) even if a
developer variant or a human hand-edit skipped one. The orchestrate
flow always has the issue numbers in hand, so this always runs.

Pass the set the PR **actually closes**, which for a batch that
dropped a member is a subset of the branch's set. What you pass is the
skill's claim, and it reconciles that claim against the branch name
itself (see `/github-prs:pr-link-issue` → "Own issue set only"), but
it is your job not to ask it to re-add a deliberately deferred member.

The PR number and the branch name the developer reported are
load-bearing — every follow-up agent and the review pipeline are
addressed with them, and a wrong one sends the whole rest of the loop
at the wrong PR. This `/pr-link-issue` call is where a wrong PR number
surfaces cheaply; read what it reports back rather than assuming the
no-op, per "Report-consumption principle".

The PR stays a **draft** at this point and through the entire
review/fix loop — see "PR draft/ready lifecycle" below.

### After each issue-developer or issue-fixer: doc-updater, then review

Run `doc-updater` and then `theorem-based-pr-reviewer` **sequentially**,
doc-updater first. The review must see the final state of the PR
including the doc commit; if doc-updater runs after the review, the
review covers an incomplete PR.

This applies to **every** round that puts commits on the branch — the
initial `issue-developer` implementation and each `issue-fixer` round
alike (see "Handling review findings — the fix loop" below) — and each
of those rounds needs the doc pass before its re-review.

The doc pass is cheap in the common case and never costs a review
round: a round with no doc impact returns without a doc commit, and
the review-round cap (see "Hard Constraints" below) counts reviewer
spawns only, at whatever tier the pipeline picked.

No worktree is removed in this phase, or anywhere else in the run.
As each subagent returns — `issue-developer`, `doc-updater`,
`issue-fixer`, `agent-memory-scrubber`, `pr-finalizer`,
`theorem-based-pr-reviewer` alike — append its worktree to the run
file, per "The run file: every worktree this run creates" above, and
move on. Phase 3's terminal cleanup is the one place a worktree goes
away, which is what keeps a fan-out's worktrees from being removed
under a round that is still running.

**doc-updater spawn prompt** — give it PR number, the issue set, and
branch name. The same prompt serves both the developer's round and
every fixer round; the agent works from the PR diff, so it needs no
telling which round produced the commits, and a batch PR needs nothing
extra — k issues produce one diff. The set is context only, and the
titles ride along as a human-readable label on the numbers rather than
as issue content to work from: `doc-updater`'s own Inputs section says
it never reads those issues, so the developer template's cut of
title / body / labels — which exists because that agent *does* read
each issue — has nothing to withhold here:

```text
PR <PR_N> for issues <link-prefix><issue_N1> ("<title>"),
<link-prefix><issue_N2> ("<title>"), … has new commits on it.
Branch: <branch-name>

Update docs per your agent definition (CLAUDE.md, READMEs, /docs,
repo-level .claude/rules/ and .claude/skills/ that the change
affects, and in-code doc comments — TSDoc or the language
equivalent — in source files the PR touched). Report back which
files changed and what you updated.
```

### Run the review pipeline

Review is a teammate spawn like any other. Spawn
`theorem-based-pr-reviewer` with the `Agent` tool, giving it the
reviewer's own double-dash parameters — the PR number, the issue set,
and the branch name (`--pr`, `--issues`, `--branch`). That is the one
vocabulary both this path and a standalone `/sdlc:git-review-pr` use.

The reviewer carries the review procedure in its own definition, and
spawns the generator, one `theorem-disprover` per live theorem
in parallel, and one `counterexample-verifier` per disproved theorem
in parallel, all from inside itself. You spawn nothing of the
reviewer's own, and "Never do work an agent owns" applies to review
with no carve-out: you never write a review body and never run
`gh pr review` yourself.

The issue set is not context here: it is the **claim** the reviewer
reconciles against the branch name, so pass the set the PR actually
closes (a dropped member is not in it), and pass it on every run. Left
out, the reviewer falls back to reading the PR body itself, which is
the standalone path rather than this one:

```text
--pr <PR_N> --issues <issue_N1> <issue_N2> … --branch <branch-name>

Review this PR per your agent definition. Report back its verdicts,
findings, severity counts, and theorem tally.
```

Pass no `--generator`, no effort, and no model. The reviewer picks the
tier itself from the round's delta. You never pick one, and no
property of a round makes it yours to pick — `--generator` goes in
only when the human named a tier. See "Overriding the generator tier"
below.

`--full` is yours or the human's to pass, and it re-disproves every
recorded theorem, retired ones included.

The reviewer returns every verdict line it posted, the overall
APPROVED / NEEDS_CHANGES / BLOCKED, the severity counts, the findings
themselves, and the theorem tally — which includes how many disproved
theorems had their counterexample refuted by verification, the number
that says what the verification stage bought that round. What the
tally enumerates, and which of its counts never reach severity, is the
reviewer agent's own "Report back" section; this summary defers to it
rather than restating it. Afterwards append to the run file both the
reviewer's own worktree and every fan-out worktree that round's log
names, per "The run file: every worktree this run creates" — the
reviewer removes nothing of its own, and a reviewer that never returns
still leaves that log behind for you to read.

That return is a report, so read it per "Report-consumption
principle" — which cuts both ways here.

In its favour: you write none of the reviewer's briefs — not the
generator's, not a disprover's, not a verifier's. The reviewer fixes
them all, from parameters you pass (`--pr`, `--issues`, `--branch`)
and nothing else, so a review finding is independent of your judgment
by construction and "the review found X" is an honest relay.

Against: the verdict is a claim you act on and relay, and the review
is **posted** on the PR, so whether it says what the reviewer reported
back is one `gh pr view` away. Verify before a cap escalation or a
Phase 3 hand-off rests on it. The round kind matters to that reading:
an empty-delta round's verdicts are carried forward from the previous
round rather than freshly checked, and the reviewer says which kind of
round it ran.

### Overriding the generator tier

You do not pick a tier. The rubric lives in the reviewer, next to the
delta it reads (see the `sdlc:theorem-based-pr-reviewer` agent →
"Pick the generator tier"), and it routes between `theorem-generator` (low) and
`theorem-generator-medium` (medium) and nowhere else.

`--generator` is a human-override channel, and you pass it only when
the human names a tier. `theorem-generator-high` and
`theorem-generator-xhigh` are reachable that way and no other. The
cases that warrant asking the human for one:

- The diff changes the **executable behavior of a shared mechanism**
  *and* coincides with a security-sensitive surface — the `guardrails`
  permission-gate, credential handling, or anything that decides what
  a command is allowed to do.
- A round at the rubric's pick missed a defect the human then caught.
  That is direct evidence the tier was too low for this PR, and it
  holds for the rest of the PR's rounds.

Over-tiering is not merely wasted tokens, which is why an override is
something to argue for rather than a default to reach past. A
generator given more effort than the diff has stakes for spends it
manufacturing immaterial claims — and each one that gets disproved
drives a fix, which is a new diff for the next round to harvest more
of the same from. Too high a tier therefore degrades review quality,
not just its cost.

`--full` is the other override, and it is the human's or yours. Say in
the round's report which tier ran, whether the rubric or an override
picked it, and whether the round was a `--full` one.

### The PR body is frozen for the loop

The freeze closes as soon as the PR is linked to its issues.
`issue-developer` writes the body when the PR opens, and your one
`/github-prs:pr-link-issue` call appends whatever closing lines it is
missing immediately after (see "After each issue-developer reports
back: link the PR to its issues") — both of those land before the
first review round exists to be confused by them. From there until
the loop ends, **nothing edits the PR body**. Not you, not
`issue-fixer`, not `doc-updater`. `pr-finalizer` appends one final
section after the loop is over (see "End-of-loop lifecycle
transitions"), and that is the whole exception.

The freeze is what makes the review's inputs testable. The body is the
one input that can change with no commit, no comment and no timestamp,
so a finding whose fix is a body edit contributes nothing to any
round's delta: every later round is empty-delta, carries its verdicts
forward, and re-reports the fixed finding until the round cap runs
out. With the body frozen there is no such edit to miss, which is why
the reviewer reads the body once at the start of a round and never
diffs it.

So everything in flight travels as a **PR comment** — the human's
review adjustments you relay (see "Posting the human's review
adjustments as a PR comment") and the fixer brief you write (see
"Handling review findings — the fix loop"). A comment is append-only
and carries a timestamp the next round can cut against; a body edit is
neither.

A finding whose remedy really is a PR-body change is not lost by this.
Relay it to `pr-finalizer` as part of what the final section has to
settle, and say so in the round's report — the fix lands once, at the
end, rather than mid-loop where nothing can see it.

### Handling review findings — the fix loop

The reviewer reports a verdict per issue the PR closes — plus one for
any other issue its findings name, such as a branch-set member the
body silently dropped — and an overall verdict, which is the worst of
them. **The overall verdict drives the loop** — the PR merges as one
unit, so one member at NEEDS_CHANGES sends the whole PR back. The
per-issue verdicts tell you which member's criteria each finding is
measured against; carry those tags into the fixer's brief rather than
flattening them.

When `theorem-based-pr-reviewer` reports back:

**If the report carries no verdict block**: the reviewer did not
finish a round. The harness surfaces every one of these as
`status: completed` with the closing message as the result, so a
verdictless return is indistinguishable from a finished review unless
you check for the verdict block. Check on every return; this is not an
escalation, because the reviewer is not stopping to ask you anything.

Two different reports arrive this way and they take opposite
responses, so read what the report **says** before you act on it:

- **An in-progress status** — which stage the round is still waiting
  on and how much of it is outstanding, the theorem list itself as
  readily as the disprovers or the verifiers, and on a reviewer that
  had already exhausted its own resume loop, which exit it took. A
  round is under way; follow the steps below.
- **A broken call** — the report names a `sdlc-agent-result-persist`
  call the reviewer could not repair and quotes the script's message
  verbatim. No round is under way, so follow "A broken call" below
  instead. Never read one as an in-progress status: a re-spawn composes
  the same call and fails the same way, and step 4's escalation would
  then tell the human the PR keeps returning mid-round.

1. **Confirm it against the PR.** A round that returned mid-round
   posted no review, so read the PR rather than the report:

   ```bash
   gh pr view <PR> --json reviews \
     --jq '.reviews | sort_by(.submittedAt) | last | .submittedAt'
   ```

   If a review *was* posted, the report and the PR disagree, and that
   discrepancy is itself a finding — name both versions per
   "Report-consumption principle" and give it a **Needs Your
   Attention** row rather than acting on either.

2. **Spawn no `issue-fixer`.** There are no findings to fix: an
   in-progress status carries none by construction, and briefing a
   fixer from a partial round would put your own reading of the round
   into the fix.

3. **Re-spawn the reviewer** over the same PR with the same
   parameters. Nothing else in the loop changes — no doc-updater pass,
   because no commits landed, and no adjustment comment, because the
   human has nothing to adjust yet.

   That re-spawn **resumes** the stalled round rather than starting it
   over: the reviewer derives what is left from this round's log and its
   result files, keeps every theorem already settled there, and
   re-attacks only the rest (see
   the `sdlc:theorem-based-pr-reviewer` agent → "You are re-entrant",
   where one child per theorem per stage is an invariant and a settled
   theorem gets no second child at all). So a
   second in-progress return means the round
   is still making no progress on what it has left, not that the
   re-spawn threw the first attempt away.

4. **The round does not count against the review-round cap**
   (see "Hard Constraints" below). It produced no review, and charging
   the budget for a harness failure burns the loop's headroom on it.
   Count it in the round's report instead, so the human can see a PR
   that keeps returning mid-round rather than
   converging — after two such returns on one PR, raise it as a
   **Needs Your Attention** row rather than re-spawning indefinitely.

**A broken call.** This is a defect to surface, not a round to
retry. Spawn no `issue-fixer` and re-spawn no reviewer; raise it as a
**Needs Your Attention** row on the first return, quoting the script's
message verbatim per "Report-consumption principle", since that message
is the only evidence of which value the reviewer could not resolve. It
does not count against the review-round cap, for the same reason a
mid-round return does not: it produced no review.

**If APPROVED with Low findings**: List the Lows in the final report
for human decision, tagged by member. Do not spawn the fixer — no loop
runs for Lows alone. Relay each Low as the review stated it — the
never-soften-a-severity rule under "Spawn-prompt principle" governs
this hand-off as much as a brief.

**If APPROVED with no findings**: No further action needed for this PR.

**If NEEDS_CHANGES (any open Critical/High/Medium finding, on any
member)**:

1. If the review notes a Design Decision, or a deviation from the
   design, or a mismatch between an issue's title and the summary,
   stop, and bring this up to the human for review and a decision.
2. **Post the fix instructions as a PR comment**, then spawn an
   `issue-fixer` with the PR number and nothing else.

   The comment is the authoritative brief. Write it after you have
   judged the reviewer's report and consulted the human wherever the
   report needed a human decision — that judgment is step 1 above and
   "Report-consumption principle", and it happens before the comment
   is written, not inside the fixer.

   The comment's **first line is the marker**
   `<!-- sdlc:fixer-brief -->`, on a line of its own. That literal is
   how `issue-fixer` recognizes the comment as its instructions, how
   `theorem-based-pr-reviewer` knows to skip it rather than read it as
   a human adjustment, and how `pr-finalizer` finds the briefs at the
   end of the run — so a PR that changes it sweeps every file
   `git grep -n 'sdlc:fixer-brief'` returns:

   ```text
   <!-- sdlc:fixer-brief -->
   PR <PR_N> for issues <link-prefix><issue_N1>,
   <link-prefix><issue_N2>, … received review feedback.
   Branch: <branch-name>

   Findings to address — all of them, including Low, each tagged with
   the issue it belongs to:
   <paste every finding from the review, un-tiered, keeping the
   review's per-issue tags>

   Address per your agent definition. Report back what you fixed and
   what you didn't.
   ```

   Post it, and post nothing else on the PR until the fixer has run:
   `issue-fixer` reads the PR's **most recent** comment and stops if
   that comment is not a fixer brief, so a review-adjustments comment
   or an orchestration note landing between the two sends it home
   empty-handed. Post the adjustments comment first, then the brief.

   The spawn prompt then restates none of it:

   ```text
   PR <PR_N> has a fixer brief waiting on it.

   Address it per your agent definition. Report back what you fixed
   and what you didn't.
   ```

   Putting the brief on the PR rather than in the spawn prompt is what
   makes it readable afterwards — by the human, and by the next review
   round, which reads the comments posted since the previous review.
   A spawn prompt reaches neither: it is visible to nobody once the
   spawn returns.

3. After issue-fixer returns, append its worktree to the run file (see
   "The run file: every worktree this run creates") and spawn the next
   subagent. Read its per-finding report as input rather than as the
   record: it says which findings it fixed and which it did not, and
   the next review round is what settles whether it was right. When it
   reports a finding **unfixed** — escalated for a design decision, or
   declined — that is yours to judge and act on now, not to carry
   silently into another round (see "Report-consumption principle").
4. Spawn `doc-updater` against the branch, with the same spawn prompt
   as after the developer's round (see "After each issue-developer or
   issue-fixer: doc-updater, then review" above), and append its
   worktree to the run file when it returns, before the review runs.
   The review must see the final state of the PR including any doc commit;
   if doc-updater runs after the review, the review covers an
   incomplete PR. Skipping this step is what lets a fixer's own
   unverified doc claim reach the review unchecked. A round with no
   doc impact returns without a doc commit and does not consume a
   review round.
5. Spawn `theorem-based-pr-reviewer` again over the new changes, with
   the same parameters. The reviewer re-picks the tier itself from the
   new round's delta; a round in which the pick missed a defect the
   human caught is a reason to ask the human for a `--generator`
   override, per "Overriding the generator tier".
6. Repeat this loop until APPROVED or until the review-round cap
   (see "Hard Constraints" below) is reached.
7. If findings above Low persist when the cap is reached, escalate to
   the human in the final report.

### Posting the human's review adjustments as a PR comment

The human's input on a round is re-grades and overrides of the posted
review — a rejected finding, a severity override, occasionally a
missed defect — and it reaches you in conversation. An adjustment the
human means to **bind later rounds** must be posted on the PR as a
comment, by you, on their instruction: the PR is the only channel the
pipeline reads, so an adjustment that stays in conversation never
reaches the next round.

Post one comment per round of adjustments, naming each theorem id it
touches and what it does to it:

```text
Review adjustments for round <N>:

- T7 — rejected. <the human's reason>
- T11 — severity override: High → Low. <the human's reason>
- new — <the defect the human says the round missed>, in
  <file-or-location>.
```

Write only what the human told you to write. This is a relay, not a
judgment: an adjustment you author yourself would put your own reading
of the diff into the next round's theorem list, which is exactly what
"Never pre-solve a teammate's task" forbids. Ask the human first, and
post nothing they did not say.

The next round reads the comments posted since the previous review and
applies each: a rejected finding retires as human-refuted, a severity
override rewrites that finding's severity, and a missed defect mints a
new theorem that gets a disprover. None of it travels as a spawn
parameter.

Post this comment **before** the round's fixer brief, never after.
`issue-fixer` reads the PR's most recent comment and stops when it is
not a fixer brief, so an adjustments comment posted on top of one
strands the fixer — see "Handling review findings — the fix loop".

### Before `/pr-ready`: curate the PR's agent memory

`agent-memory-scrubber` runs after every memory-declaring teammate and
before Phase 3's `/github-prs:pr-ready` call, so the changes it lands
are part of what the human blesses. Spawn it once the PR's review loop
has settled — APPROVED, or the review-round cap reached — and no
further branch work is queued.

Running after every memory-declaring teammate is the whole point: by
that moment every agent that writes memory (`issue-developer`,
`issue-fixer`, `doc-updater` — `pr-finalizer`,
`theorem-based-pr-reviewer`,
`theorem-generator`, `theorem-disprover` and
`counterexample-verifier` write none) has captured into the session's
inbox for this branch, so the scrubber's pass grades the whole run's
entries. `pr-finalizer` running after the scrubber is therefore not a
re-trigger: it captures nothing, and it puts no commit on the branch
either. Nothing about that capture is on the branch: the inbox lives
under the harness scratchpad, and the scrubber's commit carries
`CLAUDE.md` and `docs/` changes and nothing else.

One pass is therefore the normal outcome, but it is a *consequence* of
running after every memory-declaring teammate — not a budget, and not
a rule that survives later work. **Spawn the scrubber again whenever a
memory-declaring teammate was spawned after the scrubber last ran.**
That is this trigger's one full statement; every other mention of it
in this file uses the same noun phrase or points here. Decide it from
your own spawn history: capture happens inside the teammate's
end-of-run, and none of the three reports a *successful* capture back
to you — a failed one it does report, stopping before its cleanup — so
a spawn is the only evidence you have that entries may be waiting. That over-approximates
— a round that wrote no entry triggers a scrubber spawn that finds
nothing — and the cost of the over-approximation is one spawn that
finds an empty inbox and commits nothing, against the cost of the
under-approximation, which is a round's entries dying with the
session. A late `issue-fixer` round after a re-review, or the
`doc-updater` pass that follows it, each captures into the inbox the
scrubber already emptied; the inbox is session-ephemeral, so entries
left there when the session ends are lost. Re-running is the correct
move rather than a violation, and the second pass sees only what the
later round captured. The only wrong placement is spawning it *early*,
while more branch work is still expected.

Curation is destructive, so it is agent-owned work: the orchestrator
never deletes, transfers, or rewrites memory entries itself, and never
invokes `/cc-tools:agent-memory-inbox-cleanup` directly (see "Never do
work an agent owns" under Hard Constraints). The scrubber's per-entry
and per-cut lines are the record of what it deleted, transferred, and
cut from a destination file, so pass them through to the human as it
wrote them, per "Report-consumption principle".

**agent-memory-scrubber spawn prompt** — give it PR number and branch
name:

```text
PR <PR_N> has settled its review loop. Branch: <branch-name>

Curate the PR's agent memory per your agent definition. Report back
what was transferred, what was deleted, and what was cut from a
destination file, where transfers landed, and the commit SHA you
pushed — or, if nothing was staged, why.
```

Append its worktree to the run file after it returns, the same way as
any other teammate's.

### When a teammate escalates

A teammate "escalates" when it stops mid-run and reports back instead
of completing — for example, when it hits an environmental mismatch,
a rule conflict, a topology problem, or any of the conditions in
`~/.claude/rules/escalation-discipline.md`. Escalation is distinct
from the review-finding fix loop above (which is normal
completion-then-followup, not an early stop).

When a teammate escalates:

1. Relay the full escalation to the human verbatim. Do not summarize,
   do not pre-decide between the options the teammate listed, and do
   not perform "obvious" cleanup of the teammate's environment
   (worktree, lock state, branch claim, in-flight commits). This is
   the named carve-out from "Own the synthesis" in
   "Report-consumption principle". An escalation is an incomplete run
   whose lifecycle decision the rules reserve for the human, so here
   the verbatim forward is the correct move rather than an abdication.
2. Wait for direction. The lifecycle decision belongs to the human —
   see "Never act on a subagent escalation without human input" under
   Hard Constraints.
3. If the human's direction is "retry," prefer re-dispatching a fresh
   subagent over resuming the escalated one. A fresh dispatch starts
   in a clean worktree; resume inherits whatever environmental state
   caused the escalation.

#### A dropped batch member

An `issue-developer` working a batch stops working a member and
reports when that member needs a design decision its issue does not
answer, or turns out materially larger than scoped. That is its **drop
protocol** — the member is dropped, never silently descoped — and like
any escalation it goes to the human verbatim.

What is different here is that the decision is scoped to the dropped
member, not to the PR. When the developer also delivered a PR for the
landed subset, do **not** stall that PR's loop waiting for the answer;
run it on the subset per the remedy below while the human decides what
becomes of the dropped issue. Unless the human says otherwise:

- The already-committed members stay, and the branch keeps its name.
  A PR closing a subset of its branch's issue set is sanctioned by
  `rules/git-workflow.md` → "Issue references", so the PR closes only
  the landed subset and the developer names the deferral in the PR
  body.
- The rest of the loop runs on that subset: `/pr-link-issue`,
  `doc-updater`, and the review pipeline all get the set the PR
  actually closes, not the branch's full set.
- The dropped issue **stays In Progress**. Do not flip it to In Review
  at end-of-loop (Phase 3) and do not put it back to Ready. It gets
  its own branch later, on the human's say-so.
- Surface it in the final report's **Needs Your Attention** section,
  naming the reason the developer gave.

A developer that reports a drop *and* a finished PR has completed its
run, not failed it — the escalation is about the dropped member alone.

### Wave sequencing

Do not start Wave 2 until all Wave 1 issue-developers have reported back
(doc-updaters, review pipelines, and fix loops can still be running — they don't
block the next wave). This ensures file-conflicting batches never run
concurrently.

---

## Phase 3: Final Report

### End-of-loop lifecycle transitions (per PR, on human confirmation)

The review/fix loop leaves each PR **draft** and every issue it closes
**In Progress**, with `agent-memory-scrubber` already run against it
after every memory-declaring teammate ran (Phase 2, "Before
`/pr-ready`: curate the PR's agent memory") so the run's memory is
curated before the human sees it. Phase 3 is where the human
confirms — per PR — that the loop is done and the PR is good enough to
move forward. On that end-of-loop confirmation for a given PR, and
only then, the orchestrator performs these transitions, in this order:

1. **Spawn `pr-finalizer` to amend the PR body.** The body has been
   frozen since the developer wrote it (see "The PR body is frozen for
   the loop"), so it still describes the PR as first opened. The
   finalizer appends one section summarising the review rounds, the
   changes made in response, and any scope notes the run settled.

   The amendment lands **before** the flips below, so the status flip
   stays the run's single "done" signal and there is no window in
   which the PR is ready for review carrying no final note.

   Spawn it after the memory scrub and after any final `issue-fixer`
   round — those put commits on the branch, and a summary written
   before them would describe a PR that no longer exists. Give it the
   PR number, the branch name, and the scope notes the run settled
   that the reviewer's own posted reviews do not carry:

   ```text
   PR <PR_N> has finished its review loop. Branch: <branch-name>

   Scope notes this run settled, for the final section:
   <the deferrals, dropped members, and rulings the human made that
   the posted reviews do not carry — or "none">

   Append the final section per your agent definition. Report back
   what you appended.
   ```

   It reads the PR's own reviews and commits for the rest; that is its
   job, not yours to summarize into the brief. Append its worktree to
   the run file after it returns, the same way as any other
   teammate's.

2. **Flip the PR draft → ready:**

   ```text
   /github-prs:pr-ready <PR>
   ```

   This is the deliberate gate: because the repo's auto-merge workflow
   filters `isDraft == false`, a PR stays unmergeable (and its
   `Closes #N` auto-close stays inert) until this call. Keeping the PR
   draft through the whole review/fix loop is what makes "the
   orchestrator never merges before the human blesses the PR" enforced
   by state, not just by prose. Do **not** call `/pr-ready` earlier in
   the loop.

   If a memory-declaring teammate was spawned after the scrubber last
   ran — a late `issue-fixer` round, another `doc-updater` pass — spawn
   the scrubber again first (Phase 2, "Before `/pr-ready`: curate the
   PR's agent memory"), which is a read of your own spawn history
   rather than of any report. Whatever
   that round captured sits in a session-ephemeral inbox and is lost
   when the session ends, so flipping the PR ready over it discards
   it.

3. **Set every issue the PR closes to In Review.** The authoritative
   list of those issues is what `/github-prs:pr-closing-issues <PR>`
   reports — the one skill that reads a PR body's closing lines. Ask
   it rather than reusing the batch's planned membership: neither
   `/pr-create` nor `/pr-link-issue` writes a closing line for a
   member the developer **dropped**, so a dropped member is absent
   from that list and stays In Progress. Then, once per member it
   named:

   ```text
   /issue-set-status <N> "In Review"
   ```

   They flip together, because they ship together. Gated on a
   configured status slot — see "Issue-status transitions" below.

None of the three merges the PR; the human still owns the merge. If
the human ends the loop without blessing a PR (e.g. it lands in "Needs
Your Attention"), leave that PR draft and its issues In Progress — do
not flip it to ready or them to In Review, and do not spawn
`pr-finalizer` either: the loop has not ended, so there is no final
section to write and the body stays frozen for whatever round comes
next.

### The terminal cleanup

This is the run's **only** removal of anything, and it runs once, at
the end, after every PR has had whatever transitions above it gets:
the human said the review/fix looping is over → `pr-finalizer` → the
scrubber again if a memory-declaring teammate ran since it last did →
the `/pr-ready` flip → the issues to In Review → this. One cleanup for
the whole run, not one per PR, because the run file is the run's.

A PR the human never blessed gets none of those transitions, per the
paragraph above, and that holds nothing back here: this step runs once
the human ends the loop, whatever each PR's outcome was. Those
worktrees are as finished with on an unblessed PR as on a blessed one
— and leaking them is the failure the run file exists to close.

It is an inline step of this skill rather than an `sdlc` cleanup agent.
Every agent in this plugin declares `isolation: worktree`, so a cleanup
agent would be handed a worktree of its own — one more leftover, and
the one leftover it could not put in its own run file, since it is
standing in it. It would create the very thing it exists to remove, and
it would do no judgment work to pay for that: the run file already says
what to remove, so a cleanup agent would only be a courier.

Work the run file's records **serially**, in order, and touch nothing
else. For each record, `TaskStop` that record's own agent — the
harness names every worktree it hands out `agent-<id>`, so the id is
the path's basename with `agent-` dropped — and then run, in this
order:

```bash
git worktree unlock <absolute-path-from-the-run-file> || true
git worktree remove --force <absolute-path-from-the-run-file>
git branch -D worktree-<basename-of-that-path> || true   # worktree-agent-<id>
```

Each step of that is licensed by something the run knows:

- **Stop first, unconditionally, and ignore the failure.** No liveness
  check, no probe of whether that agent is still running, no branch on
  where the record came from — every record is worked identically.
  Read what the answer establishes, though, and no more: a `TaskStop`
  answers `No task found with ID` for an agent **you** spawned that
  already returned, for an agent you never spawned, and for an id that
  never existed alike, so it says only that this session holds no task
  by that id. It never says the agent returned, and it is never a
  failure to report.

  For a teammate's record the stop is real — you spawned that agent —
  and the run appended the record only after it returned anyway. For a
  **fan-out child** it is a no-op whatever the child's state, because
  the reviewer spawned that child and you did not; what leaves those
  trees quiet is the reviewer stopping its own children before it
  returns, on every path by which it does, per
  `docs/plugin-authoring-constraints.md` → "Every spawner stops its
  own children before it returns". Your stop is belt-and-braces over
  that. Destroying a worktree and its branch while its agent is still
  working there is not an end state to leave behind, which is why the
  stop comes before the removal rather than after it.
- **Unlock unconditionally, and ignore its failure.** Every worktree
  here belongs to an agent the run has stopped — you stopped the
  teammates, and the reviewer stopped its own fan-out children before
  it returned — so a lock left on one is a stale end-state lock rather
  than a live agent's, and you are not inferring that from the lock
  reason. For a fan-out child that is not a promise made in prose: the
  reviewer appends a `killed` record for every child it stops on its
  way out, so a theorem whose last `enter` in a stage is followed by a
  `killed` has nothing running in its tree, and the record is what says
  so (`sdlc:agent-result-persist-interface` → "The modes"). One case
  escapes that and is named rather than papered over: a reviewer killed
  before it could return stopped nothing and recorded nothing, so a
  child whose `enter` carries no `leave`, no `stopped` and no `killed`
  can still be running here. It is still this run's worktree and
  still yours to remove — the human has ended the loop — and it is the
  same case the run file exists to keep from leaking. Not every
  worktree carries a lock, though, and `git worktree unlock` on an
  unlocked one is not a no-op: it exits 128 with
  `fatal: '<path>' is not locked`. That failure is the expected case
  and never a removal failure to report.
- **`--force` is correct here**, and this is the one place in the run
  it is. See "What the orchestrator IS allowed to do" for the carve-out
  and its bounds. Everything of value the run produced is on the PR
  branch and pushed; what is left in these worktrees is scratch, and
  the stops above — yours over the teammates, the reviewer's over its
  own children — ended what was using them.
- **Delete only the harness's throwaway branch.** The harness creates
  one `worktree-agent-<id>` branch per worktree it hands out, and its
  name follows from the worktree directory's own name — so the branch
  to delete is derived, never guessed. A `git branch -D` reporting
  that branch not found is nothing to repair — an agent that detached
  and released it already got there — which is why that line carries
  `|| true` as well: the expected case must not read as a removal
  failure to report. **Never delete the issue branch**: it carries the
  PR the human is about to merge.

These bounds make it safe to run in a `.claude/worktrees/` shared with
every other session on this repo:

- **It acts only on paths the run file names**, and on the agent ids
  those paths carry. A path it was not given belongs to another
  session, whatever state it is in, and so does the agent standing in
  it — the stop is unconditional over the records, never over the
  directory.
- **It never enumerates `.claude/worktrees/`, and never sweeps the
  `git worktree list` output by pattern.** There is no "looks like one
  of ours" arm, because there is no way to write one that is right.

One worktree can exist that the run file cannot name: a fan-out child
that died before writing its `enter` record leaves a `spawn` record
carrying no agent id, so no path resolves for it. The reviewer reports
that child by theorem and stage; relay it the same way in the summary,
and guess no path for it — which leaves it no id to stop either, since
the id is what the path carries. Guessing is what the whole design
refuses.

Report every removal that **fails** with git's own message, verbatim,
in the summary. Never route around a failure — not with a second
`--force`, not with `rm -rf`, not with a script that globs. A leaked
directory costs disk; an improvised removal is how another live
session loses tracked files.

`/git-tools:git-cleanup-branches-and-worktrees` remains the whole-repo
sweep a human runs over whatever any run left behind, from any session.
This step does not invoke it and is not a variant of it: that skill
works out what is safe to remove from the tree in front of it — a
clean worktree whose commits are all on origin, a lock whose pid is
dead, a merged PR with its remote branch gone — while you infer
nothing, because you were told.

### Summary

Once all waves are complete and all review loops have settled, deliver
a summary:

```text
## Issue Fix Summary

### Ready for Your Review
| Batch | Issues | PR | Review Verdict | Review Rounds | Doc Changes |
|-------|--------|----|-----------------|---------------|-------------|
| A | <link-prefix>101 | <PR1> | Approved | 1 | CLAUDE.md, README.md |
| B | <link-prefix>106, <link-prefix>104 | <PR2> | Approved (both) | 2 (fixed high on 104) | /docs/api.md |

### Needs Your Attention
| Issue | PR | Problem |
|-------|----|---------|
| <link-prefix>102  | <PR3> | Critical finding persists at review-round cap |
| <link-prefix>105  | —     | Dropped from batch C — needs a design decision its issue doesn't answer; not on <PR3>, still In Progress |

### Sequential Queue (not yet started)
| Batch | Issues | Waiting On | Reason |
|-------|--------|-----------|--------|
| D | <link-prefix>103 | Batch C to merge | same file conflict |

### Terminal Cleanup
<the terminal cleanup's own summary: how many run-file records it
worked, and one line per removal that failed, carrying git's message
verbatim>

All ready-for-review PRs are open and awaiting your approval.
Nothing has been merged.

To start the sequential queue, reply: "continue with <link-prefix>103"
```

Every cell in those tables is a claim to the human, and most of them
arrive from a teammate's report rather than from something you
observed — the `Doc Changes` list is `doc-updater`'s account of its
own commit, and the `Review Verdict` and the severity detail behind it
are `theorem-based-pr-reviewer`'s. `Review Rounds` is the cell that is
genuinely yours: the reviewer reports one round's verdict, tally, tier
and round kind and never a round count, so the number is your own
tally of loop iterations, while the parenthetical explaining it draws
on the reviewer's severity line and the fixer's report. Fill them per
"Report-consumption principle":

- The PR column and the verdict are load-bearing — the human decides
  whether to merge on them — so verify them against the live PR rather
  than against your notes of what was reported.
- Say what a finding's provenance was when it is not the review's own.
  A defect you observed yourself is never "the review found" it, and
  neither is one the human raised that you never relayed. A defect the
  human raised that you *did* relay as an adjustment comment is
  different: the next round minted it as a theorem and a disprover
  broke it, so it is the review's finding by that round, and the
  human's contribution is that the theorem exists at all. Name which
  of those a finding is.
- A discrepancy between an agent's report and what you observe gets
  its own **Needs Your Attention** row, naming both versions. Silently
  publishing whichever one you believe hides the discrepancy that was
  the actual finding.

---

## Hard Constraints

- **Never merge a PR.** Leave all PRs in open/ready-for-review state.
- **Never do work an agent owns.** The orchestrator's job is plan +
  spawn + report. If a teammate agent's definition covers a kind of
  work, spawn that teammate rather than doing it yourself, even when
  the agent has already run once on this PR. Agent-owned work
  includes:
  - **Code/config edits, including doc edits** — owned by
    `issue-developer`, `issue-fixer`, `doc-updater`. The orchestrator
    never uses `Edit`, `Write`, or `NotebookEdit`. The
    orchestrator never *originates* feature work via `git commit` or
    `git push` — those belong to the teammate that owns the change.
    The narrow exception is pushing a commit the agent already
    authored but couldn't push itself (see "What the orchestrator IS
    allowed to do" below); the orchestrator never authors new
    feature-work commits in the primary clone.
  - **PR reviews** — owned by `theorem-based-pr-reviewer`, which
    carries the review procedure and spawns the
    `theorem-generator` / `theorem-disprover` /
    `counterexample-verifier` agents itself. You **spawn** that
    reviewer (see "Run the review pipeline") and do none of its work:
    you never author a review finding, never write a review body from
    your own reading of the diff, never assign a severity, and never
    run `gh pr review` in any spelling — the
    pipeline posts through `/github-prs:pr-review-submit`, handing it
    a body file the reviewer staged under `.claude/tmp/`. The one
    thing you post on a reviewed PR is a review-adjustments comment
    the human dictated, per "Posting the human's review adjustments as
    a PR comment".
  - **Editing a PR body** — owned by `pr-finalizer`. The body is
    frozen for the whole loop (see "The PR body is frozen for the
    loop"), and the one amendment it gets is the final section the
    finalizer appends in Phase 3. The orchestrator never runs
    `gh pr edit --body` / `--body-file`, and never briefs another
    teammate to. Your `/github-prs:pr-link-issue` call is not the
    exception it looks like: it writes closing lines and nothing else,
    and it runs before the first review round.
  - **Merge-conflict resolution** — owned by `issue-fixer`. The
    orchestrator never runs `git rebase`, `git merge`, or hand-edits
    conflict markers in the primary clone.
  - **Implementing review findings** — owned by `issue-fixer`. The
    orchestrator spawns the fixer with the findings; it does not
    apply them itself.
  - **Agent-memory curation** — owned by `agent-memory-scrubber`. The
    orchestrator never deletes, transfers, or rewrites a captured
    memory entry, and never invokes
    `/cc-tools:agent-memory-inbox-cleanup` itself. Curation is
    destructive and the scrubber's report is the record of it. When a
    memory-declaring teammate was spawned after the scrubber last ran,
    the remedy is another scrubber spawn — never an
    orchestrator-authored touch-up.
- **Never act on a subagent escalation without human input.** When a
  teammate stops and reports an environmental mismatch, rule conflict,
  or topology problem, the orchestrator's job is to surface that
  escalation to the human verbatim and wait for direction — not to
  repair the environment and resume. Specifically forbidden without
  explicit human approval:
  - `TaskStop`ping the escalated teammate, or removing, unlocking, or
    force-removing its worktree, or deleting any branch it holds. An
    escalated teammate never reaches the run file — you append a
    worktree only once its owner is done with it — so the terminal
    cleanup does not touch one either.
  - Resuming an escalated subagent instead of asking the human
    (always re-dispatch fresh if the human says retry)

  The line is: if a subagent is mid-run or escalated, the lifecycle
  decision belongs to the human.
- **Never skip the planning phase.** Even for a single issue.
- **Never spawn a Wave 2 batch concurrently with a conflicting Wave 1
  batch.**
- **Never regroup a batch after its developer has spawned.** Grouping
  is settled at the Phase 1 confirm step, which is the human's escape
  hatch on it; once a branch carries commits and a PR, the only way a
  member leaves the batch is the developer's drop protocol (see "A
  dropped batch member").
- **Never pass a `worktree_path` in a spawn prompt.** Every teammate
  declares `isolation: worktree` and the harness handles their
  working directory. Pass branch name + PR number + the issue set
  instead.
- **Never duplicate agent runbooks in spawn prompts.** Trust the agent
  to read its own definition and the per-repo config.
- **Never pre-solve a teammate's task in its spawn prompt.** No
  expected conclusion, and no finding or location **of your own** — a
  brief carries standards, scope boundaries, decisions, and
  identifiers, not the answer. Findings the review pipeline produced
  are the exemption. See "Spawn-prompt principle" for the keep/cut
  test and for why that exemption holds.
- **Never relay a teammate's report as your own observation, and never
  present it as independent corroboration of something you pointed it
  at.** Verify a load-bearing claim against the territory, or label it
  as the agent's report. See "Report-consumption principle".
- **Never instruct a teammate to use a closing keyword adjacent to an
  issue reference.** A closing keyword (`close`/`closes`/`closed`/
  `fix`/`fixes`/`fixed`/`resolve`/`resolves`/`resolved`,
  case-insensitive) **immediately followed by** an issue reference
  (`#N`, `owner/repo#N`, `GH-N`, or issue URL) auto-closes the
  referenced issue and must never appear. See
  `rules/git-workflow.md` → "Issue references" for the full rule.
- **Never stop an agent, remove a worktree, or delete a branch before
  the terminal cleanup.** You do none of the three anywhere else; you
  append to the run file and the one terminal step acts on it (see
  "The terminal cleanup").
  It works its records serially, never in parallel, per
  [Anthropic issue #48927](https://github.com/anthropics/claude-code/issues/48927).
- **Always wait for explicit human confirmation** before starting
  Phase 2.
- **Max review rounds per PR: 5.** Escalate to human after that. A
  round is one `theorem-based-pr-reviewer` spawn **that posted a
  review** — everything inside that spawn is one round, however many
  `theorem-disprover` and `counterexample-verifier` agents its
  fan-outs spawned, at whatever generator tier; the `doc-updater` pass
  that precedes each one is not a review and never counts against the
  cap. A spawn that returned without a verdict block posted nothing
  and does not count either — an in-progress status or a broken
  `sdlc-agent-result-persist` call alike (see "Handling review
  findings — the fix loop"):
  charging the budget for a spawn that checked nothing spends the
  loop's headroom on it.

### What the orchestrator IS allowed to do

The "never do work an agent owns" rule is not a total prohibition on
the orchestrator running commands. The following are orchestration
mechanics, not agent-owned work, and the orchestrator should do them
itself:

- **Read freely.** `gh pr view`, `gh pr diff`, `git log`, `git diff`,
  file reads. Reading is planning; the more the orchestrator reads
  before spawning, the better its batching, sequencing, and scope
  rulings — which is what a brief carries. It does not make the brief
  longer: what the reading turns up stays yours (see "Spawn-prompt
  principle"). These read-only
  planning commands have **no `/issue-*` equivalent**, so raw `gh` /
  `git` stays the right tool for them. For *reading an issue*,
  however, prefer `/issue-view <N>` over `gh issue view <N> --json
  ...` — see "Prefer the `/issue-*` namespace over raw `gh`" below.
- **Run git plumbing for orchestration mechanics.** `git fetch`,
  `git pull --ff-only` / `git merge --ff-only` on long-lived branches
  it tracks (the pre-flight's fast-forward, and keeping the default
  branch current in the primary clone after a merge), `git push` of an
  agent's work that the agent committed but couldn't push due to a
  credential prompt (rare), and the terminal cleanup's `TaskStop` /
  `git worktree unlock` / `git worktree remove --force` /
  `git branch -D` over the run file's records.

  Force-removal is otherwise reserved for data-loss cases (uncommitted
  changes or unpushed commits the user has chosen to discard) and
  needs explicit human approval for the data loss. **The terminal
  cleanup is the one named exception**, and its licence is what the
  run file records plus the stops that ran first, rather than what a
  lock reason suggests: every record's agent has been stopped by the
  instance that could stop it — you for the teammates you spawned, the
  reviewer for its own fan-out children, and the reviewer's stops are
  on the round log as `killed` records rather than taken on trust —
  before its worktree is touched, the PR is pushed and already flipped
  ready, and the run knows nothing of value is left in those trees.
  Outside that step — mid-run, and against any path the run file does
  not name — force-removal stays a human decision, and so does any
  cleanup touching a worktree whose subagent is still mid-run or
  escalated (see "Never act on a subagent
  escalation without human input" above).
- **Comment on a PR with orchestration metadata** — e.g. "closing
  this PR because we'll respawn the issue", or pointing at a follow-up
  issue. That's coordination, not review. A review body with verdict
  is always the review pipeline's job. The review-adjustments comment
  under "Posting the human's review adjustments as a PR comment" is
  the same bucket: you relay what the human dictated, you do not grade
  anything. So is the **fixer brief** under "Handling review findings
  — the fix loop": the findings in it are the pipeline's, and writing
  them onto the PR rather than into a spawn prompt is how the fixer
  and the next round both reach them. Commenting is not editing —
  the PR *body* is `pr-finalizer`'s alone. PR comments
  (`gh pr comment`)
  have no
  `/issue-*` equivalent, so raw `gh` stays the tool here — but
  commenting on an *issue* goes through `/issue-comment <N>`, per
  "Prefer the `/issue-*` namespace over raw `gh`" below.
- **Manage a PR's draft/ready state and issue links via the
  `/github-prs:*` skills** — `/pr-link-issue <PR> <issues>` (link
  a PR to the issues it closes), `/pr-closing-issues <PR>` (read back
  which issues it closes), and `/pr-ready <N>` (flip draft → ready at
  end-of-loop). These are coordination metadata in the same bucket as
  `gh pr comment`: they set or read the PR's lifecycle state, they
  don't author feature work or a review verdict. `/pr-link-issue` is
  set-idempotent (it adds only the missing `Closes #N` lines, and
  no-ops when the developer already wrote them all),
  `/pr-closing-issues` is read-only, and `/pr-ready` merely un-drafts
  — none of them merges the PR. See "PR draft/ready lifecycle" below
  for when the orchestrator calls `/pr-link-issue` and `/pr-ready`,
  and "End-of-loop lifecycle transitions" above for the
  `/pr-closing-issues` read that feeds the In Review flip.
- **Set issue status via `/issue-set-status`** — `In Progress` when
  work starts, `In Review` at end-of-loop. Coordination metadata, not
  agent-owned work. See "Issue-status transitions" below and the
  `/issue-*` namespace rule for the general "prefer the skill"
  principle.
- **File follow-up issues via `/issue-create`.** It sets type,
  priority, size, status, project-board entry, and assignee from
  repo-config in one shot, so the issue is fully configured before the
  URL is printed. Raw `gh issue create` is **not** a substitute —
  issues filed that way come out unconfigured (no type, no slot
  fields, no board entry, no assignee) and require multiple follow-up
  `/issue-set-*` calls to backfill metadata the skill would have set
  in the first place. The skill *is* the right tool for issue
  creation; there is no Task-tool agent for it, but that is no longer
  a reason to hand-roll the raw CLI. If the issue body would be
  long-form and multi-step, ask the human first rather than authoring
  it yourself — that rule is independent of which tool authors the
  issue.

  After `/issue-create` returns, **post-verify with `/issue-view`.**
  Run `/issue-view <new-N>` and confirm that `type`, the configured
  slot fields (`priority`, `size`, `status`), and the assignee are
  populated as repo-config requires. If any required field is empty
  when repo-config says it should be populated, surface the mismatch
  in the final report's **Needs Your Attention** section rather than
  declaring the follow-up issue filed. The check is cheap (one
  `/issue-view` call) and catches the case where `/issue-create`
  silently skipped a step. The post-verify is **not** redundant with
  `/issue-create`'s own output checklist: verifying your own output
  is structurally weaker than having an independent caller verify it,
  and the orchestrator is that independent caller — so it reads the
  issue back rather than trusting the create runbook's self-report.

### PR draft/ready lifecycle

Every PR the orchestrate flow produces goes through the same
draft-first lifecycle:

1. **Born draft.** Every PR the developer reports back is a draft;
   its agent definition is what guarantees that. A draft PR cannot be
   auto-merged — the repo's auto-merge workflow filters
   `isDraft == false` — so the PR is inert from the moment it opens.
2. **Linked.** Right after the developer reports back, the
   orchestrator calls `/github-prs:pr-link-issue <PR> <issues>` to
   guarantee the PR body closes every issue it delivers, one closing
   line each (set-idempotent — see "After each issue-developer reports
   back: link the PR to its issues"). The `Closes #N` keywords only
   fire on merge to the default branch, so they stay inert while the
   PR is draft.
3. **Stays draft through the whole review/fix loop, and through the
   memory scrub that closes it out.** doc-updater, the review
   pipeline, and any issue-fixer rounds all run against the draft PR,
   and so does
   `agent-memory-scrubber` — running after every memory-declaring
   teammate, re-spawned whenever a memory-declaring teammate was
   spawned after the scrubber last ran (see "Before `/pr-ready`: curate
   the PR's agent memory"). Nothing in that sequence flips the PR to
   ready, and nothing in it edits the PR body either (see "The PR body
   is frozen for the loop").
4. **Finalized, then ready at end-of-loop, on human confirmation
   only.** In Phase 3, when the human confirms a PR is good enough to
   end the loop, the orchestrator spawns `pr-finalizer` to append the
   run's final section to the body, and only then calls
   `/github-prs:pr-ready <PR>` (see "End-of-loop lifecycle
   transitions"). That order is what keeps the PR from being ready for
   review for a window in which its body has no final note. The
   `/pr-ready` call is the single point where the PR becomes
   mergeable, and even then the human — never the orchestrator —
   performs the merge.

The draft state is the enforcement mechanism behind the "Never merge a
PR" Hard Constraint: it makes "unmergeable until the human blesses it"
a property of the PR's state, not just a rule in prose.

### Issue-status transitions

The orchestrator keeps each issue's board status in sync with its
lifecycle via `/issue-set-status`. A batch's members transition
together, because one developer starts them together and one PR ships
them together:

- **In Progress** — set after plan confirmation, before spawning the
  batch's developer (Phase 2, "Set each batch's issues to In Progress
  before spawning its developer").
- **In Review** — set on end-of-loop human confirmation, for every
  member the PR closes (Phase 3, "End-of-loop lifecycle
  transitions"). A dropped member is not one of them and stays In
  Progress.

Both transitions are **gated on a configured status slot**: the repo
must have `github-project.fields.status` (GitHub) or the Jira `status`
slot in `.issues/repo-config.md`. If no status slot is
configured, **warn-and-skip** — emit a one-line note that status
tracking is not configured and continue the run. Do **not** abort;
this matches how `/issue-set-status` itself degrades.

**Option-name fallback.** `/issue-set-status` matches option names
case-insensitively, so `"In Progress"` / `"In Review"` resolve to a
board's `In progress` / `In review` options automatically. But if the
board has a status slot that **lacks** a matching option — i.e.
`/issue-set-status` aborts with its "Slot value not in options map"
error — the orchestrator must **catch that abort and ask the human**
which status option to use instead, or whether to skip the transition
for this run. It must **not** let that abort fail the whole run. This
keeps the feature working on boards whose status options are named
differently (e.g. `Doing` / `Reviewing`).

### Prefer the `/issue-*` namespace over raw `gh`

Wherever a `/issue-*` skill exists for an operation, use it rather
than hand-rolling the equivalent `gh issue ...` or `gh api graphql`
call. The skills read repo-config (via `skills/lib/repo-config.md`),
respect the repo's project board config, dispatch on the issue tracker
(GitHub vs. Jira), and emit the namespace's canonical abort wording —
a raw `gh` call silently does the GitHub-only thing and skips all of
that. This is the same "stop reaching for the lazy raw-`gh` path"
principle behind `/issue-create` above, applied to the rest of the
namespace.

- **Reading an issue** → `/issue-view <N>` (and `/issue-view-tree`,
  `/issue-sub-list` for hierarchy) instead of
  `gh issue view <N> --json title,body,labels`. `/issue-view`
  surfaces type, all configured slot fields, and
  parent/sub-issue/blocked-by/blocking relationships in one shot; an
  ad-hoc `gh issue view --json` misses all of that.
- **Commenting** → `/issue-comment <N>` instead of `gh issue comment`.
- **Closing** → `/issue-close <N>` instead of `gh issue close`.
- **Setting fields** → `/issue-set-status`, `/issue-set-priority`,
  `/issue-set-size`, `/issue-set-type`, and the
  parent/child/blocked-by relationship verbs (`/issue-set-parent`,
  `/issue-set-child`, `/issue-set-blocked-by`, `/issue-set-blocks`,
  and their `unset-` counterparts) instead of raw `gh api graphql`
  issue mutations.
- **Updating title/body/labels/assignees** → `/issue-update <N>`
  instead of `gh issue edit`.

These carve-outs keep this rule from being over-broad:

1. **Read-only planning `gh` / `git` stays.** `gh pr view`,
   `gh pr diff`, `git log`, `git diff`, and file reads have no
   `/issue-*` equivalent and remain the right tools for Phase 1
   planning (see "Read freely" above). This rule is specifically
   about *issue* operations that now have a skill.
2. **No `/issue-*` skill exists → raw `gh` is fine.** When an
   operation has no skill — e.g. a bulk query across many issues, a
   `gh issue list` filter, or a field the namespace doesn't expose —
   raw `gh` remains the tool. The rule is "prefer the skill where one
   exists," not "never touch `gh` for issues."

## Token Efficiency

- Use every teammate with its own frontmatter-declared `model` and
  `effort` — do not override the model on a routine spawn, and note
  that effort cannot be overridden at spawn time at all. Every
  teammate but the off-default generator tiers declares
  `effort: medium`
  deliberately: it has proven more solid than higher efforts on the
  bounded, spec-driven tasks the teammates receive. For a genuinely
  hard issue, escalate that single spawn to a stronger model via the
  `Agent` tool's per-call `model` override rather than editing front
  matter; the frontmatter `model:` is a default, and an override may
  name a lower, higher, or equal model for that one spawn. Changing an
  effort is always a frontmatter
  edit plus an `sdlc` version bump, and it changes every spawn of that
  agent — it is not a per-run lever. Review is the exception in
  *selection*, not in mechanism: `theorem-generator`,
  `theorem-generator-high` and
  `theorem-generator-xhigh` are separate definitions pinning
  `effort: low`, `effort: high` and `effort: xhigh`, so a cheaper or
  costlier generation is bought by spawning a different definition,
  never by an effort override. The reviewer chooses between the low
  and medium ones itself; the two higher ones are reachable only
  through a `--generator` override (see "Overriding the generator
  tier"). The reviewer routes a `model` per spawn
  of its own, described above: a `mechanical` theorem is spawned below
  the declared default of `theorem-disprover` and of
  `counterexample-verifier` alike, and no such value is named here.
  That is inside the reviewer's fan-outs, not a teammate spawn you
  make.
- Reserve your own model (the orchestrator's) for planning decisions
  and synthesis only
- If the run is large (>8 issues across all batches), split into two
  separate team sessions and note this to the human before proceeding
- **Doing agent work — OR making decisions about an agent's
  lifecycle/environment — in the orchestrator is not a token-saving
  optimization.** It shortcuts the safety mechanism: a teammate's
  perspective on its own task is independent of the orchestrator's;
  the orchestrator's perspective on the same task is not. And the
  human is excluded from decisions the rules reserve for them
  (escalations, locked worktrees, retry-vs-resume). A "quick"
  orchestrator-authored review, fix, or environmental repair loses
  that independence and is worth fewer tokens than it costs.
