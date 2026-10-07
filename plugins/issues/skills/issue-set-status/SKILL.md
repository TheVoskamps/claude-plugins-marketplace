---
name: issue-set-status
description: Set the status slot on a single issue by human-readable name, adding the issue to the project board first when the slot is a board field it is not on yet.
---

Set the status slot on a single issue — the slot declared as
`github-project.fields.status` in `.issues/repo-config.md`, normally a
`kind: single-select` field on the configured Project V2 board. The
issue is added to the board first when it is not on it yet.

## Invocation

```text
/issue-set-status <issue> <status-name>
```

- `<issue>` (required): an issue reference. In another repo the slot is that
  repo's own.
- `<status-name>` (required): a human-readable status name (e.g.
  `Todo`, `In Progress`, `Done`), matched case-insensitively against
  the slot's configured options. Whitespace inside a name is
  significant, and a multi-word name is one quoted argument. A name
  that matches nothing is an error, never a guess — run
  `/issue-field-options status` when you need to choose one.

## Execution

Run the `issue-set-status` script, which this plugin puts on `PATH`,
with the Bash tool from inside the repo's working tree:

```bash
issue-set-status <issue> "<status-name>"
```

The script resolves the name, writes it, and re-reads the status; it
exits non-zero when the re-read does not show the value it set. Print
its stdout as it stands. On a non-zero exit, relay its stderr verbatim
and stop: it carries the canonical wording for a missing
`github-project:` block, a name not in the options, an issue not
found, a stale field ID (re-run `/repo-config`), or a write that did
not land.

## Output

On success, one confirmation line using the option's canonical
capitalization, then the issue URL:

```text
Set status on issue #<N> to <canonical-name>.
https://github.com/<owner>/<repo>/issues/<N>
```

When the repo's `status` slot is `kind: skip` or absent from
`fields:`, the script prints this line instead and exits **zero** — a
warning, not an error:

> `/issue-set-status` has nothing to do: this repo has no `status`
> slot configured. (Run `/repo-config` to add one.)

For an issue in another repository, the line names that repository in
place of `this repo`, and says to run `/repo-config` in it.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before it reads or writes an
issue; follow
`skills/lib/issue.md` → "Jira backend" → "Metadata setters" instead.
