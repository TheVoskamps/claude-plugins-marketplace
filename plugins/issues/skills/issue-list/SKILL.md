---
name: issue-list
description: List the project board's open issues for one repository at one status, in the order they should be worked — the board's position order, or a named view's sort — filtered by assignee if asked. Read-only.
---

List the configured project board's open issues in one repository at
one status, one line per issue, in the board's position order or a
view's sort. This
is the verb that takes no issue reference: a caller working a board has
none until the board gives it one.

## Invocation

```text
/issue-list [<owner>/<repo>] --status <name> [--view <name-or-number>]
            [--assignee <login>]... [--unassigned] [--limit <n>]
```

- `<owner>/<repo>`: list this repository's issues instead of the
  current one's, written in any form `skills/lib/issue.md` →
  "Repositories and issue references" lists. Its own repo-config
  governs the run, and the board listed is the one its
  `github-project:` block names.
- `--status` (required): one option of the configured `status` slot,
  matched case-insensitively.
- `--view`: a view of the board, by name (case-insensitive) or by
  number. Its filter narrows the list and its sort orders it.
- `--assignee`, repeatable: issues assigned to any of these logins.
  `--unassigned`: issues assigned to no one. With both, an issue
  matching either is listed; with neither, assignees do not filter.
- `--limit`: print at most this many lines, counted after ordering.

## Execution

Run the `issue-list` script, which this plugin puts on `PATH`, with the
Bash tool from inside the repo's working tree, passing the arguments
unchanged:

```bash
issue-list [<owner>/<repo>] --status <name> [--view <name-or-number>] \
  [--assignee <login>]... [--unassigned] [--limit <n>]
```

Print its stdout as it stands. On a non-zero exit, relay its stderr
verbatim and stop.

## Output

One line per issue, tab-separated, in this column order:

```text
<issue-reference>  <status>  <priority>  <size>  <open-blockers>  <assignees>  <title>
```

- `<issue-reference>` is the repo-config's `issue-link-prefix` followed
  by the number.
- `<priority>` and `<size>` are the slot values, or `-` when unset or
  when the slot is unconfigured.
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

The run aborts, printing no issue line, when the repo-config has no
`github-project:` block or no `status` slot of `kind: single-select`,
when `--status` names no option of that slot, and when `--view`
matches no view; the last names the board's views.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before it reads the board;
follow `skills/lib/issue.md` → "Jira backend" → "List" instead, which
produces the same lines through `acli`.
