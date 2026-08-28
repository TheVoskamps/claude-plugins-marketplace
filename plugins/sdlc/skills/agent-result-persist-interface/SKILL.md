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
append their own result to it as their final act.

## Invocation

```text
sdlc-agent-result-persist --mode <mode> \
  --scratchpad <dir> --owner <owner> --repo <repo> \
  --pr <n> --round <n> --agent <name> [mode-specific flags]
```

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
  verbatim. The reviewer's one call per fan-out, at spawn time. It
  **refuses a file that already exists**, exiting non-zero and writing
  nothing: every record already there is a result no notification can
  be asked to redeliver.
- **`detail`** — appends one `return` record for `--theorem <id>`
  carrying `--result <token>`. A child's final act. `--result` takes
  any single token; the vocabulary is each agent's own and the script
  grades it no further. Creates the file when it is absent rather than
  discarding the result.
- **`stopped`** — appends one `stopped` record for `--theorem <id>`.
  The reviewer's, at the deadline arm, for a child it `TaskStop`s. A
  stop is its own record kind, never a `return` carrying a `STOPPED`
  result — a `return` is a verdict, and the reviewer is not a source of
  verdicts.
- **`print`** — writes the file to stdout. Exits non-zero when the file
  does not exist, which means the fan-out's `header` call never ran.

The script stamps each `return` and `stopped` time itself: the writer
owns when the record was made.

A refusal and a malformed call both exit non-zero, so the status says
only that the call did nothing. The message says which.

## The line grammar

One record per line, whitespace-separated columns, appended, and **no
line is ever revised in place**:

```text
anchor  <anchor-instant> <deadline-instant>
spawn   <theorem-id> <iso-time>
return  <theorem-id> <iso-time> <result>
stopped <theorem-id> <iso-time>
```

Every instant is `date -u +%Y-%m-%dT%H:%M:%SZ`. There is no stage
column: `--agent` keys the file. The script rejects a theorem id or a
result carrying whitespace, which would shift its own line's columns.

**The outstanding set is derived, never stored.** It is the `spawn` ids
minus the `return` and `stopped` ids, which one command answers over
`--mode print` output:

```bash
awk '$1=="spawn"{s[$2]=1}
     ($1=="return"||$1=="stopped"){delete s[$2]}
     END{for(t in s) print t}'
```

A stored `outstanding:` list would be a line that must be revised to
stay true; a derived set cannot go stale.
