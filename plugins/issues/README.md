# issues

Issue-tracker verbs for Claude Code: create, view, update, link, and
set fields on an issue, list a project board's issues in work order,
and report what a field accepts. The same verbs serve a GitHub or a
Jira tracker, chosen by the `issues:` value in the repo's config.

## Why you would want it

An issue's interesting metadata is not reachable from a single `gh`
flag. Its type, its status, priority and size fields, its parent, its
sub-issues and its blocked-by edges are GraphQL mutations addressed by
node ID, and the IDs differ per repo. A session that files or updates
an issue without these verbs looks those IDs up again every time, and
has to get each mutation's input shape right first try.

These verbs move that lookup to setup time and record the answers in
the repo's config. Afterwards `/issue-create` files a fully configured
issue in one invocation, `/issue-view` prints one issue's body, project
fields, the pull requests that close it and every relationship without
a follow-up command, and the relationship verbs set and clear edges by
issue reference from whichever end you are thinking from. The flags do
not change when the tracker does.

On GitHub each verb is a script rather than a procedure Claude carries
out from prose. The same invocation makes the same calls every time,
reports a failure in the same words, and checks its own writes, so a
verb that exits zero did what it printed.

## What you need first

- **A git working tree.** Every verb finds the repo root itself and
  reads the config from there.
- **`.issues/repo-config.md`, written by `/issues:repo-config`.** The
  interview asks which VCS and tracker the repo uses, discovers the
  project board's fields and options, and writes them down. The file is
  team-shared and committed, so one person runs the interview per repo.
  A verb acting on an issue here stops and points you back at
  `/issues:repo-config` when the file is missing, older than the verb
  supports, or invalid.
- **An authenticated CLI for the tracker.** For GitHub: `gh`, `jq` and
  `curl`, and nothing newer than the bash 3.2 that macOS ships. For
  Jira: `acli`, plus the `issues-jira` plugin.

A project board is optional. Without one, everything that touches only
the issue itself works unchanged: bodies, comments, labels, assignees,
parents and blocked-by edges. The verbs that reach board fields degrade
in one of two ways:

- `/issue-create` warns and skips `--type`, `--priority`, `--size` and
  `--status`, so the issue is still filed.
- `/issue-set-type`, `/issue-set-priority`, `/issue-set-size` and
  `/issue-set-status` stop and point at `/issues:repo-config`, because
  setting the field is the whole run there. `/issue-list` stops the
  same way unless you name a board with `--project` or a URL.

A field the config marks as not tracked is different again: a verb that
would set it exits zero with a warning, and `/issue-field-options`
reports it as unconfigured.

Personal defaults, such as a default assignee, are optional too.
`/issues:user-config` records them for you in this repo, in a file it
keeps out of git, and `/issues:global-user-config` records them for you
on this machine. Neither file has to exist, and a key left empty in one
falls through to the other. The one personal value a verb insists on is
the branch prefix: when the repo's config says branch names start with
your initials or your name, `/issues:issue-branch-prefix` needs that
value in one of the two files before it can print a prefix.

## Getting started

Run the interview once:

```text
/issues:repo-config
```

Commit the `.issues/repo-config.md` it writes. If the repo's
`.gitignore` is an allow-list, add a `!` line for the file so it is not
ignored. A typical run after that files an issue, links it under its
parent, and reads it back:

```text
/issue-create --title "Cache resolved field IDs" --body-file body.md
              --type Bug --priority High --status Ready
/issue-set-parent 412 380
/issue-view 412
```

Field values are the names you see on the board, such as `High`, `Bug`
or `In progress`, matched case-insensitively against the options the
config records. A name that matches nothing is an error, never a guess.
A numeric field takes an integer within the bounds the config sets.

To see what a field accepts before setting it, ask:

```text
/issue-field-options status
```

It prints the field's kind, its options in the config's own order and
its default when it has one. The argument is the field's key in the
config, `status`, `priority` or `size` among them. For this repo it
reads only the config, so it needs no board and makes no call.

## Skills

Every verb but `/issue-list` addresses one issue: an issue reference on
GitHub, a key on Jira. `/issue-list` takes none and prints one line per
issue it finds.

| Skill | What it does |
| ------- | -------------- |
| `/issue-create [<repo>] [--parent <issue>]` | File a new issue with title, body, type, fields, parent, assignees and labels in one invocation, here or in another repo |
| `/issue-view <issue>` | Print one issue's body, project fields, the pull requests that close it and every relationship in one shot |
| `/issue-view-tree <issue>` | Walk an issue tree downward through sub-issues, depth-capped at 5 |
| `/issue-sub-list <parent-issue>` | List a parent's direct sub-issues |
| `/issue-list [<owner> \| <owner>/<repo>] [--project <number\|url>] --status <name> [--view <name\|number\|url>] [--assignee <login>]... [--unassigned] [--limit <n>]` | List a project board's open issues at one status, in the board's position order or a view's sort: the configured board in one repository, or with `--project` or a URL an owner's board across its repositories or in one |
| `/issue-update <issue>` | Change a title, body, labels or assignees |
| `/issue-comment <issue> --body-file PATH` | Add a comment, body read from a file |
| `/issue-close <issue> [--reason <reason>]` | Close an issue, optionally commenting first, and optionally set the close reason: completed, not planned, or a duplicate of a named issue |
| `/issue-set-status <issue> <status>` | Set the status field on the issue's project item |
| `/issue-set-priority <issue> <value>` | Set the priority field |
| `/issue-set-size <issue> <value>` | Set the size field |
| `/issue-set-type <issue> <type>` | Set the issue type |
| `/issue-field-options [[<repo>] <slot>]`, `/issue-field-options [<repo>] --all` | Report a field's configured kind, default and options, or every field's with `--all` or with nothing named, here or for another repo |
| `/issue-set-parent <child-issue> <parent-issue>` | Make one issue a sub-issue of another |
| `/issue-set-child <parent-issue> <child-issue>` | The same edge, named from the parent's end |
| `/issue-unset-parent <child-issue>` | Detach an issue from its parent |
| `/issue-unset-child <parent-issue> <child-issue>` | The same removal, named from the parent's end |
| `/issue-set-blocked-by <issue> <blocker-issue>` | Record that an issue is blocked |
| `/issue-set-blocks <issue> <blocked-issue>` | The same edge, named from the blocker's end |
| `/issue-unset-blocked-by <issue> <blocker-issue>` | Clear a blocked-by edge |
| `/issue-unset-blocks <issue> <blocked-issue>` | The same removal, named from the blocker's end |
| `/issues:repo-config` | Interview the repo's team-shared config into existence, or rewrite it whole |
| `/issues:user-config` | Merge-update your private settings for this repo, and keep the file ignored |
| `/issues:global-user-config` | Merge-update your machine-wide settings |
| `/issues:issue-branch-prefix` | Print the branch-prefix mode the repo config names and the literal prefix it resolves to for you |
| `/issue-add` | Deprecated alias for `/issue-create` |
| `/issue-set-importance` | Deprecated alias for `/issue-set-priority` |

A parent/child pair of verbs, like a blocked-by/blocks pair, writes one
edge, not two: you think about a link from either end, so you can say
it from either end.

## Issues in other repositories

On GitHub an issue operand, and `--parent`'s value, is an issue
reference, and a reference can name any repository:

- `N` or `#N` for an issue in this repo;
- `repo#N` for one under the same owner;
- `owner/repo#N` for one on the same host;
- `host/owner/repo#N` for one on another host, such as a GitHub
  Enterprise server;
- the issue's `https://` URL.

You supply only the part that differs from where you stand. Every
reference a verb prints is the shortest form that leads back to the
same issue from this checkout, so a reference copied out of one verb's
output, or out of a browser, is an operand for the next.

A relationship verb's operands need not share a repo: a blocked-by or
sub-issue edge can join an issue here to one elsewhere.
`/issue-create`, `/issue-field-options` and `/issue-list` take a
leading `<repo>` to act in another repository instead.

Each repository is governed by its own config. For another repo a verb
reads that repo's `.issues/repo-config.md` from its default branch, so
the names a field accepts there are that repo's names. When that repo
has no config:

- `/issue-create` files a plain issue, with title, body, labels and
  assignees, and notes that project fields were skipped;
- `/issue-view` prints the issue without field rows;
- `/issue-field-options` reports every field as unconfigured;
- a field setter stops, naming the repository;
- everything that touches only the issue itself proceeds.

A missing config in this checkout does not stop work on another repo's
issues. Your default assignee for another repo comes from your
machine-wide settings only, because the per-repo ones belong to this
repo.

Every call goes to the host the repository is on. Inside a checkout
whose `origin` is on a GitHub Enterprise server, a bare `owner/repo`
means that server, not github.com, and one session can work across
several hosts without changing any environment variable.

## What a verb checks for you

A malformed argument stops a verb with exit status 2 before anything is
sent to GitHub. Every other failure exits non-zero with the reason on
stderr.

A verb that changes an issue re-reads what it set, and exits non-zero
when the re-read does not show it. That catches a label or assignee
GitHub accepted and silently dropped: the report still prints, and the
exit status says the write did not land. When `/issue-create` fails
after the issue exists, stderr names the issue, its URL and what was
already done; nothing is rolled back.

The verbs act on issues only. A pull request's URL is refused before
any call, and a number that turns out to be a pull request stops the
verb once read, naming it as one.

A board set to add every new issue itself can race the verb's own add.
The verb treats GitHub's "already exists in this project" as success:
it waits for the item to appear, re-reading up to 5 times at 5-second
intervals, and sets the fields you asked for on that item.

## Listing a board

`/issue-list` answers "what should be worked next" from the project
board:

```text
/issue-list --status Ready --assignee octocat --unassigned --limit 10
```

Which issues it prints is decided by GitHub, not by the verb. The view's
filter, the status, the assignees and the repository go to the board as
one search, so a view's filter means exactly what it means in the
board's own UI.

The order is the board's position order. With a `--view` that sorts,
the list follows the view's sort instead, ties keeping position order
and items with no value sorting last. A view sorted by a field the verb
cannot read stops the run, naming the field, rather than printing an
order that would pass for the view's and be wrong.

Without `--project` or a URL, the verb lists the board the repo's
config names, in this repository, and `--status` is one of the config's
status names. With either, it lists any board you can read, across its
repositories or in one, needs no config in this checkout, and
`--status` is an option of the board's own `Status` field.

## On Jira

When the repo's config says `issues: Jira`, the same verbs take the
same flags and address work items by key, such as `PROJ-412`; a bare
number is completed with the project's key prefix. Claude carries the
verb out through `acli`, which needs the `issues-jira` plugin
installed.

What differs:

- `/issue-list` does not support Jira.
- `/issue-view` prints `closed-by: unsupported`.
- The repository-qualified reference forms are GitHub-only, because a
  Jira key is already unique across projects. An operand naming a
  repository that is tracked in Jira stops the verb before the issue is
  read.

`/issues:issue-branch-prefix` and `/issue-field-options` read only
config, so they work under either tracker and without `acli`.

## What it deliberately does not do

- **No search or list-the-backlog verb.** Every verb takes an issue you
  already have a reference to. `/issue-list` is the one exception: it
  lists one board at one status, and searches nothing else.
- **No branch, commit or PR handling.** Naming an issue's branch,
  opening its PR and writing the closing keywords belong to the
  `git-tools` and `github-prs` plugins. What this plugin owns is the
  value a branch name is prefixed with, which
  `/issues:issue-branch-prefix` prints.
- **No config written behind your back.** `/issues:repo-config` is the
  only writer of the repo config, and it rewrites the whole file from
  an interview. It refuses a draft the verbs would reject, leaving an
  existing file untouched, and no verb edits the file mid-run to record
  what it discovered.
- **No rollback.** When `/issue-create` fails after the issue exists,
  it reports what it completed and leaves it in place.
- **No guessing.** A field value or status name that matches nothing
  stops the verb; it never picks the nearest name.
