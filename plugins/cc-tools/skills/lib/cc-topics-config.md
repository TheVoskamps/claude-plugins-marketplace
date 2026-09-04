# Topics config contract (`skills/lib/cc-topics-config.md`)

This file is the single source of truth for **where** the user's
curated Claude Code topics live, **what** the file holds, and **how** a
skill reads it. It is reference prose, not an executable script.
`/cc-tools:cc-watchlist` and `/cc-tools:cc-whats-new` (the readers),
`/cc-tools:cc-suggest-topics` (which reads the file and appends what
the user accepts to it), and `/cc-tools:cc-seed-config` (the writer)
all follow this contract; none of them restates the path or the
schema.

## Why the topics are a config and not a skill body

Both skills act on the same curated set from opposite ends:
`cc-watchlist` reports the status of the issues under a topic,
`cc-whats-new` searches upstream for what is new on the topic's
subject. A set baked into either skill's body is one user's shopping
list shipped as the plugin's behaviour — unaddable, unremovable, and
lost on every plugin update. A set *derived and written* from the
machine's settings and installed plugins is no better: it is a list the
user never chose and cannot prune. Derivation as a *proposal* is a
different thing, and is what `cc-suggest-topics` does — every topic it
derives takes the user's yes before it reaches the file, so what the
file holds stays a list the user chose.

So the file below is the **only** source of topics for the two readers
named above. Neither infers a topic from anything else.

## The path

```text
${XDG_CONFIG_HOME:-$HOME/.config}/cc-tools/config.yml
```

Per [`docs/config-file-conventions.md`](../../../../docs/config-file-conventions.md):
the variable when it is set and non-empty, `$HOME/.config` when it is
unset or empty. Resolve it by reading the environment yourself and pass
the absolute path — the skills that read this file forbid compound Bash
commands, which rules out shell parameter expansion.

## The shape

Plain YAML, one document. No Markdown front-matter fences: `---` is a
YAML document separator, and wrapping the keys in a pair of them makes
the file a two-document stream.

```yaml
schema-version: 1
topics:
  - name: Compound bash parsing & permissions harness
    issues: [16561, 46363, 31523]
  - name: remote control
```

- **`schema-version`** — an integer, first key. The pin is **1**.
- **`topics`** — a list, in the order the user wants them reported and
  searched.
- **`name`** — required. The heading `cc-watchlist` groups under, and
  the query string `cc-whats-new` searches. Quote it when it contains
  a colon followed by a space, as `` `isolation: worktree` subagent
  isolation `` does — unquoted, YAML reads the colon as a key
  separator and the topic becomes a nested mapping.
- **`issues`** — optional, a list of `anthropics/claude-code` issue
  numbers. A topic without one is search-only, which is how a user
  tracks a subject that has no issue numbers yet; it contributes no
  rows to a `cc-watchlist` report.

## Reading it

Read it with the `Read` tool, never `cat` or `grep` from Bash. The
permission gate's `$HOME/.config` carve-out reaches the file-tool track
only, so a Bash read is denied on every machine whether or not the
operator listed a glob (`docs/config-file-conventions.md` → "The
permission gate reads `$HOME/.config` literally").

Every reader handles each of these outcomes:

- **Absent** — invoke `/cc-tools:cc-seed-config` to write it, say in
  your own report that the config was seeded and at which path, and
  proceed on the topics it wrote.
- **Unreadable** — the `Read` denies. Report the tool's error verbatim
  and the path it was denied at, and name no cause: a denial says
  nothing about why, so any explanation you offer is a guess the user
  will act on. Then offer to invoke `/cc-tools:cc-seed-config`, in case
  the file does not exist, and say what the offer risks — a denied read
  is not evidence that the file is missing, so an accepted offer may
  overwrite a config nobody could see. Declined, stop and report on no
  topics; there is no fallback set to report on. Accepted and written,
  proceed as for **Absent**. Accepted and the write denies too, report
  that error verbatim and stop. `cc-suggest-topics` is the one
  exception to the offer: it derives its candidates against what is
  already tracked, so with the file unseen it would propose its whole
  list as new — it reports the denial and stops without offering to
  seed.
- **`schema-version` absent, or the YAML is malformed** — abort,
  naming the path. A hand-editable file that a reader treats as absent
  is a hand edit about to be overwritten.
- **`schema-version` lower than the pin** — abort, naming both
  versions.
- **`schema-version` higher than the pin** — proceed, reading only the
  keys this contract documents.

## Writing it

Only `/cc-tools:cc-seed-config` creates the file, and only when a
reader found it absent or the user accepted the offer the
**Unreadable** case makes. The other two writes are edits to an
existing file, and each preserves every key and every topic already
there: `cc-whats-new` appending a topic the user accepted from its
discovery section, and `cc-suggest-topics` appending a candidate the
user accepted — or renaming one tracked topic to a broader term the
user accepted, carrying its `issues:` over untouched.
