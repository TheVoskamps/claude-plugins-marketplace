---
name: agent-result-persist-interface
description: The contract for the sdlc-agent-result-persist CLI — its modes, its flags, the path it composes, and the line grammar of the file it writes. Preloaded into sdlc:theorem-based-pr-reviewer, sdlc:theorem-disprover, and sdlc:counterexample-verifier via their skills frontmatter; not invoked from the user's slash menu.
user-invocable: false
---

# Agent Result Persist Interface

`sdlc-agent-result-persist` records one review fan-out's results in a
file outside every worktree, so a `<task-notification>` the harness
never delivers cannot take its child's result with it. A notification
is a wake-up; a record in this file is the evidence.
`sdlc:theorem-based-pr-reviewer` creates a fan-out's file and reads it
back; `sdlc:theorem-disprover` and `sdlc:counterexample-verifier`
append their own entry and their own result to it.

The file is also what a **resumed** round picks itself up from: a
reviewer re-spawned over a round that already has one keeps every
theorem the file says is settled and re-runs only the rest, rather
than starting the round over. `sdlc:theorem-based-pr-reviewer` → "The
round state file" owns that procedure; this file owns the record
grammar it reads.

## Invocation

```text
sdlc-agent-result-persist --mode <mode> \
  --scratchpad <dir> --owner <owner> --repo <repo> \
  --pr <n> --round <n> --agent <name> [mode-specific flags]
```

A child derives its own `--agent-id` from its cwd: every theorem agent
runs `isolation: worktree`, and the harness names that worktree
directory `agent-<agent-id>`, carrying the same token `TaskStop`
accepts. `basename "$PWD"` with the `agent-` prefix stripped is the id,
and no harness affordance beyond that is needed.

Spell the command as a bare name, never by path: the rule that lets a
child run it unattended — `Bash(sdlc-agent-result-persist:*)` — is
keyed on that spelling, and it lives in the caller's own settings
because this plugin ships no permission rules.

## The identifying flags

These six go on **every** call in every mode, and they are the whole of
what the path is composed from:

- `--scratchpad <dir>` — the harness's per-session scratchpad
  directory, as the reviewer's own context names it, passed down
  verbatim. Never hand-build a lookalike path: the uid in
  `/tmp/claude-<uid>/` varies per machine and the session segment is
  not a child's to compute.
- `--owner <owner>` and `--repo <repo>` — two values, not one
  `owner/name` token, whose `/` would add a directory level to the
  path. Neither may carry a path separator or whitespace.
- `--pr <n>` and `--round <n>` — numbers.
- `--agent <name>` — the **fan-out** this file belongs to, either
  `theorem-disprover` or `counterexample-verifier`, never the
  individual child. One round has two files, and neither can answer
  for the other.

## The path

The script composes it and **no caller ever holds it** — there is no
path string to mistype, and none to carry across a turn boundary:

```text
<scratchpad>/sdlc/theorem-based-pr-reviewer-<owner>-<repo>-pr<pr>-round<round>-<agent>
```

## The modes

- **`header`** — creates the file and writes `--header <text>` to it
  verbatim. The reviewer's one call per fan-out, on a **fresh** round
  only. It **refuses a file that already exists**, exiting non-zero and
  writing nothing: every record already there is a result no
  notification can be asked to redeliver. The reviewer calls `print`
  first and reaches `header` only where that failed, so the refusal is
  a backstop rather than the resume path — one a child starting in
  between can still trip, which sends the reviewer back to `print`
  rather than ending its round.

  **One case is not a refusal**: the existing file's `anchor` and the
  incoming header both name a head SHA, and the two differ. The records
  then describe a tree that no longer exists and answer nothing the new
  round will ask, so the old file is renamed to
  `<file>.voided-<instant>` — kept as the evidence of what the voided
  round did — and the new header is written in its place. Nothing is
  deleted, and a header carrying no parseable `anchor` head SHA is
  refused as usual rather than guessed at.
- **`enter`** — appends one `enter` record for `--theorem <id>`
  carrying `--agent-id <id>`. A child's first act, before it does any
  work. It is what makes the child's deadline measurable: `Agent()`
  calls beyond the harness's concurrency ceiling queue, so a child
  spawned at the round anchor may not begin for many minutes, and a
  child with no `enter` record has not started at all.
- **`detail`** — appends one `return` record for `--theorem <id>`
  carrying `--agent-id <id>` and `--result <token>`. A child's final
  act. `--result` takes any single token; the vocabulary is each
  agent's own and the script grades it no further. Creates the file
  when it is absent rather than discarding the result.
- **`stopped`** — appends one `stopped` record for `--theorem <id>`.
  The reviewer's, at a child's deadline. It writes one whether or not
  it `TaskStop`ped that child — a predecessor instance's child is never
  its to stop, and the record is what says the child was written off
  either way. A stop is its own record kind, never a `return` carrying a `STOPPED`
  result — a `return` is a verdict, and the reviewer is not a source of
  verdicts.
- **`print`** — writes the file to stdout. Exits non-zero when the file
  does not exist, which means the fan-out's `header` call never ran.

The script stamps each `enter`, `return` and `stopped` time itself: the
writer owns when the record was made.

A refusal and a malformed call both exit non-zero, so the status says
only that the call did nothing. The message says which.

## The line grammar

One record per line, whitespace-separated columns, appended, and **no
line is ever revised in place**:

```text
anchor  <anchor-instant> <head-sha>
spawn   <theorem-id> <iso-time>
enter   <theorem-id> <iso-time> <agent-id>
return  <theorem-id> <iso-time> <agent-id> <result>
stopped <theorem-id> <iso-time>
```

Every instant is `date -u +%Y-%m-%dT%H:%M:%SZ`. There is no stage
column: `--agent` keys the file. The script rejects a theorem id, an
agent id or a result carrying whitespace, which would shift its own
line's columns.

**Two lifecycles share the file, and the split is what keeps the
vocabulary from drifting the next time a kind is added.** `spawn` and
`stopped` are the reviewer's view of a child — it asked for one, and it
cut one off. `enter` and `return` are the child's own — it began, and
it finished. A reviewer therefore never writes an `enter` and a child
never writes a `spawn`.

The `anchor` line is the reviewer's, written into `--mode header`. Its
`<head-sha>` is the head commit the round's theorems were generated
against, and it is what a resume compares against `origin/<branch>`
before trusting a single record: a scheduled sweep force-rebases open
PR branches and can fire mid-round, and verdicts from two trees must
never be mixed. The line carries no deadline instant: what a child's
deadline is measured from is the reviewer's, owned by
`sdlc:theorem-based-pr-reviewer` → "Resume a started round; never
restart it".

**The outstanding set is derived, never stored.** A theorem is
**settled** once it carries any `return` record, and the outstanding
set is the `spawn` ids minus those, which one command answers over
`--mode print` output:

```bash
awk '$1=="spawn"{s[$2]=1}
     $1=="return"{delete s[$2]}
     END{for(t in s) print t}'
```

**Whether an outstanding theorem has a child in flight is a second
question, and it is keyed on the child rather than on the theorem.** A
theorem is in flight when its **last** `enter` carries an agent id that
no `return` of that theorem carries, and no `stopped` record follows
that `enter`:

```bash
awk '$1=="enter"{child[$2]=$4; gone[$2]=0}
     $1=="stopped"{gone[$2]=1}
     $1=="return"{done[$2" "$4]=1}
     END{for(t in child) if(!gone[t] && !((t" "child[t]) in done)) print t}'
```

That is the question a deadline arm asks — an outstanding theorem with
no child in flight has nothing to be overdue — and the one a re-spawn
asks before adding to its spawn count.

`stopped` kills the **child**, not the **theorem**, so it subtracts
from in-flight but not from outstanding. That child is gone, and a
derivation that left it in flight would report the theorem overdue on
every later resume and take the deadline arm against a child already
written off — reachable whenever a stopped child is never re-spawned,
which is what the resume-pass loop's no-progress exit, its hard stop,
and an exhausted spawn budget each leave behind. The theorem itself
stays outstanding and re-spawnable, and a derivation that subtracted it
from *that* set would report a theorem stopped at a deadline and
re-spawned in a resume pass as finished while its fresh child was still
working, because a resume appends no new `spawn` record. The `enter`
record, not this one, is what names the stopped child's worktree for
cleanup.

A stored `outstanding:` list would be a line that must be revised to
stay true; a derived set cannot go stale.

**First `return` wins.** A theorem can end up with two `return`
records: a child written off as lost reports late, or a resume
re-spawned one and both children finished. Both are legitimate
readings of the same tree, so the reader takes the **first** record for
a theorem and ignores the rest. The duplicate stays in the file and is
worth reporting as a diagnostic — it is evidence that a child believed
dead was alive, which is exactly what a stalled-round post-mortem
needs. The rule lives in the reader, so no line is ever revised and
concurrent appends cannot collide.

`enter` resolves the other way: the **last** `enter` for a theorem
names the child running it now, because a re-spawn's whole point is
that the earlier child is no longer the one being waited on. Measuring
a re-spawned child's deadline from its predecessor's `enter` would
declare it overdue the moment it started.
