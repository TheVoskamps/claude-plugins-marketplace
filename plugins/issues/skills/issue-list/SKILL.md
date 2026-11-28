---
name: issue-list
description: List a project board's open issues at one status, in the order they should be worked — the board's position order, or a named view's sort — filtered by assignee if asked. Lists the board a repository's repo-config names, for that repository, or with `--project` or a project URL any owner's board, across every repository on it or for one. Read-only.
---

# Issue List

List a project board's open issues at one status, one line per issue,
in the board's position order or a view's sort: the board a
repository's repo-config names, in that repository, or — with
`--project` or a project URL — an owner's board, across every
repository on it or in one. This
is the verb that takes no issue reference: a caller working a board has
none until the board gives it one.

## Invocation

```text
/issue-list [<owner> | <owner>/<repo>] [--project <number|url>] --status <name>
            [--view <name|number|url>] [--assignee <login>]... [--unassigned] [--limit <n>]
```

- `<owner>/<repo>`: list this repository's issues instead of the
  current one's, written in any form `skills/lib/issue.md` →
  "Repositories and issue references" states, a bare single word being a
  repository under the current owner. Without `--project` or a URL its
  own repo-config governs the run, and the board listed is the one its
  `github-project:` block names. With either, the board listed is the
  one they name, the list is scoped to this repository, and it needs no
  repo-config.
- `<owner>`: with `--project` or a URL, a bare single word is an owner,
  never a repository, and the board is listed across every repository
  on it. A repository under the current owner is then written
  `<owner>/<repo>`.
- `--project`: the board, by number under the positional's owner — an
  organization or a user — or by URL,
  `https://<host>/orgs/<owner>/projects/<n>` or the `users/` form, which
  supplies owner and number and makes the positional optional.
- `--status` (required): without `--project` or a URL, one option of
  the configured `status` slot; with either, one option of the board's
  single-select field named `Status`. Matched case-insensitively.
- `--view`: a view of the board, by name, by number, or by URL,
  `.../projects/<n>/views/<v>`, which supplies owner, project number
  and view, so it lists from any directory. A name matches
  case-insensitively for ASCII letters only, so `é` does not match `É`.
  Its filter narrows the list and its sort orders it.
- `--assignee`, repeatable: issues assigned to any of these logins.
  `--unassigned`: issues assigned to no one. With both, an issue
  matching either is listed; with neither, assignees do not filter.
- `--limit`: print at most this many lines, counted after ordering.

## Execution

Run the `issue-list` script, which this plugin puts on `PATH`, with the
Bash tool from inside the repo's working tree, passing the arguments
unchanged:

```bash
issue-list [<owner> | <owner>/<repo>] [--project <number|url>] --status <name> \
  [--view <name|number|url>] [--assignee <login>]... [--unassigned] [--limit <n>]
```

Print its stdout as it stands. On a non-zero exit, relay its stderr
verbatim and stop.

## Output

One line per issue, tab-separated, in this column order:

```text
<issue-reference>  <status>  <priority>  <size>  <open-blockers>  <assignees>  <title>
```

- `<issue-reference>` is the current repository's `issue-link-prefix`
  followed by the number for an issue of the current repository,
  whichever repository is listed — `#` when the current repository has
  no repo-config — and otherwise the shortest form
  `skills/lib/issue.md` → "Repositories and issue references" gives
  that names the issue's repository.
- `<status>` is the status slot's value without `--project` or a URL,
  and with either the item's value of the board's `Status` field.
- `<priority>` and `<size>`, without `--project` or a URL, are the slot
  values, or `-` when unset or when the slot is unconfigured. With
  either, they are the slot values of the issue's own repository's
  repo-config, read from its default branch even for the current
  repository, once per repository; when that repo-config is absent or
  unusable — tracked in Jira, at an unsupported schema version, or
  otherwise invalid — they are the item's value of the board field of
  the same name, else `-`.
- `<open-blockers>` counts the issue's blocked-by issues that are open.
- `<assignees>` is the logins joined with `,`, or `-`.

No issue matching prints nothing and exits zero.

Lines follow the board's position order. With a `--view` that sorts,
they follow the view's sort fields in order and direction, items tied
on every field keeping position order and an item with no value in a
field sorting after those with one. A single-select field sorts by its
options' order. A view may sort only by number, single-select, text,
title, date and iteration fields; one sorting by any other field kind —
assignees, labels and the like — aborts naming the field.

The run aborts, printing no issue line, when `--status` names no option
it resolves against and when `--view` matches no view; the last names
the board's views. Without `--project` or a URL it also aborts when the
repo-config has no `github-project:` block or no `status` slot of
`kind: single-select`. With either, the local repo-config never aborts
the run. It aborts too on:

- a bare `<owner>` with no `--project` and no URL, where no current
  repository makes it a repository — an owner can hold many boards and
  nothing names one;
- an owner or project number in a URL that disagrees with the
  positional's owner or with `--project`;
- `--view <url>` and `--project` naming different projects;
- a board with no single-select field named `Status`.

## Jira backend

This verb does not support `issues: Jira`: the script's refusal under
it ends the run, and there is no Jira procedure to follow instead. With
`--project` or a URL no repo-config governs the run, so a Jira-tracked
local one does not stop it.
