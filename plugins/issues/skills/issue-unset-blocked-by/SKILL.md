---
name: issue-unset-blocked-by
description: Remove a blocked-by relationship between two issues. Idempotent.
---

Clear "issue N is blocked by issue B". This is one side of the
blocked-by edge — `/issue-unset-blocks` clears the same edge named
from the blocker's end.

## Invocation

```text
/issue-unset-blocked-by <issue> <blocker-issue>
```

- `<issue>` (required): the formerly blocked issue.
- `<blocker-issue>` (required): the blocker to detach.

Each operand is an issue reference, and the two need not share a repo.

## Execution

Run the `issue-unset-blocked-by` script, which this plugin puts on
`PATH`, with the Bash tool from inside the repo's working tree:

```bash
issue-unset-blocked-by <issue> <blocker-issue>
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
exits zero. An issue reference prints as
`skills/lib/issue.md` → "Repositories and issue references" states.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before it reads or writes an
issue; follow
`skills/lib/issue.md` → "Jira backend" → "Relationships" instead,
where a `<repository>#N` operand is refused.
