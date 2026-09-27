---
name: issue-unset-parent
description: Remove a child issue from its current parent (sub-issue edge), looked up from the child side.
---

Detach an issue from its parent. Only the child is named: an issue has
at most one parent, so the script looks the parent up.

## Invocation

```text
/issue-unset-parent <child-N>
```

- `<child-N>` (required): issue number in the current repo, with or
  without a leading `#`.

## Execution

Run the `issue-unset-parent` script, which this plugin puts on
`PATH`, with the Bash tool from inside the repo's working tree:

```bash
issue-unset-parent <child-N>
```

The script is a no-op when the issue has no parent, and otherwise
removes the edge and re-reads the child, exiting non-zero when the
parent is still there. Print its stdout as it stands. On a non-zero
exit, relay its stderr verbatim and stop.

## Output

The confirmation names the former parent and prints the child's URL:

```text
Removed issue #<C> as a sub-issue of #<former-P>.
https://github.com/<owner>/<repo>/issues/<C>
```

The no-op prints `Issue #<C> has no parent; no change.` and exits
zero.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Relationships" instead.
