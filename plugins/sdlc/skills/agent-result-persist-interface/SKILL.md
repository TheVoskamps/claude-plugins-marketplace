---
name: agent-result-persist-interface
description: The contract for the sdlc-agent-result-persist CLI — its modes, its flags, the paths it composes, the line grammar of the round log it writes, and the per-round records and review files it stores. Preloaded into sdlc:theorem-based-pr-reviewer, the theorem-generator variants, sdlc:theorem-disprover, sdlc:counterexample-verifier, and sdlc:pr-finalizer via their skills frontmatter; not invoked from the user's slash menu.
user-invocable: false
---

# Agent Result Persist Interface

`sdlc-agent-result-persist` keeps one review round's evidence outside
every worktree: a **round log** of one-line records, one **result file**
per child holding that child's full report, the round's **records file**
holding its theorem records, and the round's **review file** holding the
argued review it composed. Any instance of
`sdlc:theorem-based-pr-reviewer` derives what is left to do from the log
and the result files, and from nothing it heard back; the next round
reads its predecessor's theorem records out of the records file, and the
end of an orchestrate loop assembles the run's detail out of the review
files.

That is the whole design. A child that ran, finished and reported can
still skip its own last call, and a `<task-notification>` can go
undelivered; both failures look identical from the caller's side, and
neither is recoverable from the caller's memory. So **the child writes
its own entry and its own exit**, and the caller's view of a child is
telemetry rather than truth.

`sdlc:theorem-based-pr-reviewer` anchors the round, records each spawn,
reads the log back, records a child it writes off, and at the end of the
round stores its records file and its review file. The theorem
generator, `sdlc:theorem-disprover` and `sdlc:counterexample-verifier`
each write their own `enter` and `leave`. **Every log record is a
single atomic append**, so no two writers can be ordered wrongly and no
call has to know what the log already holds. The records file and the
review file are not records: each is written whole and replaces
whatever the round held before, so a resumed instance that re-derives
the round stores its own version over its predecessor's rather than
adding to it. The carry form below builds the records from the round
below `--round`, never from the round's own, so the resumed instance's
records are rebuilt from the same input its predecessor's were.

## Invocation

```text
sdlc-agent-result-persist --mode <mode> \
  --pr <host>/<owner>/<repo>#<n> [--round <n>] \
  [mode-specific flags]
sdlc-agent-result-persist --mode list [<repository>]
sdlc-agent-result-persist --mode repos
```

Spell the command as a bare name, never by path: the rule that lets a
child run it unattended — `Bash(sdlc-agent-result-persist:*)` — is
keyed on that spelling, and it lives in the caller's own settings
because this plugin ships no permission rules.

## The payload: `--from <path>`, or stdin

`leave`, `records` and `review` each store a **payload** — a report, a
round's records, a round's review. The payload is read from the file
`--from <path>` names, or from **stdin** when no `--from` is passed.
With both present, `--from` wins and stdin is not read. Every other mode
refuses `--from`, since it has no payload to store.

Pass the payload with `--from`, naming a file you wrote with the Write
tool. The harness's worktree-isolation guard grades a heredoc on the
text it carries, and refuses the call when that text names `git`
anywhere — so a report that quotes a `git log` line or a
path under `.git/` cannot travel in a heredoc, and quoting it changes
nothing. The guard does not read a Write tool's content, and it never
sees the file's bytes on the persist call.

A child stages its `leave` payload in the session scratchpad the
harness names in its environment, at
`<session-scratchpad>/pr<pr>-r<round>-<stage>-<theorem>-<agent>-report.md`,
filling in the `--pr`, `--round`, `--stage`, `--theorem` and `--agent`
values of its own `leave` call, `pr<pr>` spelled as the state directory
spells it — the number after the `#` of `--pr`. Every child in a
fan-out shares that one scratchpad, so a name missing the stage, the
theorem or the agent would let two concurrent children stage over each
other's reports; theorem ids restart at `T1` on every PR, so a name
missing the PR would let two PRs' fan-outs in one session do the same;
and the persist script never
removes the file, so a name missing the round would leave an earlier
round of the same PR in the same session holding the path a later
round's child stages at.

If Write refuses because a file already exists at that path, Read it,
then Write again.

- A `--from` path that is not an existing file is refused, non-zero,
  with a message naming the path, before anything is written.
- A `--from` file that exists but cannot be read is refused, non-zero,
  with a message naming that file.
- An empty payload is refused either way, except by `records --carry`,
  whose payload is only the round's new records. With no `--from`, empty stdin
  gets `--mode <mode> takes the <noun> on stdin, and nothing arrived`;
  an empty `--from` file gets a message naming that file.
- The file is read, never moved or removed: it stays where its writer
  put it.

## The identifying flags

These two go on **every** call, and "The paths" below says what they
compose, except where a mode acts above the level a flag names and
refuses it: `delete` removes the whole PR's directory and `print-root`
names it, so each refuses `--round`, `list` reads across every PR of a
repository, so it refuses `--pr` and `--round` alike and takes the
repository instead, and
`repos` reads across every repository, so it refuses both and takes no
repository. `print-records` selects the round itself, so `--round` is
optional there and bounds that selection rather than naming a round.

- `--pr <host>/<owner>/<repo>#<n>` — the PR, by the canonical
  reference `/github-prs:pr-view <PR> --ref` prints: its repository,
  host included, since one machine holds state for repositories on
  several hosts and the same owner/repo on two of them is two
  repositories, then `#` and its number. Pass the reference you were
  given; never resolve the repository yourself. A bare number, or a
  reference without a host, is a usage error. Each of host, owner and
  repo may hold only letters, digits, `.`, `_` and `-`, and none may be
  `.` or `..`.
- `--round <n>` — a number. Rounds count review passes from 1, and
  **`--round 0` is valid**: the pre-loop seed, settled by the
  orchestrator before any implementer ran.

`list`'s repository is an optional operand, never a flag:
`<host>/<owner>/<repo>`, `https://<host>/<owner>/<repo>`, or a shorter
`<owner>/<repo>` or `<repo>`. Omitted, it is the current repository —
the one the checkout's remote names — and a shorter form takes the
segments it omits from the current repository. The script resolves the
current repository itself; pass the operand as you were given it, or
none.

**One round is one log.** There is no per-fan-out file and no `--agent`
in the path: the `stage` column below says which fan-out a record
belongs to, so two files can never disagree about the round and a
reader answers every stage's question from one `--mode print`.

## The paths

The script composes every path below and **no caller ever reads or
writes one by path** — there is no path string to mistype, and none to carry
across a turn boundary. A reader learns a result file's path by reading
it out of the log it just printed, and reaches the records and review
files through the print modes named for them rather than by path at
all.

A caller does spell the PR's state root
`${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/<host>/<owner>/<repo>/pr<pr>/` in
prose that points a **human** at the directory: the posted review
summary names it once and hangs a round-relative path off each theorem
and finding line, and every file that tells a reader where a round's
detail is spells the same root. That is a signpost, not a route:
nothing composes it to open a file with.

The round gets a **directory of its own**, and the identifying flags
are the whole of what composes it — no session is part of the path.
Each is a fact about the PR under review, which is what makes a round
survive the session that opened it: a reviewer resumed in a session
that never saw the first one holds both already, composes the same
path, and reads the same log. The state variable is used when
set and non-empty and `$HOME/.local/state` otherwise, and the script
spells that fallback once. This directory is where the whole of a
round's output lives: the theorem
records that the next round carries forward, and the argued review it
composed, are files here rather than text on the PR.

```text
${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/<host>/<owner>/<repo>/pr<pr>/round<round>/log
<the same directory>/<theorem>-<agent>
<the same directory>/records
<the same directory>/review
~/.claude/projects/<project>/<session>/subagents/agent-<agent-id>.jsonl
```

`log` is the round log, `<theorem>-<agent>` a child's result file,
`records` the round's theorem records, and `review` the round's argued
review; the `.jsonl` under `~/.claude/projects/` is the harness's own
transcript of a child, which `--mode enter` records. The records and
the review are written at the end of the round, and a voided round's
rename carries both with it exactly as it carries the log and the
result files.
`<project>` is the **primary clone's** path with every character
outside `[A-Za-z0-9-]` replaced by a dash — measured on a `/` and on a
`.` alike. Every child runs in a worktree, so its own cwd is the wrong
basis: the primary root is `git rev-parse --git-common-dir` passed
through `dirname`. `<session>` is `CLAUDE_CODE_SESSION_ID` and
`<agent-id>` is the child's own worktree name with `agent-` stripped.
The harness's per-session scratchpad holds an `.output` symlink to that
transcript; the record carries the target, which outlives the symlink.

With any of those unavailable the record still lands, carrying `-` in
the transcript column. A missing path is worth less than a missing
record.

The repository's directory, `sdlc/<host>/<owner>/<repo>/`, carries a
`repo.yml` naming the repository it holds, which the script writes when
it creates the directory:

```yaml
schema-version: 1
host: github.com
owner: <owner>
repo: <repo>
```

The file is what identifies the directory; no reader derives the
repository from the path's depth or segment names, and where the file
and the path disagree the file wins. State written before the host was
part of the path sits at `sdlc/<owner>/<repo>/`. Every run, of every
mode but `repos`, first moves that directory to `sdlc/<host>/<owner>/<repo>/`,
host from `--pr` or from `list`'s repository, and writes its
`repo.yml`; no mode reads the old path afterwards. A run that finds
state at both paths refuses, non-zero, naming both, and moves nothing.

**Nothing here is deleted but by `--mode delete`, and that mode is
called only by `/sdlc:orchestrate-cleanup`, a pass the human invokes.**
A round's files are the evidence a stalled or voided round is diagnosed
from, so no mode that runs during a review removes one, and none ever
expires: a PR's directory stays until the human decides its evidence is
no longer wanted, which is the one exception this policy makes.

## The modes

One word, one meaning: **every mode is named for what it writes** — the
record, or the file — the `print` modes for the ones that read one
round, `print-root` for the PR directory it names, `list` and `delete`
for what they do across a repo's PR directories, and `repos` for what
it lists across the state root.

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
    a tree that no longer exists, so the round's whole directory is
    renamed to `round<round>.voided-<instant>` — kept as the evidence
    of what the voided round did — and a fresh `round<round>/` holding
    only the new anchor takes its place. Nothing is deleted. The result
    files move with the log because a reader takes a report's existence
    as a settled theorem, and one left under its own name would settle
    the fresh round's theorem from the voided tree.
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
- **`leave`** — writes the child's report, read as its payload, to that
  child's result file, then appends one `leave` record naming the file.
  A child's final act. `--agent` is half the file's name. The report is
  stored byte for byte: no size limit, no encoding, no quoting. Empty
  input is refused — a `leave` exists to carry a report. The report is
  written before the record that names it, so a run that dies between
  the two leaves the report readable rather than a record pointing at
  nothing. Once both have landed, the call prints the result file's
  path on stdout, and that line is what a child's hand-back opens with,
  per "A child's hand-back" below; a refused `leave` prints nothing
  there.

  The payload lands first in `<result-file>.partial-<pid>` and is renamed into
  place only once it is whole, because a result file's mere existence
  settles its theorem: a report streamed straight to its own name would
  settle the theorem from a fragment the moment the first byte landed,
  and a child killed mid-write would leave that fragment there for
  good. The rename is what makes the file appear complete or not at
  all, and the `-<pid>` suffix is what keeps two writers from staging
  over each other. A refused report — empty, a `--from` file that
  could not be read, a `THEOREM:` mismatch or an id refusal below —
  leaves nothing behind: the staging file is removed before the call exits non-zero,
  and no `leave` record is appended.

  With `--stage disprove` or `--stage verify`, the report must answer
  the theorem it is filed under. The first line of the report that
  starts `THEOREM:` names that theorem, and the call is refused,
  non-zero, when no such line names one or when it names a theorem
  other than `--theorem`; the message names the `--theorem` value and,
  on a mismatch, the one the report named. A result file is named for
  `--theorem`, and its existence settles that theorem, so a report
  handed over from another child would otherwise settle a theorem it
  never answered.

  With `--stage generate` the report is the theorem list, filed under
  `--theorem list`, and its new ids must continue the records the round
  carries: those `print-records --round <round>` would print, or none
  when no round below `--round` holds records — round 0 included — so
  the list then starts at `T1`. Its ids are the lines holding nothing
  but `T<n>`, above any `RETIREMENTS` line, in order, and each is held
  to the rule the carry form holds a new record to: a new id a carried
  record already holds, or one that is not the next id in sequence, is
  refused, non-zero, with a message naming that id and the expected
  next one. The call is refused as `print-records` would be, too, when
  a round above `--round` holds records.
- **`return`** — appends one `return` record for `--theorem` in
  `--stage`, carrying `--agent-id` and the optional `--tokens`,
  `--tools` and `--ms`. The caller's, from a `<task-notification>` it
  received. It is **best-effort telemetry and never evidence**: no
  derivation below reads it, and a stage never waits on one. An omitted
  number leaves its column empty rather than dropping the column.
- **`stopped`** — appends one `stopped` record for `--theorem` in
  `--stage`, carrying `--agent-id`, the id of the child it writes off,
  as that child's `enter` record names it. The caller's, when it writes
  a child off. It writes one whether or not it `TaskStop`ped that
  child — a predecessor instance's child is never its to stop, and the
  record is what says the child was written off either way.
  `--agent-id` is required: without it the call exits non-zero and
  appends nothing, since a record naming only the theorem would write
  off whichever child the theorem had when it landed, a replacement
  included.
- **`print`** — writes the round log to stdout, followed by one
  `result` line per result file present. A `.partial-<pid>` staging
  from a `leave` still in flight is **skipped**, so a report reaches a
  reader whole or not at all, and so are the round's `records` and
  `review` files, which are the round's own output rather than any
  child's report. Exits non-zero when the log
  does not exist, which means neither the round's `anchor` call nor any
  child's `enter` has run — the fresh-round case the reviewer branches
  on before spawning anything.
- **`print-in-flight`** — writes to stdout one line per theorem with a
  child in flight in `--stage`, `<theorem> <agent-id> <instant>`: the
  child's agent id and the instant of its `enter`, which is what its
  deadline runs from. `--stage` and `--agent` are required, `--agent`
  naming the definition whose result file settles the theorem —
  `theorem-disprover` or `counterexample-verifier`, and for the theorem
  `list` the generator the last `spawn` record names. "What the reader
  derives" below states what in flight means. Exits non-zero when the
  log does not exist, as `print` does.
- **`records`** — writes the round's theorem records to the round's
  `records` file. Without `--carry` it stores its payload whole: the
  orchestrator's once, at `--round 0`, for the ruled seed, and the
  reviewer's on a round with nothing to carry. With `--carry`, below, it
  builds the file from the carried round: the reviewer's on every other
  round that reaches disposition, an empty-delta round included. In the
  plain form empty input is refused, and in both the bytes land in a
  staging name and are renamed into place only once whole, for the
  reason `leave` gives: a reader takes the file's existence as the
  round's records, and half a file would carry half a round's theorems
  into the next round with nothing saying so.

  A records file is a sequence of records in id order, separated by one
  blank line. Each opens with its id, `T<n>`, on a line of its own,
  followed by one `key: value` line per field: `claim`, `issues`,
  `settle-mode`, `pointers`, then, when present, `state`,
  `state-detail`, `settled-at`, `severity-override`, in that order. Ids
  are never reused.

  **With `--carry` the script builds the file itself** rather than
  taking one whole, and makes no decision while doing so — what each
  record's new state is arrives as an edit:

  1. It reads the records of the highest-numbered round **below**
     `--round` that holds a records file, skipping the
     `.voided-<instant>` directories as `print-records` does. A records
     file at `--round` itself is not read: `--round` may be the latest
     round holding records, and the carry then rebuilds that round's
     file from the round below, so a resumed reviewer stores its round's
     records again and gets the same file from the same edits. It
     refuses when any round **above** `--round` holds a records file.
  2. It applies the **edits file** `--edits <path>`, one edit per line:
     `<id>`, a tab, `<field>`, a tab, `<value>`. `<value>` is the rest
     of the line and may be empty; an empty line is skipped. `<field>`
     is one of `state`, `state-detail`, `settled-at` and
     `severity-override`. An edit to a field the record has replaces its
     line in place; an edit to a field it lacks adds the line after the
     record's other fields, the added lines in that same order. Only
     `state` is validated — it is `disproved`, `unsettled` or `retired`
     — and the other three are stored verbatim. `--edits` is optional:
     a round that changes no carried record passes none.
  3. It appends the **new records** read as its payload, in the record
     shape above. Their ids, in payload order, are exactly `T<m+1>`,
     `T<m+2>`, … where `T<m>` is the highest carried id. The payload may
     be empty here, so an empty-delta round and a round that only
     retires are both written.
  4. It writes the result in id order, staged and renamed into place as
     the plain form is.

  No carried record gains or changes a field that no edit names. Every
  round from 1 on stamps a `state` on every record, so the result must
  hold one on each.

  Each of these is refused, non-zero, writing nothing and creating no
  round directory, with a message naming the offending line or id:

  - an edit line that is not three tab-separated parts;
  - an edit naming an id no carried record has;
  - an edit to a field outside the four;
  - a `state` value outside the three;
  - a second edit to the same field of the same record;
  - a new record whose id a carried record already holds, or that is not
    the next id in the `T<m+1>`, `T<m+2>`, … sequence;
  - a result that leaves any record without `state` — a round-0 seed
    record carried into round 1 unstamped is the case this catches —
    naming each such id;
  - `--carry` when no round below `--round` holds a records file, or
    when a round above it does, naming that round;
  - `--edits` without `--carry`, and `--carry` in any mode but
    `records`.
- **`review`** — writes the round's argued review, read as its payload,
  to the round's `review` file, on the same terms as `records`.
- **`print-records`** — writes to stdout the records of the
  **highest-numbered** round that holds a records file, ignoring the
  `.voided-<instant>` directories, whose records describe a tree that no
  longer exists. The round to carry forward is the most recent one
  there is, not one a caller names. A `--round <n>` bounds the
  selection to the rounds **below** `<n>`, and `<n>` need not hold
  records itself: a round under way passes its own number, so it reads
  the round it carries from even when an earlier instance of it already
  stored this round's records. With `--round <n>` it exits non-zero,
  printing no records, when any round **above** `<n>` holds a records
  file — the condition `--carry` refuses on, decided by the same code —
  so a stale `--round` fails at this read rather than at the carry
  that follows it. Its first line is `round <n>`, naming the
  round it selected, so a reader that needs the rest of that round's
  state — its `anchor` line's head SHA, its review file — has the number
  to ask for it with; the records follow from the second line on. Exits
  non-zero when no round it considers holds a records file — a PR whose
  round 1 has no round-0 seed to read.
- **`print-round-records`** — writes the named round's records file
  to stdout, byte for byte, with no `round <n>` line in front: the
  caller named the round. It is the read for a caller that walks every
  round rather than carrying the most recent one forward, and it
  creates nothing. Exits non-zero when that round holds no records
  file.
- **`print-review`** — writes the named round's review file to stdout.
  Exits non-zero when that round holds none.
- **`print-root`** — writes the PR's state root to stdout as one line,
  `${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/<host>/<owner>/<repo>/pr<pr>/`
  expanded, trailing `/` included. It is the signpost "The paths"
  describes, composed here so a caller that names a file to a human
  relative to the root spells no root of its own; it opens nothing. It
  takes **no `--round`** and refuses one, creates nothing, and exits
  zero whether or not the directory exists.
- **`list`** — writes to stdout one PR per line, as the
  `<host>/<owner>/<repo>#<n>` reference `--pr` takes, in ascending
  order of `<n>`, one per `pr<n>/` directory under the repository's
  `<host>/<owner>/<repo>/` state directory, and nothing else on the line; an
  entry whose name is not `pr` followed by digits, or that is not a
  directory, is skipped. The repository is the operand "The identifying
  flags" describes. It takes **no `--pr` and no `--round`**, and
  refuses either, and refuses a second operand. A repository no review
  has run against has no directory, so the output is empty and the exit
  zero; the mode creates nothing.
- **`delete`** — removes `pr<n>/` recursively, every round under it
  and every voided round with them. It takes **no `--round`** and
  refuses one, and it refuses a missing `--pr` with the usual
  `--pr is required` message. A directory already absent is the state
  the call asks for, so it exits zero and prints nothing.
- **`repos`** — writes to stdout one line per repository directory the
  state root holds, `<kind> <repository> <directory>`, the directory
  relative to `sdlc/`. Every directory holding a `repo.yml` is read
  from that file: `repo` when the file names the directory's own path,
  `mismatch` when it names another, the repository being the file's
  `<host>/<owner>/<repo>` either way. A directory two levels down
  that has no `repo.yml` in it or one level down, and holds
  `pr<n>/` directories directly, is old-layout state: `old <owner>/<repo> <owner>/<repo>`,
  its host unknown. It takes **no repository, no `--pr` and no
  `--round`**, refuses each, moves nothing, and prints nothing for a
  state root that does not exist.

  **`delete` is the only mode that deletes stored state.** The one
  thing any other mode removes is its own staging file, when `leave`,
  `records` or `review` refuses its payload as empty or as a `--from`
  file that could not be read, or `leave` refuses a report whose
  `THEOREM:` line does not name `--theorem` or a theorem list whose ids
  do not continue the carried records; `anchor` renames a voided round rather
  than removing it.

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
stopped <theorem> <stage> <instant> <agent-id>
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
agent id that no `leave` and no `stopped` of that theorem carries, and
no result file for it under `--agent` exists. `--mode print-in-flight`
is that derivation, and the only one: ask it rather than reading the
answer off the log yourself. A `stopped` is matched to an `enter` by
agent id, never by where it lands, so an original child's `stopped`
that lands after its replacement's `enter` writes off the original
alone and leaves the replacement in flight.

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
theorem with two `leave` records. When the replacement carried the
same `--agent` name as the child it replaced — which every stage but
`generate` guarantees, there being one definition per stage — the two
share a result-file name and there is one file, the later child's,
since its rename overwrote the earlier report. So the theorem's
verdict is the later child's by construction: it is the verdict in the
one file there is to read, and no reader has a tie to break. A
replacement carrying a different `--agent` name writes a file of its
own instead, leaving the theorem two, and the reader picks between
them by the log rather than by the directory. Both records stay in the
log, because the pair is evidence that a child believed dead was
alive, and the reader reports it as such. No line is revised, so
concurrent appends cannot collide.

## A child's hand-back

A child's `leave` record and result file land before the child
returns, so by the time its `<task-notification>` reaches the caller a
missing `leave` is final rather than a race. A child therefore makes
its `leave` call before it composes its hand-back, and composes one only
from what that call did:

- **The call succeeded** — the hand-back's first line is the
  result-file path the call printed, and the report the file holds
  follows it.
- **The call failed** — the hand-back is a failure report carrying no
  verdict and no theorem, so nothing the caller reads from it can stand
  in for the result file that was never written:

  ```text
  LEAVE FAILED
  COMMAND: <the leave command, as run>
  OUTPUT: <everything it printed, verbatim>
  ```
