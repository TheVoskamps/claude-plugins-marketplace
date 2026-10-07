---
name: issue-set-parent
description: Link a child issue to a parent (sub-issue edge) by adding the child as a sub-issue of the parent.
---

Make one issue a sub-issue of another, named from the child's end.
`/issue-set-child` writes the same edge with the arguments the other
way round.

## Invocation

```text
/issue-set-parent <child-issue> <parent-issue>
```

- `<child-issue>` (required): the issue becoming a sub-issue.
- `<parent-issue>` (required): the containing issue.

Each is an issue reference, and the two need not share a repo.
Mnemonic: "set parent of C to P" reads left-to-right.

## Execution

Run the `issue-set-parent` script, which this plugin puts on `PATH`,
with the Bash tool from inside the repo's working tree:

```bash
issue-set-parent <child-issue> <parent-issue>
```

An issue has at most one parent. The script is a no-op when the child
is already under that parent, refuses when it is under a different
one, and otherwise links it and re-reads the child's parent, exiting
non-zero when the re-read does not show the link. Print its stdout as
it stands. On a non-zero exit, relay its stderr verbatim and stop.

## Output

```text
Linked issue #<C> as a sub-issue of #<P>.
https://github.com/<owner>/<repo>/issues/<P>
```

The no-op prints `Issue #<C> is already a sub-issue of #<P>; no
change.` and exits zero. A child under another parent is an error:

> issue `#<C>` already has parent `#<existing-P>`; remove it first
> with `/issue-unset-parent #<C>` before setting a new parent

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before it reads or writes an
issue; follow
`skills/lib/issue.md` → "Jira backend" → "Relationships" instead.
