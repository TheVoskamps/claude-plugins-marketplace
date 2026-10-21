# PR Lifecycle

What the orchestrator does to a PR from the moment its developer
reports it open to the moment it is flipped ready: the link to its
issues, the round-0 write that follows it, the body freeze that holds
through both loops, the documentation loop's briefs and round
mechanics, the spawn that runs on the human's confirmation of that
loop's end, the close-out, and the briefs for the two agents that
carry the loops on either side of the close-out.

## Link the PR to its issues, once the developer reports back

The developer is `docs-writer` for a batch with no code to implement,
which skips the round-0 write below. First resolve the PR the developer
reported, by its URL, to its canonical reference, once:

```text
/github-prs:pr-view <PR URL> --ref
```

What it prints, `<host>/<owner>/<repo>#<N>`, is `<PR_REF>`: every
brief you write from here on names the PR by it, and every
`github-prs` verb and `sdlc-agent-result-persist --pr` call takes it as
it stands. Never resolve the repository yourself.

Then, before spawning the follow-up agents, call
`/github-prs:pr-link-issue <PR_REF> <issues>`, passing the set
the PR **actually closes** — for a batch that dropped a member, a
subset of the branch's set. It is an idempotent safety-net that
normally no-ops, and running it unconditionally guarantees every
member carries its own closing keyword. The skill reconciles your
claim against the branch name itself; your job is not to ask it to
re-add a deliberately deferred member.

`<PR_REF>` and the branch name the developer reported are
load-bearing — every follow-up agent and the review pipeline are
addressed with them. This call is where a wrong PR surfaces
cheaply; read what it reports back rather than assuming the no-op.

## Write the ruled seed as round 0 of the PR's state

Once the PR is linked, and before `code-documenter` and the first
reviewer spawn, write the ruled seed as round 0 — the PR now exists to
key the path on. Write the file with the Write tool to

```text
<session-scratchpad>/pr<N>-round0-records.md
```

where `<N>` is the number after the `#` of `<PR_REF>` and
`<session-scratchpad>` is the scratchpad directory the harness names in
your environment, then hand it to the script with `--from`:

```bash
sdlc-agent-result-persist --mode records \
  --pr <PR_REF> --round 0 \
  --from <session-scratchpad>/pr<N>-round0-records.md
```

The records never travel on the command line, in a heredoc or
otherwise; the `sdlc:agent-result-persist-interface` skill → "The
payload: `--from <path>`, or stdin" says why.

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
round exists to be confused by them. From there until the
documentation loop ends, **nothing edits the PR body**. Not you, and
not any other teammate. `pr-finalizer` writes one final section and
makes the last review round's closing-line corrections after both loops
are over, in the close-out below, and that is the whole exception.

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

Closing-line corrections need no collecting. Each round's reviewer
report carries a Closing-line corrections section, and the body does
not change during the loop, so the PR's last review round's section is
the whole current set: say in each round's report what its section
carries, and hand the last round's section on, verbatim, as the
`pr-finalizer` brief's `Closing-line corrections:` line.

## The documentation loop

The rounds of the loop `skills/orchestrate/SKILL.md` → "The
documentation loop" runs. Each opens with a `docs-writer` commit, then
`style-checker` and `theorem-based-pr-reviewer` under
`--mode documentation`, sequentially. The reviewer's spawn is the code
loop's with that mode; `style-checker`'s is:

```text
PR <PR_REF> has new commits on it.
Branch: <branch-name>
--mode documentation

Check the documentation against the rules under
`## For Authors and Checkers` per your agent definition. Report back
your findings, or that there are none.
```

**The first round's commit comes from the writing brief.** Give
`docs-writer` the PR reference, the issue set the PR closes, the
branch name, the deferred edits — every entry on the
`Deferred to docs-writer:` line of the developer's report and of every
fixer round's report on this PR, verbatim, or on a
`documentation loop needed` return, the `Deferred to docs-writer:`
entries that report relays and one entry per path on its
`Documentation conflicts:` line, as `<path> — a rebase conflict
issue-fixer resolved` —
and the documentation criteria: every bullet of the
`## Documentation acceptance` section, as `sdlc:orchestrate-readiness`
defines it, of every issue the PR closes, read off `/issue-view <N>`
for each. Collect the deferred entries as each report returns, and
raise none of them to the human: each is a documentation edit the
class rules hand to `docs-writer`, not open work.

```text
PR <PR_REF> for issues <link-prefix><issue_N1>,
<link-prefix><issue_N2>, … has finished its code loop.
Branch: <branch-name>
Deferred to docs-writer:
<every collected entry, verbatim, one per line — or "none">
Documentation criteria:
<each criterion, one per line, as `<member>: "<the bullet, verbatim>"`,
with `<member>` the issue as this brief's first line names it — or
"none">

Write the PR's documentation per your agent definition. Report back
every file you changed with a one-line reason (or "none"), the commit
SHA you pushed, each documentation criterion as met or not met, and
anything the change made wrong that was not yours to fix — a PR-body
claim, quoted, with what is true now.
```

On a batch with no code to implement the first commit comes from the
new-branch brief instead, which opens the PR as well:

```text
You are writing the documentation for issues <link-prefix><N1>,
<link-prefix><N2>, … in this repo, as one batch: one branch, one PR
closing all of them. No code loop runs for it.

Implementation order: <N1>, <N2>, …
Compound slug for the branch name: <compound-slug>
Documentation criteria:
<each criterion, one per line, as `<member>: "<the bullet, verbatim>"`>

Write the documentation, create the branch and open the PR per your
agent definition. Report back the PR URL, the issue set the PR closes,
the branch name, every file you changed with a one-line reason, the
commit SHA you pushed, and each documentation criterion as met or not
met.
```

For a batch of one, the opening line names the one issue, and the
`Implementation order` and `Compound slug` lines go away.

**Every `docs-writer` report's per-file list** is added to the
summary's `Doc Changes` cell, and goes verbatim into the scope notes
you hand `pr-finalizer`.

**A round's fixer brief** is posted on the PR in the shape the code
loop's is — `skills/orchestrate/SKILL.md` → "Handling review findings —
the fix loop", marker, finding-line rulings and owner rulings included
— carrying every finding of the round: the review's, `style-checker`'s
when the style-fix loop posts one, and each criterion the round's
`docs-writer` report graded `not met`, quoted, tagged to its member and
ruled `— in scope`. A `not met` criterion is a finding even when the
review approved, so it alone makes a fixer round. Post the brief, post
nothing else on the PR, then spawn `docs-writer` with this address and
nothing more:

```text
PR <PR_REF> has a fixer brief waiting on it.

Edit documentation only; the code loop has ended.

Address it per your agent definition. Report back what you fixed and
what you didn't, every file you changed with a one-line reason, and
the commit SHA you pushed.
```

Its commit opens the next round.

**The loop ends** on a round whose review is APPROVED with no finding
above Low and whose `docs-writer` report graded no criterion
`not met`, or when the documentation loop's round bound is reached
with a finding above Low still open, which goes to the human in the
final report. Either way the human's end-of-loop confirmation is what
moves the PR on. A BLOCKED round stops the loop short of both, until
the human rules on it, per `skills/orchestrate/SKILL.md` → "Handling
review findings — the fix loop".

## The pre-readiness spawn, once the documentation loop is confirmed

**Spawn `agent-memory-scrubber` to curate the PR's agent memory.**
By now every teammate that writes memory has captured into the
session's inbox for this branch, so one pass grades the whole run's
entries; the scrubber's commit is the last one on the branch before
the gate runs, so that what the gate grades is what the human blesses.
Give it the PR reference and the branch name:

```text
PR <PR_REF> has settled its review loop. Branch: <branch-name>

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
entries may be waiting. Past this point the only such spawns are the
`issue-fixer` a merge-readiness remedy runs, after which
`pr-merge-readiness` runs the scrubber itself, and the `docs-writer`
of a documentation loop that remedy needed, after which you spawn it
here again. The only wrong placement is spawning it *early*, while
more branch work is still expected.

## The brief for `pr-merge-readiness`

Give it the PR reference and the branch name — after a
`documentation loop needed` return, the same brief as a first spawn —
and, on a re-spawn after it returned with a question, the human's
ruling, with the state and
the cause the question named, both copied from the `Question:` line of
the report that asked it: a ruling answers only the question it was
asked, and the state and cause together are how the re-spawn tells
whether the gate is still asking it:

```text
PR <PR_REF> has been blessed. Branch: <branch-name>
Ruling on <STATE> (<cause>): <the human's answer, quoted, to the
question your last spawn returned with; <STATE> and <cause> are the
state and the cause that question named — or omit the line on the
first spawn>

Drive the PR to a merge-ready state per your agent definition. Report
back the state you reached, the question you stopped on — its state
and cause, with the gate's report verbatim — or that a documentation
loop is needed, with the fixer's entries that need it; any ruling this
brief carried that went unconsumed — by the gate's report, with what
the gate reported instead, or by the fixer's rebase on whatever state
its brief named, as the fixer reported it — quoted; every issue-fixer
round you ran; the scrubber's per-entry and per-cut lines as it wrote them;
every wait you took on a running check, with the checks it named; and
every spawn record that failed, with the CLI's message.
```

## The close-out

Reached only when `pr-merge-readiness` returns with a terminal state,
and linear:

1. **Spawn `pr-finalizer` to post the run's detail and amend the PR
   body.** The PR carries none of a round's argued detail while the
   loop runs; the finalizer posts it as a chain of PR comments and
   writes one section summarising the review rounds, the changes made
   in response, and any scope notes the run settled, replacing the
   section a previous run of this close-out left, and makes the
   closing-line corrections. Give it `<PR_REF>`, the branch name,
   the scope notes the run settled that the rounds themselves do not
   carry, and the last review round's Closing-line corrections
   section:

   ```text
   PR <PR_REF> has finished its review loop. Branch: <branch-name>

   Scope notes this run settled, for the final section:
   <the deferrals, dropped members, and rulings the human made that
   the rounds do not carry; every PR-body claim the run made stale,
   quoted, with what is true now; and docs-writer's per-file list
   verbatim — or "none">
   Closing-line corrections:
   <the last review round's Closing-line corrections section, verbatim:
   one per line, as `add <issue>` or `remove <issue>` — or "none">

   Post the detail and write the final section per your agent
   definition. Report back what you posted, what you wrote, and each
   closing-line correction as applied or not, with why.
   ```

   It reads the rounds out of state and the commits off the branch for
   the rest; that is its job, not yours to summarize into the brief.

   Each correction its report names as not applied becomes a **Needs
   Your Attention** row, quoting its line as the report gives it,
   raised before the ready flip.

2. **Set every issue the PR closes to In Review.** The authoritative
   list of those issues is what `/github-prs:pr-closing-issues <PR_REF>`
   reports now, after the finalizer's amendment — the one skill that
   reads a PR body's closing lines. Ask it rather than reusing the
   batch's planned membership, and apply no correction to its list by
   hand: neither `/pr-create` nor `/pr-link-issue` writes a closing
   line for a member the developer **dropped**, so a dropped member is
   absent from that list and stays In Progress, and a correction the
   finalizer did not apply is the human's, on its row. Flip each member
   of the list with `/issue-set-status <N> "In Review"`, gated on the
   configured status slot as every status transition is.

3. **Flip the PR draft → ready:**

   ```text
   /github-prs:pr-ready <PR_REF>
   ```

   This is the single point where the PR becomes mergeable; do **not**
   call `/pr-ready` earlier in the loop.

A close-out that fails partway is re-run from the merge-readiness loop
once the cause is settled, with no manual cleanup: a status flip
repeats harmlessly, the finalizer leaves a detail chain it finds
complete alone and overwrites its own section rather than stacking
one, and the ready flip no-ops on a PR already ready.

## The brief for `pr-monitor`

Give it the PR reference, the branch name, and the resolved
`merge-poll-interval-seconds` and `merge-max-unchanged-polls` from
pre-flight, on every spawn — the first, and each re-spawn after a
`BEHIND` or `DIRTY` remedy or a yes to keep waiting:

```text
PR <PR_REF> is ready for review. Branch: <branch-name>
Poll interval: <merge-poll-interval-seconds> seconds
Unchanged-poll bound: <merge-max-unchanged-polls>

Watch the PR per your agent definition. Report back which outcome
ended your loop and the state your last poll found.
```
