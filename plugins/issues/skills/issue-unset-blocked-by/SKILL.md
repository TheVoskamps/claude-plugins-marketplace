---
name: issue-unset-blocked-by
description: Remove a blocked-by relationship between two issues. Idempotent.
---

Clear "issue N is blocked by issue B". This is one side of the
blocked-by edge — `/issue-unset-blocks` clears the same edge named
from the blocker's end.

## Invocation

```text
/issue-unset-blocked-by <N> <blocker-N>
```

- `<N>` (required): the formerly blocked issue.
- `<blocker-N>` (required): the blocker to detach.

Either operand may be `N`, `#N`, or `owner/repo#N`; the last names an
issue in another GitHub repo.

## Execution

Run the `issue-unset-blocked-by` script, which this plugin puts on
`PATH`, with the Bash tool from inside the repo's working tree:

```bash
issue-unset-blocked-by <N> <blocker-N>
```

The script resolves each operand in the repo it names, is a no-op when
there is no such edge, and otherwise removes it and re-reads the
blocked issue, exiting non-zero when the edge is still there. Print
its stdout as it stands. On a non-zero exit, relay its stderr verbatim
and stop.

## Output

```text
Removed blocked-by relationship: issue <N> is no longer blocked by <B>.
<url of the formerly blocked issue>
```

The no-op prints `Issue <N> is not blocked by <B>; no change.` and
exits zero. An issue prints as `#<N>` in the current repo and as
`owner/repo#N` in another.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Relationships" instead,
where an `owner/repo#N` operand is refused.
