# PR Lifecycle

What the orchestrator does to a PR from the moment its developer
reports it open to the moment it is flipped ready: the link to its
issues, the round-0 write that follows it, the body freeze that holds
through the review loop, the two
spawns that run on the human's end-of-loop confirmation, the close-out,
and the briefs for the two agents that carry the loops on either side
of the close-out.

## Link the PR to its issues, once the developer reports back

Before spawning the follow-up agents, call `/github-prs:pr-link-issue
<PR> <issues>` for the PR the developer just reported, passing the set
the PR **actually closes** — for a batch that dropped a member, a
subset of the branch's set. It is an idempotent safety-net that
normally no-ops, and running it unconditionally guarantees every
member carries its own closing keyword. The skill reconciles your
claim against the branch name itself; your job is not to ask it to
re-add a deliberately deferred member.

The PR number and the branch name the developer reported are
load-bearing — every follow-up agent and the review pipeline are
addressed with them. This call is where a wrong PR number surfaces
cheaply; read what it reports back rather than assuming the no-op.

## Write the ruled seed as round 0 of the PR's state

Once the PR is linked, and before `code-documenter` and the first
reviewer spawn, write the ruled seed as round 0 — the PR number now
exists to key the path on. Resolve `--owner` and `--repo`
with `gh repo view --json owner,name --jq '.owner.login + " " +
.name'`, and pass the file on stdin through a quoted heredoc, which is
what keeps a backtick or a `$` in a claim from reaching the shell:

```bash
sdlc-agent-result-persist --mode records \
  --owner <owner> --repo <repo> --pr <PR_N> --round 0 <<'RECORDS'
T1
claim: …
issues: …
settle-mode: …
pointers: …
RECORDS
```

The file holds every candidate the generator emitted, in id order, in
the record shape `sdlc:theorem-based-pr-reviewer` owns, with the
seed's rulings transcribed onto it:

- an **accepted** or **re-moded** theorem is a live record carrying
  **no `state` field** — it has never been attacked — with its
  `settle-mode` as ruled;
- a **rejected** theorem is `state: retired`,
  `state-detail: human-refuted`, `settled-at` the PR head, so no
  later default round revives it;
- a **merge** retires each merged theorem the same way and mints one
  new record continuing the id sequence — the human's claim, quoted;
  `settle-mode: semantic` unless the human said otherwise; `issues`
  and `pointers` the union of the merged theorems'. Ids are never
  reused.

Round 0 holds that file and nothing else — no log, no result files,
no review. The reviewer's round 1 reads it as its carried records and
takes the delta path over the whole branch.

## The PR body is frozen for the loop

The freeze closes as soon as the PR is linked to its issues.
`issue-developer` writes the body when the PR opens, and your one
`/github-prs:pr-link-issue` call appends whatever closing lines it is
missing immediately after — both of those land before the first review
round exists to be confused by them. From there until the loop ends,
**nothing edits the PR body**. Not you, and not any other teammate.
`pr-finalizer` writes one final section after the loop is over, in the
close-out below, and that is the whole exception.

The freeze is what makes the review's inputs testable. The body is the
one input that can change with no commit, no comment and no timestamp,
so a body edit contributes nothing to any round's delta: every later
round is empty-delta, carries its verdicts forward, and re-reports the
finding the edit fixed until the round cap runs out. So everything in
flight travels as a **PR comment** — the human's review adjustments
you relay and the fixer brief you write — which is append-only and
carries a timestamp the next round can cut against.

A PR-body claim the run made stale is not lost by this. Collect every
one the teammate reports name — a finding whose remedy is a body
change, a body change a fixer reports it did not make, a claim
`docs-writer` says a change falsified — say so in the round's report,
and carry each into the scope notes you hand `pr-finalizer`, quoted,
with what is true now. The fix lands once, at the end.

## The pre-readiness spawns, on the human's end-of-loop confirmation

Two teammates still put commits on the branch after the loop ends,
and both run before the merge-readiness loop so that what the gate
grades is what the human blesses. Spawn them in this order, and wait
for each to return.

1. **Spawn `docs-writer` to write the PR's documentation.** It runs
   once per PR, here, and no review round runs over its commit. Give it
   the PR number, the issue set the PR closes, and the branch name:

   ```text
   PR <PR_N> for issues <link-prefix><issue_N1>,
   <link-prefix><issue_N2>, … has finished its review loop.
   Branch: <branch-name>

   Write the PR's documentation per your agent definition. Report back
   every file you changed with a one-line reason (or "none"), the
   commit SHA you pushed, and anything the change made wrong that was
   not yours to fix — a PR-body claim, quoted, with what is true now.
   ```

   Its per-file list is the summary's `Doc Changes` cell, and it goes
   verbatim into the scope notes you hand `pr-finalizer`. A
   documentation change the human wants after reading it is a manual
   round, not a loop: this flow spawns `docs-writer` once.

2. **Spawn `agent-memory-scrubber` to curate the PR's agent memory.**
   By now every teammate that writes memory has captured into the
   session's inbox for this branch, so one pass grades the whole run's
   entries; the scrubber's commit is the last one on the branch before
   the gate runs. Give it the PR number and the branch name:

   ```text
   PR <PR_N> has settled its review loop. Branch: <branch-name>

   Curate the PR's agent memory per your agent definition. Report back
   what was transferred, what was deleted, and what was cut from or
   created as a destination file, where transfers landed, and the commit
   SHA you pushed — or, if nothing was staged, why.
   ```

   The scrubber's per-entry and per-cut lines are the record of what it
   deleted, transferred, and cut from a destination file, so pass them
   through to the human as it wrote them.

   A memory-declaring teammate spawned after the scrubber last ran
   leaves entries the scrubber has not seen, and none of them reports a
   *successful* capture back, so a spawn is the only evidence that
   entries may be waiting. Past this point the only such spawn is the
   `issue-fixer` a merge-readiness remedy runs, and `pr-merge-readiness`
   runs the scrubber itself after every one of those, so you spawn it
   here once. The only wrong placement is spawning it *early*, while
   more branch work is still expected.

## The brief for `pr-merge-readiness`

Give it the PR number and the branch name, and — on a re-spawn after
it returned with a question — the human's ruling, with the state and
the cause the question named, both copied from the `Question:` line of
the report that asked it: a ruling answers only the question it was
asked, and the state and cause together are how the re-spawn tells
whether the gate is still asking it:

```text
PR <PR_N> has been blessed. Branch: <branch-name>
Ruling on <STATE> (<cause>): <the human's answer, quoted, to the
question your last spawn returned with; <STATE> and <cause> are the
state and the cause that question named — or omit the line on the
first spawn>

Drive the PR to a merge-ready state per your agent definition. Report
back the state you reached, or the question you stopped on — its state
and cause, with the gate's report verbatim; any ruling this brief
carried that went unconsumed — by the gate's report, with what the
gate reported instead, or by the fixer's rebase on whatever state its
brief named, as the fixer reported it — quoted; every issue-fixer
round you ran; the scrubber's per-entry and per-cut lines as it wrote
them; and every wait you took on a running check, with the checks it
named.
```

## The close-out

Reached only when `pr-merge-readiness` returns with a terminal state,
and linear:

1. **Set every issue the PR closes to In Review.** The authoritative
   list of those issues is what `/github-prs:pr-closing-issues <PR>`
   reports — the one skill that reads a PR body's closing lines. Ask
   it rather than reusing the batch's planned membership: neither
   `/pr-create` nor `/pr-link-issue` writes a closing line for a
   member the developer **dropped**, so a dropped member is absent
   from that list and stays In Progress. Then flip each member it
   named with `/issue-set-status <N> "In Review"`, gated on the
   configured status slot as every status transition is. The flip
   lands before the finalizer because it is a tracker write the
   finalizer's section may mention.

2. **Spawn `pr-finalizer` to post the run's detail and amend the PR
   body.** The PR carries none of a round's argued detail while the
   loop runs; the finalizer posts it as a chain of PR comments and
   writes one section summarising the review rounds, the changes made
   in response, and any scope notes the run settled, replacing the
   section a previous run of this close-out left. Give it the PR
   number, the branch name, and the scope notes the run settled that
   the rounds themselves do not carry:

   ```text
   PR <PR_N> has finished its review loop. Branch: <branch-name>

   Scope notes this run settled, for the final section:
   <the deferrals, dropped members, and rulings the human made that
   the rounds do not carry; every PR-body claim the run made stale,
   quoted, with what is true now; and docs-writer's per-file list
   verbatim — or "none">

   Post the detail and write the final section per your agent
   definition. Report back what you posted and what you wrote.
   ```

   It reads the rounds out of state and the commits off the branch for
   the rest; that is its job, not yours to summarize into the brief.

3. **Flip the PR draft → ready:**

   ```text
   /github-prs:pr-ready <PR>
   ```

   This is the single point where the PR becomes mergeable; do **not**
   call `/pr-ready` earlier in the loop.

A close-out that fails partway is re-run from the merge-readiness loop
once the cause is settled, with no manual cleanup: a status flip
repeats harmlessly, the finalizer leaves a detail chain it finds
complete alone and overwrites its own section rather than stacking
one, and the ready flip no-ops on a PR already ready.

## The brief for `pr-monitor`

Give it the PR number, the branch name, and the resolved
`merge-poll-interval-seconds` and `merge-max-unchanged-polls` from
pre-flight, on every spawn — the first, and each re-spawn after a
`BEHIND` or `DIRTY` remedy or a yes to keep waiting:

```text
PR <PR_N> is ready for review. Branch: <branch-name>
Poll interval: <merge-poll-interval-seconds> seconds
Unchanged-poll bound: <merge-max-unchanged-polls>

Watch the PR per your agent definition. Report back which outcome
ended your loop and the state your last poll found.
```
