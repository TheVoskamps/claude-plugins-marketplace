---
name: cc-whats-new
description: Report what changed in Claude Code since this skill last ran, filtered to what this machine's settings and installed plugins actually use. Reads the upstream CHANGELOG and searches anthropics/claude-code issues on the same topics. Use when asked what's new in Claude Code, or when starting a session after an update.
allowed-tools: Bash(gh search issues:*), Bash(gh issue view:*), Bash(claude --version), Bash(cat:*), Bash(ls:*), Bash(mkdir:*), Bash(date:*), Read, Write, WebFetch
argument-hint: [--since YYYY-MM-DD] [extra-topic]
---

# What's new in Claude Code, for this machine

Report only what this user's configuration makes reachable. A
changelog line about a feature no installed plugin, setting, or flag
here touches is noise, and noise is what this skill exists to remove.

## State file

`${XDG_CONFIG_HOME:-$HOME/.config}/cc-tools/whats-new.json` holds the
watermark:

```json
{ "lastRun": "YYYY-MM-DD", "lastVersion": "2.1.119" }
```

`lastVersion` is what filters the CHANGELOG, which carries version
headings and no dates; `lastRun` is what filters the issue search,
which is dated and versionless. Both are needed — neither substitutes
for the other.

Read it first. If the file or its directory is absent, this is a first
run: report that, use the 30 days before today as the window, and say
in the report that the CHANGELOG section is capped at 30 entries rather
than complete.

`--since YYYY-MM-DD` in `$ARGUMENTS` overrides `lastRun` for this run
and leaves the file's own watermark to be advanced as usual.

## Execution rules

Every Bash command MUST be single-token: no `&&`, no `||`, no `;`, no
`|`, no `>` / `2>`. Compound forms hit the parser issues cc-watchlist
tracks and prompt even with a matching allow rule. That rules out shell
parameter expansion for the state path too — resolve
`XDG_CONFIG_HOME`'s value by reading the environment yourself and pass
the absolute path.

## Steps

1. **Read the watermark**, per the state file section above.

2. **Build the profile** — the list of topics this run cares about.
   Read, and skip any that is absent:
   - `~/.claude/settings.json` and `~/.claude/settings.local.json`
   - `<repo>/.claude/settings.json` and `settings.local.json`
   - `~/.claude/plugins/config.json`, plus the `plugins` block of
     `~/.claude.json`, for installed plugins and marketplaces
   - `~/.claude/CLAUDE.md` for always-loaded rules that name a harness
     feature

   A topic is any harness surface those files exercise: a model id, a
   permission mode, `alwaysThinkingEnabled` and its neighbours, each
   hook event wired up, each MCP server, each installed plugin's name
   and what its skills and agents call, each env var, each statusline
   or output-style setting. Record the file and key each topic came
   from — the report cites it, so the user can tell a claim about their
   config from a claim about the release.

3. **Fetch the CHANGELOG** with WebFetch from
   `https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`,
   asking for every entry above `lastVersion`. Version headings are
   descending, so stop at the first heading that is `lastVersion` or
   lower. On a first run, take the newest 30 entries.

4. **Match each entry against the profile.** Keep an entry when it
   names a surface the profile records, or when it changes a default
   the profile relies on without naming it. Drop the rest silently —
   do not report a count of what was dropped, and do not keep an entry
   because it looks generally interesting.

5. **Search issues per matched topic**, one Bash call each, both
   states, bounded by the watermark:

   ```bash
   gh search issues --repo anthropics/claude-code --limit 20 --json number,title,state,closedAt,updatedAt "<topic> updated:>=<lastRun>"
   ```

   Search the topics from the profile that step 4 matched, plus any
   extra topic given in `$ARGUMENTS`. Cap at ten searches; if the
   profile yields more topics than that, search the ten whose surfaces
   the CHANGELOG entries name and say in the report which were not
   searched.

6. **Write the watermark back** to the state file: today's date, and
   the version from `claude --version`. Create the directory if
   missing. Do this last, only after the report is produced, so a
   failed run leaves the window intact for the next one.

## Report format

```text
Since <lastVersion> (<lastRun>) — now <version>, <today>.

## Affects your setup

- <CHANGELOG entry, verbatim> — <what it changes for you, one line>
  (<file>: <key>)

## Issues on those topics

<topic>:
- #<num> open — <title>
- #<num> closed <YYYY-MM-DD> — <title>

## Watch

- <entry that names a surface you configure but does not change it yet>
```

Omit any section whose list is empty. Two bounds on the middle column:
say what the entry changes for this configuration, not what the feature
is, and never assert an interaction the CHANGELOG does not state —
label a hypothesis as one.

## Notes

- If WebFetch fails, report the error verbatim and stop before writing
  the watermark.
- A plugin in the profile is a topic by name **and** by what it does:
  a hook-shipping plugin makes hook-event changes relevant even when no
  settings file of the user's mentions hooks.
