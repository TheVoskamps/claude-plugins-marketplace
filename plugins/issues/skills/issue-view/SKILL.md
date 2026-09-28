---
name: issue-view
description: Dump a single issue with body, every configured field slot, and parent/sub-issues/blockedBy/blocking relationships in one shot.
---

Print everything about a single issue in one pass — title, body,
labels, assignees, issue type, every configured field slot, parent,
sub-issues, blockedBy, and blocking — without requiring follow-up
commands.

## Invocation

```text
/issue-view <issue-number>
```

A single positional argument: the issue number in the current repo,
with or without a leading `#`. No flags.

## Execution

Run the `issue-view` script, which this plugin puts on `PATH`, with
the Bash tool from inside the repo's working tree:

```bash
issue-view <N>
```

Print its stdout to the user as it stands. On a non-zero exit, relay
its stderr verbatim and stop — the script has already worded the
error (missing or stale repo-config, issue not found).

## Output

The script prints a single block in this order:

```text
#<N> <title>    (<state>)
<url>

Labels:     <comma-separated names>
Assignees:  <comma-separated logins>
Type:       <issue-type name>
Status:     <value>
Priority:   <value>
Size:       <value>

Parent:     #<N> <title>

Sub-issues:
  - #<N> <title>

Blocked by:
  - #<N> <title>

Blocking:
  - #<N> <title>

Body:
<body verbatim>
```

- **Field-slot rows** follow the `fields:` map in
  `.issues/repo-config.md`, in the order the file lists the slots,
  except that `Size:` follows `Priority:` when both are configured. A
  slot declared `kind: skip` or absent from `fields:` has no row, and
  with no `github-project:` block there are no slot rows at all.
- A row reads `(none)` when the value is unset,
  `(not on project board)` for a project-field slot (`kind: number`
  or `kind: single-select`) on an issue that is not on the configured
  board, and `(multiple)` for a `kind: label` slot carrying more than
  one of its own labels. `/issue-set-<slot>` converges that last state;
  this verb is read-only.
- Every other empty section reads `(none)`.
- A related issue in another repo prints as `owner/repo#N`.
- Lists keep GitHub's order, and the body is printed verbatim.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Read / view" instead, which
renders the same block from `acli`.
