---
name: cc-whats-new
description: Report what changed in Claude Code since this skill last ran, filtered to the topics in your cc-tools config. Reads the upstream CHANGELOG and searches anthropics/claude-code issues on the same topics. Use when asked what's new in Claude Code, or when starting a session after an update.
allowed-tools: Bash(gh search issues:*), Bash(gh issue view:*), Bash(claude --version), Bash(cat:*), Bash(ls:*), Bash(mkdir:*), Bash(date:*), Read, Write, Skill, WebFetch
argument-hint: [--since YYYY-MM-DD]
---

# What's new in Claude Code, on the topics you track

Report only what the user's configured topics reach. A changelog line
about a surface no configured topic names is noise, and noise is what
this skill exists to remove.

## Topics

The topics are the user's, and they are the only topics this skill
acts on — it infers none from this machine's settings, installed
plugins, or always-loaded rules. Read
`skills/lib/cc-topics-config.md` for the config path, the `topics:`
schema, and what to do when the file is absent, unreadable, or carries
a `schema-version` this skill cannot serve. That contract is the only
statement of them.

This skill's pin is `schema-version: 1`.

## State file

`${XDG_CONFIG_HOME:-$HOME/.config}/cc-tools/whats-new.yml` holds the
watermark — plain YAML, one document, beside the topics config in the
same directory:

```yaml
schema-version: 1
last-run: "2026-08-31"
last-version: "2.1.247"
```

Both values are quoted. Unquoted, YAML 1.1 resolves `2026-08-31` to a
timestamp rather than the `YYYY-MM-DD` string this skill compares
against `--since` and against `gh search` output, and `2.1.247` is not
a number at all.

`last-version` is what filters the CHANGELOG, which carries version
headings and no dates; `last-run` is what filters the issue search,
which is dated and versionless. Both are needed — neither substitutes
for the other.

Read it with the `Read` tool, for the reason the topics contract gives,
requiring `schema-version: 1`. A malformed file is not a watermark to
guess at: report the path and stop, so a hand-edit that broke the file
is not silently overwritten. A `schema-version` lower than the pin
stops the same way, naming both versions — the one the file carries and
the `1` this skill requires. A **higher** version reads fine — take the
two keys and ignore the rest.

If the file is absent, this is a first run: report that, use the 30
days before today as the window, and say in the report that the
CHANGELOG section is capped at 30 entries rather than complete. There
is no migration from any earlier watermark file — an absent
`whats-new.yml` is a first run whatever else the directory holds.

If the `Read` **denies**, report the tool's error verbatim and the path
it was denied at, and stop. Name no cause: a denial says nothing about
why, so any explanation you offer is a guess the user will act on. A
denial is not absence either, so there is no first-run window to fall
back on — the run ends there, with no report and nothing written.

`--since YYYY-MM-DD` in `$ARGUMENTS` overrides `last-run` for this run
and leaves the file's own watermark to be advanced as usual.

## Execution rules

Every Bash command MUST be single-token: no `&&`, no `||`, no `;`, no
`|`, no `>` / `2>`. Compound forms hit an upstream permission-parser
bug and prompt even with a matching allow rule. That rules out shell
parameter expansion for the state path too — resolve
`XDG_CONFIG_HOME`'s value by reading the environment yourself and pass
the absolute path.

## Steps

1. **Read the watermark**, per the state file section above.

2. **Read the topics config**, per the topics section above.

3. **Fetch the CHANGELOG** with WebFetch from
   `https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`,
   asking for every entry above `last-version`. Version headings are
   descending, so stop at the first heading that is `last-version` or
   lower. On a first run, take the newest 30 entries.

4. **Match each entry against the configured topics.** Keep an entry
   when it names a surface a topic names, or when it changes a default
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
   cap: the user curated the list, so there is nothing to leave
   unsearched and nothing to report as unsearched.

6. **Propose what to track**, per the discovery section below.

7. **Write the watermark back** to the state file: today's date, and
   the version from `claude --version`. Do this last, only after the
   report is produced, so a failed run leaves the window intact for the
   next one.

## Discovery is propose-and-ask

This skill searches for issues *new since the watermark*;
`cc-watchlist` reports on issues the user *chose* to track. Appending a
discovery to `topics:` on its own collapses the two — everything
discovered becomes tracked, the list grows monotonically, and the
curation the config exists for is undone by the tool.

So: surface the candidates in the report's own section, ask which to
track and under which topic — an existing `name` or a new one the user
gives — and append only what the user accepts. Nothing reaches
`topics:` without an answer, and a declined candidate leaves the file
untouched.

An accepted candidate is an edit to a file the user owns: preserve
every existing key and every existing topic, add the issue number to
the named topic's `issues:` (creating the topic at the end of the list
when it is new), and change nothing else.

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

- <entry that names a configured topic's surface without changing it yet>

## Track these?

<topic name or "(new topic)">:
- #<num> — <title>
```

Omit any section whose list is empty. Bounds on the gloss after each
entry's dash in "Affects your setup": say what the entry changes for
these topics, not what the feature is, and never assert an interaction
the CHANGELOG does not state — label a hypothesis as one.

## Notes

- If WebFetch fails, report the error verbatim and stop before writing
  the watermark.
- Say in the report when the topics config was seeded this run, and
  where.
