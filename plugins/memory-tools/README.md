# memory-tools

Keeps a copy of every memory Claude Code writes, outside any repository,
and grades those copies on request without changing anything.

## Why you would want it

Memory is written where it is easy to lose and hard to review:

- **An agent's memory can die with its worktree.** An agent that runs
  under `isolation: worktree` writes its `.claude/agent-memory/` inside
  a throwaway worktree. Unless something carries the entry out before
  the worktree is removed, it is gone.
- **Nothing collects auto memory.** The main session's own memory sits
  under the config directory, per project, where no review ever sees
  it.
- **Curating memory in place is destructive.** A pass that deletes
  entries and moves others into `CLAUDE.md` acts on its own judgment,
  and its edits reach a branch without a review round.

The plugin separates the two halves. A hook records each memory write
the moment it happens, so no agent has to remember a copy step and no
entry depends on a session ending cleanly. A skill reads the records
and reports what each memory is worth; acting on the report is yours.

## What you need first

- `jq` and `git` on `PATH`. Without `jq` the hook records nothing and
  says nothing.
- Memory turned on in your Claude Code settings. With it off, nothing
  writes a memory file, so the hook has nothing to record.
- A repository with an `origin` remote. Records are filed by the
  repository they belong to, and a write with no `origin` to file it
  under is not recorded.
- The `cc-tools` plugin, which is installed and enabled with this one.

## What gets captured

The hook, `memory-capture.sh`, runs after every `Write` and `Edit` call
and records the call when the file it wrote lies in a memory directory.
`<config>` is `CLAUDE_CONFIG_DIR` when that is set and not empty, and
`~/.claude` otherwise:

| Kind | Directory | Whose memory |
| --- | --- | --- |
| `agent-user` | `<config>/agent-memory/<agent>/` | An agent declaring `memory: user` |
| `auto` | `<config>/projects/<project>/memory/`, or your `autoMemoryDirectory` | The main session's auto memory |
| `agent-local` | `<dir>/.claude/agent-memory-local/<agent>/` | An agent declaring `memory: local` |
| `agent-project` | `<dir>/.claude/agent-memory/<agent>/` | An agent declaring `memory: project` |

A path is matched against the kinds in that order and takes the first
that fits, so a file under `~/.claude/agent-memory/` is `agent-user`
although it also has the `agent-project` shape.

`autoMemoryDirectory` is read from `.claude/settings.local.json` and
`.claude/settings.json` in the session's working directory, then from
`<config>/settings.json`. The first file that sets it wins, and a
leading `~` is expanded. A value set only through `--settings` or a
policy file is not seen, so auto memory redirected that way is not
captured.

A call is not recorded when:

- the tool call failed;
- the file lies outside every memory directory;
- no `origin` remote can be read, or its URL does not reduce to a host,
  an owner and a repository made of letters, digits, `.`, `_` and `-`.

The hook only observes. It prints nothing, never blocks or alters a
tool call, and exits 0 whatever it is given, so a failure to record
costs that one record and nothing else.

## Where records land

Each recorded call is one YAML file:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/memory-tools/<host>/<owner>/<repo>/<captured-at>-<tool-use-id>.yml
```

`<host>/<owner>/<repo>` comes from the `origin` URL: of the directory
holding the memory file for the `agent-project` and `agent-local`
kinds, and of the session's working directory for the other two.
Records are therefore filed by repository and not by checkout, and a
memory written in a worktree outlives it. `<captured-at>` is the UTC
capture time as `YYYYMMDDTHHMMSSZ`, so a directory listing is in
capture order.

A record holds these keys, in this order:

```yaml
kind: agent-project
source-path: /abs/path/to/the/memory/file
tool: Write
session-id: 0b1c2d3e
branch: issue-12-some-branch
captured-at: 2026-11-26T05:14:25Z
content: "the file's whole text after the call"
```

- `branch` is the branch checked out in the memory file's directory,
  and is empty when there is none.
- `content` is the whole file after the call, not the change: what a
  `Write` was given, and the file read back from disk after an `Edit`.
  It is always a double-quoted scalar with JSON string escapes, so a
  YAML parser reads back exactly what was captured, whatever its
  whitespace, line endings or control characters.

Every write is a record of its own, so a memory edited five times has
five records and its history can be read off them. Nothing prunes the
directory. Records hold your memories verbatim; delete the files
yourself when you no longer want them.

## Grading what was captured

```text
/memory-tools:memory-grade [<checkout-path>]
```

`<checkout-path>` is a local checkout of the repository whose memories
you want graded, and the current directory when omitted. The skill
finds the repository's records through the checkout's `origin`, reads
them all, and judges each memory against the code and rules in that
checkout.

A memory is one `source-path`. Only its latest record is graded, and
the report says how many records it has. The record's `content` is what
is graded, not the file at `source-path`, which may have changed since
or gone with its worktree.

Each memory gets exactly one grade:

- **Delete** — it restates what the code or a rule already says, names
  a document or another repository as the source of truth, narrates
  finished work, or duplicates another memory. The report names which,
  with the check that shows it: the file and lines, the quoted text, or
  the memory it duplicates. A delete the skill cannot substantiate is
  not graded delete.
- **Durable** — a deliberate choice in the repository's own code that
  the code cannot state about itself.
- **No code home** — a preference, a workflow correction or a tooling
  gotcha about something outside the repository's code.

A durable or no-code-home memory comes with the file it would land in —
the nearest `CLAUDE.md` governing the code it is about, else an
on-demand `docs/rules/*.md`, else the root `CLAUDE.md`, and never a
README — and the constraint worded as it would be written there.

With no records for the repository, the skill says so and names the
directory it looked in.

## What it deliberately does not do

- **The grade is never applied.** The skill writes, deletes, moves and
  commits nothing, in the checkout or among the records. Moving a
  durable memory into `CLAUDE.md` and deleting a stale one are edits
  you make, or hand to a reviewed change.
- **It does not capture what was written before it was enabled.** A
  record exists only for a write the hook saw.
- **It does not capture a memory file changed by other means.** Only
  `Write` and `Edit` calls are recorded; a file written by a shell
  command is not.
- **It does not turn memory on.** Whether agents and the main session
  write memory at all is your Claude Code configuration.
