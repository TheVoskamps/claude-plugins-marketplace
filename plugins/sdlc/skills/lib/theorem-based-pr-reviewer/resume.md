# Resuming a review round (`skills/lib/theorem-based-pr-reviewer/resume.md`)

Every wait in the review workflow is the resume loop below, over one
stage, and every re-spawn it makes is counted by the resume-pass loop.

## The resume-pass loop

**Loop while progress continues; hard-stop at 7 resume passes.** A
**resume pass** is one round of re-spawning what `next` shows
unsettled, waiting, and reading again; only a pass spawns anything.
**One count spans every stage**, every re-spawn after a deadline
write-off a pass on it. Take another only while the last settled a
theorem the log did not already have, and stop at 7 whatever happened.
The count is your instance's; your caller bounds the instances.

**A stalled stage posts.** When the resume-pass loop exits — either
exit — with `disprove`- or `verify`-stage theorems that have no verdict,
the round moves on to "Dispose the round", which gives each such
theorem its no-verdict row, and posts the review. Only in the
`generate` or `assess` stage is a loop exit an escalation, since a
round with no settled theorem list has nothing to post: report an
in-progress status naming the stage and the exit you took.

**Never `TaskStop` a child you did not spawn** — a predecessor's are not
yours, and several sessions may run against one repo. Report a stall as
what the log shows, never as starvation; a `TaskStop` returning `No
task found with ID` reads as gone, leaving its theorem re-runnable.

## The resume loop

You end your turn, and the harness resumes you on a child's
`<task-notification>` or on the exit of the wait command below. Every
resume runs the same three moves, in order, over **every** outstanding
child in the stage, so one surviving notification carries the round
past every lost one.

1. **Record a final notification** that woke you with a `--mode return`
   record, with its agent id and whatever token, tool-call and duration
   figures it gave. A notification naming no agent id, and the wait
   command's exit, get no record. The record is telemetry: a child is
   finished only when it writes its own `leave`, and one that handed
   back can still be running.
2. **Run `--mode next`**, per "You are re-entrant". Its deadline is the
   **15 minutes after a child's `enter`** you pass — five times the
   worst case measured on a 32-theorem round, where every disprover
   reported inside three minutes, a figure the generator, the assessor
   and the verifiers reuse; from `enter`, so a child queued behind the
   ceiling does not read as slow.
3. **End the turn, or act on the lines**, in the stage its arm names:
   an `overdue` line takes the deadline arm, and a child with any other
   line stays in flight, whatever its hand-back said, so it is never
   written off or its theorem re-spawned before its deadline. An arm
   that moved on ends this stage's wait.

**Start the wait command before you end a turn that waits on a stage**,
with the Bash tool's `run_in_background`, so that a wait you started
over that stage is running whenever such a turn ends — skip the start
only while one you started over the stage has not yet exited:

```bash
sdlc-agent-result-persist --mode wait \
  --pr <PR_REF> --round <this round's number> --stage <stage> --deadline-minutes 15
```

While it runs, your run outlives a child that ended its turn over
background work of its own. Its exit is a resume like any other, even
when no notification arrives: run this loop.

**A turn you end while a `--mode wait` you started is running is not a
hand-back**: its exit resumes you, so the turn carries no report and no
`Return:` line. Only when you stop with stages unfinished and no such
wait running do you hand back an in-progress status, and it reads as
one — the theorems still out named by id, never counted, with their
stage, and no verdict block, tally or findings — since the harness
surfaces every turn-end as `status: completed`.

## The deadline arm

For an `overdue` line, `TaskStop` its child if **you** spawned it,
before its theorem is re-spawned, and append its stop either way,
naming it by the agent id the line printed. For an `overdue` line whose
agent id is `-`, `TaskStop` its child by the id its `Agent` call
returned, and append the stop with `-`:

```bash
sdlc-agent-result-persist --mode stopped \
  --pr <PR_REF> --round <this round's number> \
  --theorem <T<k>, or list> --stage <stage> --agent-id <that child's agent id>
```

A write-off is `TaskStop`'s one sanctioned use; never reach for it to
make a slow round finish sooner. With passes left, run `--mode next`
again, spawn on its `outstanding` lines, and wait again. A
`<task-notification>` is a wake-up, not evidence, and you are no more a
source of verdicts than of theorems.
