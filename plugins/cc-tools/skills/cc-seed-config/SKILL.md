---
name: cc-seed-config
description: "Seed the cc-tools per-user config at $XDG_CONFIG_HOME/cc-tools/config.yml from the shipped starter topics when the file is absent, or hand those starter topics back without writing. The single owner of the starter table and of the create-the-file write; invoked by cc-watchlist and cc-whats-new, never by a human."
allowed-tools: Read, Write
argument-hint: [--table-only]
user-invocable: false
---

You are running the `/cc-tools:cc-seed-config` skill. You own the
starter topic list for the `cc-tools` plugin and the write that turns
it into a config file. `/cc-tools:cc-watchlist` and
`/cc-tools:cc-whats-new` both need that list on a machine that has no
config yet, and one behaviour written twice is two behaviours that
drift, so neither of them carries a copy of the table and neither of
them creates the file.

## Invocation

```text
/cc-tools:cc-seed-config [--table-only]
```

- **No argument** — seed: create the config from the starter topics if
  it is absent, then return the topics.
- **`--table-only`** — return the starter topics and write nothing.
  This is the fallback path a caller takes when the config exists but
  could not be read, where a write would clobber a file you cannot see.

## The config file

`${XDG_CONFIG_HOME:-$HOME/.config}/cc-tools/config.yml`.
Resolve `XDG_CONFIG_HOME` by reading the environment yourself and pass
the absolute path to `Read`/`Write` — the guardrails carve-out reaches
the file-tool track only, so `cat` and `grep` from Bash are denied on
every machine.

Plain YAML, not Markdown with front-matter: a `---` fence is a YAML
document separator, and a config file that parses as a two-document
stream is not the single mapping either reader expects.

```yaml
# Config for the cc-tools plugin.
schema-version: 1
topics:
  - name: Session display / CLI flags
    issues: [40393]
  - name: Compound bash parsing & permissions harness
    issues: [16561, 46363, 31523, 28240, 52822, 4368, 4719, 27661, 54898]
  - name: "`isolation: worktree` subagent isolation"
    issues: [62547, 52958, 47548]
```

A topic is one subject seen from two ends: its `name` is what
`cc-whats-new` searches, its `issues` are what `cc-watchlist` reports
on. `issues` is optional — a topic without one is search-only, which is
how a user tracks a subject with no issue numbers yet. Order in the
file is report order.

Two shapes in the block above are load-bearing rather than stylistic,
and a hand-edit reproduces them:

- The third name is **quoted** because a plain scalar may not begin
  with a backtick — YAML reserves it — so the unquoted form is a parse
  error rather than a style choice.
- The comment is the only one. The skills own the schema, so the file
  carries no restatement of it, no history, and no rationale.

## Execution

1. **Read the config**, unless `--table-only` was given.

   - **Present and readable** — nothing to seed. Return the topics it
     holds, and tell the caller you wrote nothing.
   - **Absent** — go to step 2.
   - **Unreadable** (a denied read on a machine whose
     `~/.config/guardrails/config.yml` does not list `cc-tools/**`, or
     any other failure that is not absence) — write nothing and return
     the starter topics, saying the read failed and quoting the error.
     A file you cannot read is not a file you may overwrite.

2. **Write the starter config** at the path above, byte for byte as the
   block in "The config file" shows it. `Write` creates missing parent
   directories, so there is no `mkdir` step.

3. **Return the topics** — the starter list, or on the present-and-
   readable path the file's own — and say plainly whether this run
   wrote the file and at which path. The caller repeats that in its own
   report, so a user learns where their topics now live the first time
   either skill runs.

## Notes

- `--table-only` never reads and never writes. It is a request for the
  shipped list alone.
- The starter list is a starting point, not a recommendation the user
  is stuck with: they curate `config.yml` by hand afterwards, and this
  skill never runs again on that machine.
- Hand-editing is the **only** way to curate it. No skill creates or
  merge-updates `config.yml` interactively; the one other writer is
  `/cc-tools:cc-whats-new`, appending a topic the user accepted when it
  asked. The absence of an interactive config skill here is a decision,
  not an oversight.
- The config is machine-wide. There is no repo-local layer over it, so
  the same topics apply in every repo on this machine.
