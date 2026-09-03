# issues

Issue-tracker verbs — create, view, update, link, and set fields on an
issue — over a GitHub or Jira backend, dispatched on the `issues:`
value in the repo's config. The skills under `skills/` are the roster;
`skills/lib/` holds the contracts they share.

## Why you would want it

An issue's interesting metadata is not reachable from a single `gh`
flag. Its type, its status/priority/size fields, its parent, its
sub-issues and its blocked-by edges are Projects V2 GraphQL mutations
addressed by node ID, and the IDs are per-repo. A session that files
or updates an issue without these verbs looks those IDs up again every
time and has to get each mutation's input shape right first try.

These verbs move that lookup to setup time and record the answers in
the repo's config. Afterwards `/issue-create` files a fully configured
issue in one invocation, `/issue-view` prints one issue's body, fields
and relationships without a follow-up command, and the relationship
verbs set and clear edges by issue number from whichever end you are
thinking from. The flags do not change when the tracker does: the same
verbs serve a Jira backend, and only the calls underneath differ.

## What it needs first

- **A git working tree.** Every verb resolves the repo root itself and
  reads the config from there.
- **`.issues/repo-config.md`, written by `/issues:repo-config`.** This
  is the one prerequisite with a setup step: the interview asks which
  VCS and tracker the repo uses, discovers the project board's field
  and option IDs, and writes them down. Every verb reads the file and
  aborts pointing back at `/repo-config` when it is missing or when
  its `schema-version` is older than the reader requires. It is
  team-shared and committed, so one person runs the interview per
  repo.
- **An authenticated CLI for the backend.** `gh` for the GitHub
  backend; `acli` for Jira, plus the `issues-jira` plugin, which is
  where the Jira command templates live.

A project board is **optional**. With no `github-project:` block in
the config, the verbs and flags that need project metadata
(`--type`, `--priority`, `--size`, `--status`, and their `set-` verbs)
warn and skip rather than failing, and everything that touches only
the issue itself works unchanged.

Personal defaults — `default-assignee`, for one — are optional too,
and live in a user-config file written by `/issues:user-config` (this
repo) or `/issues:global-user-config` (this machine). Neither file
has to exist.

## Getting started

Run the interview once, then use the verbs:

```text
/issues:repo-config
```

Commit the `.issues/repo-config.md` it writes. A typical run after
that files an issue, links it under its parent, and reads it back:

```text
/issue-create --title "Cache resolved field IDs" --body-file body.md
              --type Bug --priority High --status Ready
/issue-set-parent 412 380
/issue-view 412
```

Values are always human-readable names — `High`, `Bug`, `In progress`
— matched case-insensitively against the options the config records.
A name that matches nothing is an error, never a guess.

## Skills

Every verb addresses **one** issue, by number on GitHub or by key on
Jira. Per-verb detail — flags, defaults, echo formats — lives in each
skill's own `SKILL.md`.

| Skill | What it does |
| ------- | -------------- |
| `/issue-create` | File a new issue with title, body, type, fields, parent, assignees and labels in one invocation |
| `/issue-view <N>` | Print one issue's body, project fields and every relationship in one shot |
| `/issue-view-tree <N>` | Walk an issue tree downward through sub-issues, depth-capped at 5 |
| `/issue-sub-list <parent-N>` | List a parent's direct sub-issues |
| `/issue-update <N>` | Change a title, body, labels or assignees |
| `/issue-comment <N> --body-file PATH` | Add a comment, body read from a file |
| `/issue-close <N>` | Close an issue, optionally commenting first |
| `/issue-set-status <N> <status>` | Set the status field on the issue's project item |
| `/issue-set-priority <N> <value>` | Set the priority slot |
| `/issue-set-size <N> <value>` | Set the size slot |
| `/issue-set-type <N> <type>` | Set the issue type |
| `/issue-set-parent <child-N> <parent-N>` | Make one issue a sub-issue of another |
| `/issue-set-child <parent-N> <child-N>` | The same edge, named from the parent's end |
| `/issue-unset-parent <child-N>` | Detach an issue from its parent |
| `/issue-unset-child <parent-N> <child-N>` | The same removal, named from the parent's end |
| `/issue-set-blocked-by <N> <blocker-N>` | Record that an issue is blocked |
| `/issue-set-blocks <N> <blocked-N>` | The same edge, named from the blocker's end |
| `/issue-unset-blocked-by <N> <blocker-N>` | Clear a blocked-by edge |
| `/issue-unset-blocks <N> <blocked-N>` | The same removal, named from the blocker's end |
| `/issues:repo-config` | Interview the repo's team-shared config into existence, or rewrite it whole |
| `/issues:user-config` | Merge-update this user's private per-repo settings, and keep the file ignored |
| `/issues:global-user-config` | Merge-update this user's machine-wide settings |
| `/issue-add` | Deprecated alias for `/issue-create` |
| `/issue-set-importance` | Deprecated alias for `/issue-set-priority` |

The two-verb pairs above are two views of **one** edge each, not two
edges: users think about a link from either end, so the namespace lets
them say it either way.

## What it deliberately does not do

- **No search or list-the-backlog verb.** Every verb takes an issue
  you already have the number of; a caller holding several loops.
- **No branch, commit or PR handling.** Naming an issue's branch,
  opening its PR, and writing the closing keywords belong to
  `git-tools` and `github-prs`; the multi-issue orchestrator that
  drives an issue end-to-end is `sdlc`.
- **No config written behind your back.** `/repo-config` is the only
  writer of the repo config and it rewrites the whole file from an
  interview; no verb edits it mid-run to record what it discovered.

## The config paths are literals every consumer spells itself

This plugin owns these paths:

- `.issues/repo-config.md` — team-shared, committed, written by
  `/issues:repo-config`.
- `.issues/user-config.md` — one user, one repo, gitignored, written
  by `/issues:user-config`.
- `$XDG_CONFIG_HOME/issues/user-config.md` — machine-wide per-user,
  written by `/issues:global-user-config`, outside every git clone.

None of them is a naming preference, and each replaced a
`.claude/rules/` path deliberately. Claude Code auto-loads every
un-scoped `.claude/rules/*.md` into every session and subagent on every
turn, so a config living there was carried by sessions that never
invoke an issue verb — and a config is reference data a reader fetches,
not an instruction the model holds. Do not move any of them back.

Nothing factors those literals out, because plugins are file-sandboxed:
a consumer in another plugin cannot follow `skills/lib/repo-config.md`
and writes the path out instead. `.issues/repo-config.md` crosses the
boundary two ways — consumers in `git-tools`, `github-prs` and `sdlc`
inline-parse only the front-matter each one needs, never the whole
contract, while other files merely mention it, and a prose mention goes
stale as loudly as a reader does. So a PR that moves or renames a
config path edits every plugin that **spells** it and bumps each of
their versions, in one PR. Sweep by grepping the literal —
`grep -rn '\.issues/' plugins/` and
`grep -rn 'XDG_CONFIG_HOME/issues' plugins/` — not by opening the
plugins the diff already touched.

These are deliberately *not* duplicated, and adding a copy is the
defect rather than a helpful expansion:

- **Who reads repo-config.** A reader contract states what a file
  provides, never who consumes it, so neither `skills/lib/repo-config.md`
  nor `skills/repo-config/SKILL.md` names a consumer, and a new reader
  in another plugin is no edit here.
- **The `$XDG_CONFIG_HOME` fallback.** `skills/lib/user-config.md` →
  "Where `$XDG_CONFIG_HOME` resolves" is the single definition of what
  an unset or empty variable resolves to; a consumer needing the rule
  points at that heading.

Nothing migrates a repo or a machine off the old paths. The interview
skills look only at the new path, so an already-configured repo re-runs
from built-in defaults and the old file stays put; deleting it is the
operator's job. The one automated cleanup is `/issues:user-config`
removing a stale `.claude/rules/user-config.md` line from `.gitignore`.
A repo whose `.gitignore` is an allow-list — the marketplace repo
included — also needs a `!` line so the committed
`.issues/repo-config.md` is not ignored.
