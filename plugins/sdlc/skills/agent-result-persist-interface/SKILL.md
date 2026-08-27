---
name: agent-result-persist-interface
description: The contract for the sdlc-agent-result-persist CLI — its modes, its flags, the path it composes, and the line grammar of the file it writes. Preloaded into sdlc:theorem-based-pr-reviewer, sdlc:theorem-disprover, and sdlc:counterexample-verifier via their skills frontmatter; not invoked from the user's slash menu.
user-invocable: false
---

# Agent Result Persist Interface

This is the one statement of what `sdlc-agent-result-persist` does.
`sdlc:theorem-based-pr-reviewer` creates a round's file and reads it
back; `sdlc:theorem-disprover` and `sdlc:counterexample-verifier`
append their own result to it as their final act.

The reason the file exists is that a child's result reaches the
reviewer only as a `<task-notification>`, and a notification that is
never delivered takes the result with it — the reviewer then waits out
its deadline on an agent that finished. A record the child wrote itself
survives that. **A notification is a wake-up; a record in this file is
the evidence.**

The file lives under the session scratchpad, outside every worktree, so
a child's `isolation: worktree` worktree being thrown away does not
take the record with it.

What each *brief* parameter means — including the `--scratchpad`,
`--owner`, `--repo`, `--pr` and `--round` the reviewer passes a child
so it can make the call below — is owned by
`sdlc:theorem-agents-interface`. This file owns the CLI: the modes, the
flags, the path, and the grammar.

## Invocation

The script is invoked as a bare command name, never by path:

```text
sdlc-agent-result-persist --mode <mode> \
  --scratchpad <dir> --owner <owner> --repo <repo> \
  --pr <n> --round <n> --agent <name> [mode-specific flags]
```

Spell the command exactly as written. The rule that lets it run
unattended is keyed on that bare spelling —
`Bash(sdlc-agent-result-persist:*)` — and it lives in the caller's own
settings rather than in this plugin, which ships no permission rules at
all. A spelling that does not match it byte for byte, or a machine
where the rule was never added, turns a child's final act into a prompt
nobody is there to answer.

## The identifying flags

These six are passed in **every** mode, and they are the whole of what
the path is composed from:

- `--scratchpad <dir>` — the harness's per-session scratchpad
  directory, named in the reviewer's own context and passed down
  verbatim. Every agent in a session shares the parent session's
  scratchpad, which is what lets a child write a file the reviewer
  reads. The script derives nothing about the host: the uid in
  `/tmp/claude-<uid>/` varies per machine, and the session segment is
  not a child's to compute. Never hand-build a lookalike path.
- `--owner <owner>` — the repository owner, e.g. `TheVoskamps`.
- `--repo <repo>` — the repository name, e.g.
  `claude-plugins-marketplace`. Owner and repo stay **separate**: a
  combined `owner/name` would need quoting at the call site, splitting
  in the script, and its `/` would add a directory level to the
  composed path. The script rejects a value carrying a path separator
  for that reason.
- `--pr <n>` — the pull request under review.
- `--round <n>` — the review round.
- `--agent <name>` — the fan-out this file belongs to, either
  `theorem-disprover` or `counterexample-verifier`. It names the
  **fan-out**, not the individual child: one file carries every child
  of one fan-out, so a round has two files.

## The path

The script composes it and **no caller ever holds it**:

```text
<scratchpad>/sdlc/theorem-based-pr-reviewer-<owner>-<repo>-pr<pr>-round<round>-<agent>
```

That is the whole point of passing the same identifying flags in every
mode. There is no path string for an agent to mistype, and none for the
reviewer to carry across the turn boundary a fan-out wait is made of —
which is the boundary that destroys whatever an agent merely remembers.

## The modes

### `--mode header`

Creates the file and writes `--header <text>` to it, verbatim. This is
the reviewer's one call per fan-out, made at spawn time.

It **refuses to run twice** for one file: it is the only truncating
write in the script, and every record already in the file is a result
no notification can be asked to redeliver. A second call against an
existing file exits non-zero and writes nothing.

The reviewer constructs the text — the `anchor` line and one `spawn`
line per child — and passes it as one string, without a trailing
newline. The window the anchor's deadline expresses is review policy
and belongs to the reviewer, not to this script.

### `--mode detail`

Appends one `return` record for `--theorem <id>` with `--result
<token>`, timestamped by the script. This is a child's final act.

The **script** stamps the time: the writer owns the fact, and a time
supplied by a caller would be the caller's recollection of when it
finished rather than when the record was made.

`--result` takes any non-empty single token — the vocabulary differs
per agent (`SURVIVED` / `DISPROVED` from a disprover, `STANDS` /
`REFUTED` from a verifier), so the script checks that it is one token
and grades it no further. Each agent's own definition is where its
tokens are stated; the script knows none of them.

If the file does not exist, this mode creates it rather than failing. A
header that never ran is the reviewer's defect to see in the records; a
child's discarded result is the loss this whole mechanism exists to
prevent.

### `--mode stopped`

Appends one `stopped` record for `--theorem <id>`, timestamped by the
script. It is the reviewer's, at the deadline arm, for a child it
`TaskStop`s.

A stop is a **different record kind** from a return, not a return
carrying a `STOPPED` result: a `return` line is a verdict, and the
reviewer is not a source of verdicts. Spelling a stop as a return would
manufacture exactly the verdict the reviewer is barred from inventing.

### `--mode print`

Writes the file's current contents to stdout. This is how the reviewer
reads the file on every resume; it is also how a human inspects a round
that went wrong. It exits non-zero when the file does not exist, which
means the fan-out's `--mode header` call never ran.

## The line grammar

One record per line, whitespace-separated columns, and **no line is
ever revised in place**. Four record kinds:

```text
anchor  <anchor-instant> <deadline-instant>
spawn   <theorem-id> <iso-time>
return  <theorem-id> <iso-time> <result>
stopped <theorem-id> <iso-time>
```

Every instant is `date -u +%Y-%m-%dT%H:%M:%SZ`. There is no `<stage>`
column: `--agent` keys the file, and one file carries one fan-out.

The file is **append-only**. `--mode header` writes it once, and every
later record goes on the end. Rewriting it whole would mean
reconstructing it from what an agent remembers, and what it remembers
is exactly what the turn boundary destroyed.

Because a theorem id and a result are columns, the script rejects
either carrying whitespace — a value that shifted the columns of its
own line would desynchronise the reader's derivation from the writer's
intent.

**The outstanding set is derived, never stored.** It is the `spawn` ids
minus the `return` and `stopped` ids, which one command answers over
`--mode print` output:

```bash
awk '$1=="spawn"{s[$2]=1}
     ($1=="return"||$1=="stopped"){delete s[$2]}
     END{for(t in s) print t}'
```

Never write an `outstanding:` list into the file. Maintaining one means
revising a line already written, which is what put a stale outstanding
set beside a return log that contradicted it; a derived set cannot go
stale.
