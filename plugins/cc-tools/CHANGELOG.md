# cc-tools changelog

## 0.10.0 — 2026-10-20

`cr` now merges up to four optional settings layers, so a setting shared
by every repo of an owner, or belonging to one machine, has one home.

In order, under `${XDG_CONFIG_HOME:-~/.config}/cc-tools/cr-settings`
except the last:

- `host.json`: this machine, every repo.
- `<host>/<owner>.json`: every repo of one owner or org.
- `<host>/<owner>/<repo>.json`: one repo, this machine only.
- `<repo-root>/.cc-tools/cr-settings.json`: one repo, committed.

The merged file is passed as a single `--settings` and removed when the
session ends. Lists concatenate and drop repeated entries, objects merge
key by key, and a later scalar wins. A `--settings` you pass yourself
replaces the layers for that launch.

- The repo's identity comes from its `origin` URL through `gh repo view`,
  so a fork's `upstream` is never picked. An ssh host alias is resolved
  through `ssh -G`.
- With no `origin`, in a directory `cr` ran `git init` in, or when `gh`
  cannot resolve the `origin`, only the host and committed layers apply.
- `cr` now refuses to launch when `git`, `gh` or `jq` is missing, a
  layer is not valid JSON, a key has a different type across layers, or
  an identity segment holds other characters than letters, digits, `.`,
  `_` and `-`.
- When `claude` survives an interrupt or termination, `cr` cleans up and
  exits with `claude`'s status.

## 0.9.0 — 2026-10-20

Adds `cr`, a launcher that starts a session from the repo root, named
after the repo, and loads `<repo-root>/.cc-tools/cr-settings.json`
through `--settings` when that file exists. This gives a repo a route to
settings its own `.claude/settings.json` does not reach, such as
`autoMode`.

- Name words before the first `-`-prefixed argument prefix the session
  name, and everything from that argument on goes to `claude` unchanged.
- Outside a repo, `cr` runs a throwaway `git init` and removes the
  `.git` when the session ends. `--cr-strict` refuses instead.
- A `SessionStart` hook keeps a resolver current at `~/.local/bin/cr`,
  which runs the launcher from the enabled cc-tools install. Updates
  therefore need no redeploy. The hook tells you when `~/.local/bin` is
  not on `PATH` and never edits `PATH`, and it never blocks a session.
- The resolver needs `jq`. It fails with a message rather than falling
  back to plain `claude` when it cannot find an enabled cc-tools.
- A `cr()` function in your zsh profile shadows the launcher until you
  remove it.

## 0.8.4 — 2026-09-27

cc-tools now depends on the `github-prs` plugin. Memory curation aimed
at a PR resolves that PR's branch through its PR-view skill, so that
plugin must be installed and enabled wherever this one runs.

## 0.8.3 — 2026-09-13

The topics and watermark instructions no longer say a Bash read of those
files is always denied, since the permission gate's operator carve-out
now covers Bash too. A denied read is reported the same way as before.

## 0.8.2 — 2026-09-11

Memory curation now reads and transfers into `docs/rules/*.md` rather
than `docs/*.md`. Instructions that pointed at files outside the plugin
were removed.

## 0.8.1 — 2026-09-10

`/cc-suggest-topics` now says a read of `~/.claude.json` is denied only
where the operator has not listed it under the permission gate's `home`
carve-out, and still assumes the deny, since the gate ships no default
entries.

## 0.8.0 — 2026-09-06

Adds `/cc-suggest-topics`, which proposes topics to track from this
machine's global Claude configuration and appends only what you accept.

It reads your global settings, installed plugins and marketplaces and
`~/.claude/CLAUDE.md`, and shows each candidate with the file and key
behind it.

- Accepted candidates are appended as search-only topics.
- A candidate that restates a tracked topic becomes a proposal to rename
  that topic to the broader term, keeping its issue numbers.
- Each append and rename takes its own yes. Declining everything changes
  no topic.
- Repo-local settings are not read, because the topics list is
  machine-wide.
- If the topics config cannot be read, the skill reports the denial and
  stops without offering to seed it. A settings file it cannot read is
  reported, and it continues on the rest.

## 0.7.0 — 2026-09-04

The tracked topics move out of the shipped plugin into your own
`${XDG_CONFIG_HOME:-$HOME/.config}/cc-tools/config.yml`, which is now
the only source of topics for `/cc-watchlist` and `/cc-whats-new`. Your
list survives plugin updates, and you can add and remove from it.

- An absent config is seeded from a starter set on first use.
- If the config cannot be read, either skill reports the error and the
  path, offers to seed it in case it does not exist, and otherwise stops
  with no report.
- `/cc-watchlist` groups its report under your topic names in file
  order, dropping the lettered prefixes. Extra issue numbers report under
  a trailing group of their own.
- `/cc-whats-new` no longer builds a profile from your settings and
  plugins, or caps its searches. Its `[extra-topic]` argument and source
  citations are gone, and `--since` stays. It offers what it finds as
  candidates, and appends only what you accept.
- The `/cc-whats-new` watermark becomes `whats-new.yml`. There is no
  migration, so the next run counts as a first run.

## 0.6.0 — 2026-09-02

Memory curation can now transfer lore into a README, and the plugin has
a user-facing README of its own.

- A transfer lands in the narrowest fit: the README governing the tree
  it applies to, then a `docs/*.md`, then `CLAUDE.md`. If no README
  governs that tree, curation creates one.
- A memory entry can now be deleted because a governing README already
  says what it says, and a transfer stages the README it touched.
- Curation names no path specific to this marketplace, so it works in any
  repository. A version bump travels with a README transfer only where
  the host repository's own rules require it.

## 0.5.0 — 2026-08-27

Adds `/cc-whats-new`, which reports what changed in Claude Code since it
last ran, filtered to what this machine uses.

It builds a profile from your settings, installed plugins and
`~/.claude/CLAUDE.md`, drops changelog entries that touch none of it, and
searches `anthropics/claude-code` issues on what survives, up to ten
searches. Each report line cites the file and key behind it. A watermark
at `${XDG_CONFIG_HOME:-$HOME/.config}/cc-tools/whats-new.md` is written
only after a successful report, so a failed run keeps its window. A
first run covers 30 days or 30 entries and says so.

## 0.4.0 — 2026-08-25

Memory capture and curation now judge what they keep.

- Capture drops any entry that would mean nothing to a reader who was not
  in the run, and names each drop in its report.
- Curation applies a retention test to content already in a destination
  file, deleting what fails. It stages files it only cut from and reports
  them in a `Cut from <destination>` group.
- `agent-memory-inbox-cleanup` reports a `Commit:` line on every path: a
  SHA, or `none` and why nothing was staged.

## 0.3.1 — 2026-08-21

Fixes `agent-memory-inbox-capture` aborting every capture in a repo that
commits `.claude/agent-memory/`. It now captures only the calling agent's
own directory, and other agents' entries are neither an error nor
copied.

## 0.3.0 — 2026-08-19

Adds a session inbox for agent memory, so memory no longer has to travel
on the issue branch. The capture step `sdlc`'s agents each ran at the end
of a run, committing their entries, arrives here without the commit.

- `agent-memory-inbox-capture` copies the calling agent's entries into a
  per-branch inbox under the session scratchpad, and commits nothing.
- `agent-memory-inbox-cleanup` grades each entry transfer or delete,
  commits and pushes the transfers on the branch, and empties the inbox.
  An absent or empty inbox is not a failure.

Both are driven by an orchestration flow, not typed by you. The inbox
lasts only as long as the session. `/agent-memory-cleanup` keeps its
modes and reaches the same verdicts.

## 0.2.1 — 2026-08-01

Formatting only: tables and line wrapping in the `/cc-watchlist` skill.
Behavior is unchanged.

## 0.2.0 — 2026-07-25

Adds `/agent-memory-cleanup`, which curates a repo's
`.claude/agent-memory/` in one acting pass. Curation arrives here from
the `sdlc` plugin's `doc-updater` agent.

It grades each entry persist, scrub or transfer. Scrubbed entries are
deleted, each backed by a check it can produce. Durable lore moves into
`CLAUDE.md` or `docs/*.md` as present-tense constraints, and the
`MEMORY.md` indexes and any wikilinks its deletions broke are repaired.

- With a PR number, it commits and pushes onto that PR's branch.
- With no argument, it curates the working tree and leaves the result
  uncommitted for your review.

## 0.1.0 — 2026-06-22

Claude Code meta-skills.

- `/cc-all` loads your global rules from `~/.claude/CLAUDE.md` and the
  files it includes.
- `/cc-watchlist` reports the status of a tracked set of Claude Code
  feature requests and bugs: which are open and which have shipped.
