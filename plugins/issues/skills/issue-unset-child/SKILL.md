---
name: issue-unset-child
description: Remove one specific sub-issue from a parent (sub-issue edge), addressed from the parent side.
---

Remove one named child from a parent's sub-issues; the parent's other
sub-issues are untouched.

## Invocation

```text
/issue-unset-child <parent-N> <child-N>
```

- `<parent-N>` (required): the parent.
- `<child-N>` (required): the child to remove. Required because a
  parent may have many children.

Both are issue numbers in the current repo, with or without a leading
`#`.

## Execution

Run the `issue-unset-child` script, which this plugin puts on `PATH`,
with the Bash tool from inside the repo's working tree:

```bash
issue-unset-child <parent-N> <child-N>
```

When the child has no parent, or a parent other than `<parent-N>`,
the script is a no-op rather than an error: the end state "the child
is not under that parent" already holds. Otherwise it removes the edge
and re-reads the child, exiting non-zero when the parent is still
there. Print its stdout as it stands. On a non-zero exit, relay its
stderr verbatim and stop.

## Output

```text
Removed issue #<C> as a sub-issue of #<P>.
https://github.com/<owner>/<repo>/issues/<P>
```

The no-op prints `Issue #<C> is not a sub-issue of #<P>; no change.`
and exits zero.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Relationships" instead.
