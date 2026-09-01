---
name: agent-result-persist-interface
description: The contract for the sdlc-agent-result-persist CLI — its modes, its flags, the paths it composes, and the line grammar of the round log it writes. Preloaded into sdlc:theorem-based-pr-reviewer, the theorem-generator variants, sdlc:theorem-disprover, and sdlc:counterexample-verifier via their skills frontmatter; not invoked from the user's slash menu.
user-invocable: false
---

# Agent Result Persist Interface

`sdlc-agent-result-persist` keeps one review round's evidence outside
every worktree: a **round log** of one-line records, and one **result
file** per child holding that child's full report. Any instance of
`sdlc:theorem-based-pr-reviewer` derives what is left to do from those
two, and from nothing it heard back.

That is the whole design. A child that ran, finished and reported can
still skip its own last call, and a `<task-notification>` can go
undelivered; both failures look identical from the caller's side, and
neither is recoverable from the caller's memory. So **the child writes
its own entry and its own exit**, and the caller's view of a child is
telemetry rather than truth.

`sdlc:theorem-based-pr-reviewer` anchors the round, records each spawn,
reads the log back, and records a child it writes off. The theorem
generator, `sdlc:theorem-disprover` and `sdlc:counterexample-verifier`
each write their own `enter` and `leave`. **Every record is a single
atomic append**, so no two writers can be ordered wrongly and no call
has to know what the log already holds.

## Invocation

```text
sdlc-agent-result-persist --mode <mode> \
  --scratchpad <dir> --owner <owner> --repo <repo> \
  --pr <n> --round <n> [mode-specific flags]
```

Spell the command as a bare name, never by path: the rule that lets a
child run it unattended — `Bash(sdlc-agent-result-persist:*)` — is
keyed on that spelling, and it lives in the caller's own settings
because this plugin ships no permission rules.

## The identifying flags

These five go on **every** call in every mode, and they are the whole
of what the log's path is composed from:

- `--scratchpad <dir>` — the harness's per-session scratchpad
  directory, as the reviewer's own context names it, passed down
  verbatim. Never hand-build a lookalike path: the uid in
  `/tmp/claude-<uid>/` varies per machine and the session segment is
  not a child's to compute.
- `--owner <owner>` and `--repo <repo>` — two values, not one
  `owner/name` token, whose `/` would add a directory level to the
  path. Neither may carry a path separator or whitespace.
- `--pr <n>` and `--round <n>` — numbers.

**One round is one log.** There is no per-fan-out file and no `--agent`
in the path: the `stage` column below says which fan-out a record
belongs to, so two files can never disagree about the round and a
reader answers every stage's question from one `--mode print`.

## The paths

The script composes all three and **no caller ever holds one** — there
is no path string to mistype, and none to carry across a turn
boundary. A reader learns a result file's path by reading it out of the
log it just printed.

```text
<scratchpad>/sdlc/theorem-based-pr-reviewer-<owner>-<repo>-pr<pr>-round<round>
<the same>-<theorem>-<agent>
~/.claude/projects/<project>/<session>/subagents/agent-<agent-id>.jsonl
```

The first is the round log, the second a child's result file, the third
the harness's own transcript of a child, which `--mode enter` records.
`<project>` is the **primary clone's** path with every character
outside `[A-Za-z0-9-]` replaced by a dash — measured on a `/` and on a
`.` alike. Every child runs in a worktree, so its own cwd is the wrong
basis: the primary root is `git rev-parse --git-common-dir` passed
through `dirname`. `<session>` is `CLAUDE_CODE_SESSION_ID` and
`<agent-id>` is the child's own worktree name with `agent-` stripped.
The scratchpad's `.output` file is a symlink to that transcript; the
record carries the target, which outlives the symlink.

With any of those unavailable the record still lands, carrying `-` in
the transcript column. A missing path is worth less than a missing
record.

## The modes

One word, one meaning: **every mode is named for the record it
writes**, and `print` for the one that reads.

- **`anchor`** — writes the `anchor` line carrying `--head-sha <sha>`.
  One call per round, and **idempotent**, which is what lets the
  reviewer make it without knowing whether a child has already written:

  - **No `anchor` in the log** — the line is appended, creating the log
    when it is absent. A child that started first has already created
    it with its own `enter`, so the anchor is not necessarily the first
    line and no reader may assume it is.
  - **An `anchor` naming the same head SHA** — this same round's, so
    the call writes nothing and exits zero.
  - **An `anchor` naming a different head SHA** — the records describe
    a tree that no longer exists, so the log **and every result file
    beside it** are renamed under `<file>.voided-<instant>` — kept as
    the evidence of what the voided round did — and the new anchor is
    written in its place. Nothing is deleted. The result files move
    with the log because a reader takes a report's existence as a
    settled theorem, and one left under its own name would settle the
    fresh round's theorem from the voided tree.
- **`spawn`** — appends one `spawn` record for `--theorem` in
  `--stage`, carrying `--agent`, `--model` and `--effort`. The
  caller's, once per child it spawns. Model and effort are on this
  record because the caller chose them and a child can read neither;
  pass the token `default` where the spawn named none and the
  definition's own frontmatter decided.
- **`enter`** — appends one `enter` record for `--theorem` in
  `--stage`. A child's first act, before it does any work. The script
  derives the agent id from the child's own worktree and composes the
  transcript path, so nothing is passed in.
- **`leave`** — writes the child's report, read from **stdin**, to that
  child's result file, then appends one `leave` record naming the file.
  A child's final act. `--agent` is half the file's name. The report is
  stored byte for byte: no size limit, no encoding, no quoting. Empty
  input is refused — a `leave` exists to carry a report. The report is
  written before the record that names it, so a run that dies between
  the two leaves the report readable rather than a record pointing at
  nothing.

  Stdin lands first in `<result-file>.partial-<pid>` and is renamed into
  place only once it is whole, because a result file's mere existence
  settles its theorem: a report streamed straight to its own name would
  settle the theorem from a fragment the moment the first byte landed,
  and a child killed mid-write would leave that fragment there for
  good. The rename is what makes the file appear complete or not at
  all, and the `-<pid>` suffix is what keeps two writers from staging
  over each other. A refused empty report leaves nothing behind: the
  staging file is removed before the call exits non-zero.
- **`return`** — appends one `return` record for `--theorem` in
  `--stage`, carrying `--agent-id` and the optional `--tokens`,
  `--tools` and `--ms`. The caller's, from a `<task-notification>` it
  received. It is **best-effort telemetry and never evidence**: no
  derivation below reads it, and a stage never waits on one. An omitted
  number leaves its column empty rather than dropping the column.
- **`stopped`** — appends one `stopped` record for `--theorem` in
  `--stage`. The caller's, at a child's deadline. It writes one whether
  or not it `TaskStop`ped that child — a predecessor instance's child
  is never its to stop, and the record is what says the child was
  written off either way.
- **`print`** — writes the round log to stdout, followed by one
  `result` line per result file present. A `.partial-<pid>` staging
  from a `leave` still in flight is **skipped**, so a report reaches a
  reader whole or not at all. Exits non-zero when the log
  does not exist, which means neither the round's `anchor` call nor any
  child's `enter` has run — the fresh-round case the reviewer branches
  on before spawning anything.

The script stamps every record's time itself: the writer owns when the
record was made.

A refusal and a malformed call both exit non-zero, so the status says
only that the call did nothing. The message says which.

## The line grammar

One record per line, whitespace-separated columns, appended, and **no
line is ever revised in place**:

```text
anchor  <instant> <head-sha>
spawn   <theorem> <stage> <instant> <agent> <model> <effort>
enter   <theorem> <stage> <instant> <agent-id> <transcript-path>
leave   <theorem> <stage> <instant> <agent-id> <result-file>
return  <theorem> <stage> <instant> <agent-id> tokens=<n> tools=<n> ms=<n>
stopped <theorem> <stage> <instant>
```

`--mode print` adds one line per result file it finds, synthesized from
the directory at read time and stored nowhere:

```text
result  <theorem> <agent> <result-file>
```

Every instant is `date -u +%Y-%m-%dT%H:%M:%SZ`. `<stage>` is
`generate`, `disprove` or `verify`. The script rejects any column value
carrying whitespace, which would shift its own line's columns.

A `result` line carries the agent rather than the stage because that is
what the file's own name holds, and the name is split back apart at its
first dash — so a theorem id carries no dash and the script refuses one
that does. Which stage a result belongs to follows from the agent that
wrote it.

The generation stage answers no single theorem, so its theorem column
is the literal `list` — the thing it produces. Every other stage's is a
theorem id.

**Two lifecycles share the log, and the split is what keeps the
vocabulary from drifting the next time a kind is added.** `spawn`,
`return` and `stopped` are the caller's view of a child — it asked for
one, it heard back about one, it wrote one off. `enter` and `leave` are
the child's own — it began, and it finished. A caller therefore never
writes an `enter` or a `leave`, and a child never writes any of the
other three.

A `spawn` record is written per child rather than per theorem, so a
theorem re-spawned in a later wave carries one for each attempt. That
is what makes a child that never started distinguishable from one that
started and vanished. The derivations below read `spawn` as a set of
theorem ids, so the repeats change nothing they answer.

The `anchor` line's `<head-sha>` is the head commit the round's
theorems were generated against, and it is what a resume compares
against `origin/<branch>` before trusting a single record: a scheduled
sweep force-rebases open PR branches and can fire mid-round, and
verdicts from two trees must never be mixed.

## What the reader derives

**Everything that changes as the round runs is derived on each read,
never stored.** A stored list is a line that must be revised to stay
true; a derived one cannot go stale.

**A theorem is settled in a stage when its child wrote `leave`, or when
its result file exists** — never when the caller heard back. The two
are almost always the same fact, and the second is what covers a child
that wrote its report and died before the record landed:

```bash
awk '$1=="spawn"  && $3==stage {s[$2]=1}
     $1=="leave"  && $3==stage {delete s[$2]}
     $1=="result" && $3==agent {delete s[$2]}
     END{for(t in s) print t}' stage=disprove agent=theorem-disprover
```

What that leaves is the stage's **outstanding** set, over the theorems
the log was told about. A caller holding a list of its own — the round's
live list, say — asks the question the other way round and subtracts the
settled and in-flight sets from that list, which is what puts a theorem
no instance ever spawned back in play.

The verdict itself
is in the result file, which the `leave` line names and the `result`
line names again — read the file, do not infer the verdict from the
log.

**Whether an outstanding theorem has a child in flight is a second
question, and it is keyed on the child rather than on the theorem.** A
theorem is in flight when its **last** `enter` in that stage carries an
agent id that no `leave` of that theorem carries, and no `stopped`
follows that `enter`:

```bash
awk '$1=="enter"   && $3==stage {child[$2]=$5; gone[$2]=0}
     $1=="stopped" && $3==stage {gone[$2]=1}
     $1=="leave"   && $3==stage {done[$2" "$5]=1}
     $1=="result"  && $3==agent {left[$2]=1}
     END{for(t in child) if(!gone[t] && !(t in left) && !((t" "child[t]) in done)) print t}' \
  stage=disprove agent=theorem-disprover
```

That is the question a deadline arm asks — an outstanding theorem with
no child in flight has nothing to be overdue — and the one the next
wave asks before spawning.

`stopped` kills the **child**, not the **theorem**: it subtracts from
in-flight and not from outstanding. A derivation that left the child in
flight would report the theorem overdue on every later read and take
the deadline arm against a child already written off; one that
subtracted the theorem from the outstanding set would report an
unanswered theorem as settled. The `enter` record, not this one, is
what names the stopped child's worktree for cleanup.

**A duplicate `leave` is a diagnostic, not a conflict, and the later
one wins.** A child written off as lost can report anyway, leaving one
theorem with two `leave` records and one result file — the later
child's, since its rename overwrote the earlier report. So the
theorem's verdict is the later child's by construction: it is the
verdict in the one file there is to read, and no reader has a tie to
break. Both records stay in the log, because the pair is evidence that
a child believed dead was alive, and the reader reports it as such. No
line is revised, so concurrent appends cannot collide.
