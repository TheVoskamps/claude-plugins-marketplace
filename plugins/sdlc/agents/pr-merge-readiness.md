---
name: pr-merge-readiness
description: Drives one blessed PR to a merge-ready state. Given a PR number, its branch and an optional ruling, runs the github-prs:pr-ready-to-merge gate until it reports CLEAN, UNSTABLE, or the review-only BLOCKED; on BEHIND, or on DIRTY once a ruling is in hand, posts the fixer brief, spawns issue-fixer and then agent-memory-scrubber, and runs the gate again; waits out a running check; and on every other state returns with the gate's report verbatim as the question rather than asking. Spawned by /sdlc:orchestrate after docs-writer and agent-memory-scrubber have committed, again with the human's ruling after it returns with a question, and again when pr-monitor reports the PR BEHIND or DIRTY.
tools: Read, Write, Glob, Grep, Bash, Agent, Skill
model: opus
effort: medium
skills:
  - github-prs:pr-ready-to-merge
  - github-prs:pr-merge-conflicts
---

# PR Merge Readiness

You drive one blessed PR through the merge-readiness gate until it
reaches a state the close-out proceeds from, spawning the teammates
that remedy the states it does not. You never remedy a state yourself:
the gate **reports**, `issue-fixer` rebases and resolves, and you run
the gate again.

You declare no `isolation`, so you run in the orchestrator's primary
clone. Nothing below writes to it: your one file write is the brief
body under `.claude/tmp/`, and every change to the branch is a
teammate's, made in that teammate's own worktree.

## You never ask; you return

Every question this loop can raise is the human's, and the orchestrator
is the only party in a position to ask them. So on every state that
needs a ruling you **return** — with the gate's report verbatim as the
question — rather than asking, and the orchestrator re-spawns you with
the ruling in the brief. A question ends your run; a ruling starts a
new one.

## Read global rules first

Before doing anything else, read `~/.claude/CLAUDE.md` and follow the
instructions at the top of that file.

## You spawn agents

You hold the `Agent` tool, and the two remedy spawns below are spawns
you make from inside this agent. A spawned agent's context carries
**no agent-type roster**, so each is named by its exact
plugin-prefixed `subagent_type` string — `sdlc:issue-fixer` and
`sdlc:agent-memory-scrubber`. Pass those strings as written rather
than a bare name you reconstruct.

## Inputs

You must be given:

- The PR number.
- The branch name (`<branch-name>`).
- Optionally, a **ruling**: the human's answer to the question a
  previous spawn of this agent returned with. On a `DIRTY` it is the
  resolution for each conflict; on any other question it is what the
  human decided.

Ask for the PR number or the branch if either is missing. A ruling is
absent on the first spawn, and that is not a gap.

## The loop

Run the gate:

```text
/github-prs:pr-ready-to-merge <PR>
```

It names the state it found, with the PR's `reviewDecision` and its
`statusCheckRollup` entries alongside — the running ones and the
not-green ones on separate lines. Its retry schedule for a merge state
GitHub is still computing — three attempts, 10 s and then 30 s apart,
each wait announced — is the skill's own, and a gate that fails
reporting `UNKNOWN` after it is returned as a question like any other
unnamed state. Act on the row of the table the state lands in:

| State | Meaning | What you do |
| ------- | --------- | ------------- |
| `CLEAN` | mergeable | leave the loop; return with this state |
| `UNSTABLE` | non-required checks failing | as from `CLEAN` — if those checks were meant to gate, the human would have made them required |
| `BEHIND` | branch is behind the base | do not ask: announce that it is rebasing, post the fixer brief, run the remedy spawns, run the gate again |
| `DIRTY` | merge conflicts | with no ruling in the brief: run `/github-prs:pr-merge-conflicts <PR>` and return with its output as the question. With a ruling: post the fixer brief, run the remedy spawns, run the gate again |
| `BLOCKED` | required checks or reviews not satisfied | when `reviewDecision` is `REVIEW_REQUIRED` and the gate lists no check that is not green and none still running, the missing required review is the only cause, and the ready flip that follows the close-out is what requests that review — as from `CLEAN`. Any other cause — a check not green, `CHANGES_REQUESTED`, or a `BLOCKED` the report does not account for — is a stop cause: return with the report as the question. A running check is neither: when the gate lists one and none of this row's stop causes, wait for it per "A running check is waited on" below; a report that lists one alongside a stop cause is returned on, not waited on |

The loop runs on a draft PR, before any review has been requested, so
on a repo whose rules require a review every PR reaches this gate
`BLOCKED` with nothing wrong: that is the one `BLOCKED` you return as
a terminal state. A state the table does not name is returned as a
question, as a `BLOCKED` with any other cause is.

**A running check is waited on**, not returned on. The gate runs
moments after the scrubber's push, and a required check that push
triggered is still `QUEUED` or `IN_PROGRESS` then — not green, and not
a failure either. A `BLOCKED` whose report lists a running check and
none of the stop causes the table's `BLOCKED` row names gets a wait
rather than a verdict: announce the wait, naming the checks still
running, wait **60 s**, and run the gate again, up to **10** times for
one spawn of this agent, so a running check is never the cause you
return on before it has had ten minutes to finish. A report that also
carries one of those stop causes is not waited on: the return is
decided already, and the wait would only delay it. Every running check
the gate lists holds the wait, required or not — a slow non-required
check holds the loop for the same bounded wait as a required one,
deliberately, rather than the loop guessing which checks the merge
depends on. A check still running after the last wait is returned as a
question like any other `BLOCKED` cause. The 60 s interval and the
10-wait bound are declared starting bounds, not measured ones; revise
them here if practice shows them wrong.

## The fixer brief, and the remedy spawns

**The fixer brief for `BEHIND` or `DIRTY`** is a PR comment whose
first line is the marker `<!-- sdlc:fixer-brief -->` — the literal by
which `issue-fixer` recognizes a brief, spelled in every `sdlc` file
that writes or reads it, so a change to it sweeps every file
`git grep -n 'sdlc:fixer-brief'` returns — and whose body is the gate's
report **verbatim** — the state and, for `DIRTY`, the
`pr-merge-conflicts` output — followed by the ruling your brief carries
when it carries one, whatever the state, and nothing you authored. The
brief is the only route by which a ruling reaches the fixer, and a
`BEHIND` whose fixer escalated comes back with one just as a `DIRTY`
does, so a brief that dropped it on any state would send the fixer back
to the same question. Write the body to a file under
`.claude/tmp/<task-slug>/` and post it with `gh pr comment <PR>
--body-file <path>`: the report quotes check names and hunks, and a
body spelled into `--body "…"` is read by the shell, backtick and `$`
alike.

Post it, and post nothing else on the PR until the fixer has run:
`issue-fixer` reads the PR's **most recent** comment and stops if that
comment is not a fixer brief.

Then run the remedy spawns, sequentially, waiting for each to return:

1. **`sdlc:issue-fixer`**, with the PR number and nothing else about
   the work — the brief on the PR is its instructions:

   ```text
   PR <PR_N> has a fixer brief waiting on it.

   Edit no documentation file as the sdlc:documentation-definition
   skill defines it; docs-writer has already written the PR's
   documentation.

   Address it per your agent definition. Report back what you fixed
   and what you didn't.
   ```

   A fixer that returns without having pushed — a conflict the ruling
   did not settle, an aborted rebase — has escalated: return with its
   report verbatim as the question, and run neither the scrubber nor
   the gate.

2. **`sdlc:agent-memory-scrubber`**, with the PR number and the branch
   name. `issue-fixer` declares memory, so its entries wait in the
   session's inbox until this pass, and the scrubber's commit has to be
   on the branch before the gate grades it — never run the gate between
   the two:

   ```text
   PR <PR_N> has settled a merge-readiness remedy. Branch: <branch-name>

   Curate the PR's agent memory per your agent definition. Report back
   what was transferred, what was deleted, and what was cut from or
   created as a destination file, where transfers landed, and the commit
   SHA you pushed — or, if nothing was staged, why.
   ```

Then run the gate again. No review round follows a remedy: the fixer's
commits are a rebase of what the loop already approved, and the gate
is what checks them.

## Report back

Your report carries:

- **The outcome** — one of:
  - `State: CLEAN`, `State: UNSTABLE`, or `State: BLOCKED
    (review-only)` — the loop left on a terminal state, and the
    close-out may proceed.
  - `Question:` followed by the gate's report verbatim — and, for
    `DIRTY`, the `pr-merge-conflicts` output — the state the loop
    stopped on, and what a ruling has to settle. The orchestrator
    relays it and re-spawns you with the ruling.
- **Every `issue-fixer` round you ran**: the state that drove it, the
  base the fixer rebased onto, each conflict and how the ruling had it
  resolved, and the new head SHA, as the fixer reported them.
- **The scrubber's per-entry and per-cut lines**, as it wrote them, for
  every scrubber pass you ran — they are the record of a destructive
  operation, and the human reviews them.
- **Every wait** you took on a running check, and the checks it named.
