---
name: cc-whats-new
description: Report what changed in Claude Code since this skill last ran, filtered to the topics in your cc-tools config. Reads the upstream CHANGELOG and searches anthropics/claude-code issues on the same topics. Use when asked what's new in Claude Code, or when starting a session after an update.
allowed-tools: Bash(gh search issues:*), Bash(gh issue view:*), Bash(claude --version), Bash(date:*), Read, Write, Skill, WebFetch
argument-hint: [--since YYYY-MM-DD]
---

# What's new in Claude Code, for the topics you track

Report only what the user asked to hear about. A changelog line about a
feature none of their configured topics names is noise, and noise is
what this skill exists to remove.

The topics are theirs, not this file's: they live in `topics:` in
`${XDG_CONFIG_HOME:-$HOME/.config}/cc-tools/config.yml`, which they
edit by hand. This skill does not infer them from the machine's
settings, plugins or `CLAUDE.md` — a topic the user never chose is a
topic they cannot remove. Suggesting topics from the machine's
configuration is a separate on-demand skill the user invokes, not an
implicit filter here.

That has a cost, and it is the intended trade rather than a gap to
close: a harness surface this machine exercises but the user never
listed goes unreported. The tool reports, the user curates.

## Files

Both live in `${XDG_CONFIG_HOME:-$HOME/.config}/cc-tools/`. Read and
write them with `Read` and `Write`, never `cat` or a shell redirect:
the guardrails carve-out that makes `~/.config` reachable at all covers
the file-tool track only.

**`config.yml`** — the topics, described in
`/cc-tools:cc-seed-config`, which owns its schema and its starter
contents.

**`whats-new.yml`** — the watermark. Plain YAML, not Markdown with
front-matter, whose `---` fence would split the file into a
two-document stream:

```yaml
schema-version: 1
last-run: "2026-08-31"
last-version: "2.1.247"
```

Both values are **quoted**, for different reasons. Unquoted,
`2026-08-31` resolves to a timestamp rather than the `YYYY-MM-DD`
string this skill compares against `--since` and against `gh search`
output. A three-component `2.1.247` is already a string unquoted, but a
two-component version such as `2.1` resolves to a float, so
`last-version` is quoted to keep every version the same type.

`last-version` is what filters the CHANGELOG, which carries version
headings and no dates; `last-run` is what filters the issue search,
which is dated and versionless. Both are needed — neither substitutes
for the other.

This skill reads `whats-new.yml` and nothing else; a `whats-new.md`
left over from an earlier version is not migrated and not read.

## Execution rules

Every Bash command MUST be single-token: no `&&`, no `||`, no `;`, no
`|`, no `>` / `2>`. Compound forms hit known parser gaps in the
permissions harness and prompt even with a matching allow rule. That
rules out shell parameter expansion for the file paths too — resolve
`XDG_CONFIG_HOME`'s value by reading the environment yourself and pass
the absolute path.

## Steps

1. **Read the watermark**, requiring `schema-version: 1`. A file whose
   YAML is absent or malformed, or whose `schema-version` is lower, is
   not a watermark to guess at: report the path and the version found
   and stop, so a hand-edit that broke the file is not silently
   overwritten. A **higher** version reads fine — take the two keys and
   ignore the rest.

   If the file or its directory is absent, this is a first run: report
   that, use the 30 days before today as the window, and say in the
   report that the CHANGELOG section is capped at 30 entries rather
   than complete.

   `--since YYYY-MM-DD` in `$ARGUMENTS` overrides `last-run` for this
   run and leaves the file's own watermark to be advanced as usual.

2. **Read the topics** from `config.yml`. This skill pins
   `schema-version: 1`, and handles the file the same way
   `/cc-tools:cc-watchlist` does:

   - **Absent** — invoke `/cc-tools:cc-seed-config`, which creates it
     from the shipped starter topics. Use the topics it returns, and
     say in the report that the config was seeded and at which path.
     Do not require a `cc-watchlist` run first; this skill seeds on its
     own.
   - **Unreadable** (a denied read on a machine whose
     `~/.config/guardrails/config.yml` does not list `cc-tools/**`, or
     any other failure that is not absence) — invoke
     `/cc-tools:cc-seed-config --table-only`, report that the config
     could not be read and quote the error, and run on the starter
     topics without writing anything to it.
   - **Malformed, or `schema-version` absent** — report the path and
     stop.
   - **`schema-version` below 1** — stop, naming both the version found
     and the version pinned.
   - **`schema-version` above 1** — proceed on the keys documented in
     `/cc-tools:cc-seed-config` and ignore the rest.

3. **Fetch the CHANGELOG** with WebFetch from
   `https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`,
   asking for every entry above `last-version`. Version headings are
   descending, so stop at the first heading that is `last-version` or
   lower. On a first run, take the newest 30 entries.

4. **Match each entry against the topics.** Keep an entry when it names
   a surface a configured topic names, or when it changes a default
   such a topic relies on without naming it. Drop the rest silently —
   do not report a count of what was dropped, and do not keep an entry
   because it looks generally interesting.

5. **Search every configured topic**, one Bash call each, both states,
   bounded by the watermark:

   ```bash
   gh search issues --repo anthropics/claude-code --limit 20 --json number,title,state,closedAt,updatedAt "<topic name> updated:>=<last-run>"
   ```

   Every topic is searched, whether or not step 4 matched a CHANGELOG
   entry to it and whether or not it carries `issues:`. There is no
   cap: the user curated the list, so a config with fifteen topics
   produces fifteen searches and there is nothing to report as
   unsearched.

6. **Propose what the search turned up**, per "Discovery is
   propose-and-ask" below. Append to `topics:` only what the user
   accepts, preserving every existing topic and key.

7. **Write the watermark back** to `whats-new.yml`: today's date, and
   the version from `claude --version`. `Write` creates missing parent
   directories, so there is no `mkdir` step. Do this last, only after
   the report is produced, so a failed run leaves the window intact for
   the next one.

## Discovery is propose-and-ask, never auto-append

This skill finds issues that are *new since the watermark*;
`/cc-tools:cc-watchlist` reports on issues the user *chose* to track.
An auto-append collapses the two — everything discovered becomes
tracked, the list grows monotonically, and the curation the config
exists for is undone by the tool.

So: surface the candidates in the report, ask which to track and under
which topic (an existing name or a new one), and append only what comes
back. Nothing is written to `topics:` without an answer, and declining
writes nothing at all.

`config.yml` has more than one writer, so an append **merges**: read
the file, add the accepted issue numbers to the named topic (or add the
new topic at the end), and leave every other topic, key and comment as
it was.

## Report format

```text
Since <last-version> (<last-run>) — now <version>, <today>.

## Affects your setup

- <CHANGELOG entry, verbatim> — <what it changes for you, one line>

## Issues on those topics

<topic name>:
- #<num> open — <title>
- #<num> closed <YYYY-MM-DD> — <title>

## Watch

- <entry that names a topic you track but does not change it yet>

## Track these?

<topic name or "new topic">:
- #<num> — <title>
```

Omit any section whose list is empty. Two bounds on the gloss that
follows a CHANGELOG entry in "Affects your setup": say what the entry
changes for the topics the user tracks, not what the feature is, and
never assert an interaction the CHANGELOG does not state — label a
hypothesis as one.

## Notes

- If WebFetch fails, report the error verbatim and stop before writing
  the watermark.
- A topic names a subject, not a file: search its `name` as written,
  and let the user reword it in `config.yml` if the search is too broad
  or too narrow.
