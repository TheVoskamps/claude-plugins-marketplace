---
name: issue-unset-blocks
description: Remove a blocking relationship between two issues (blocker's side). Idempotent.
---

Clear "issue N blocks issue B". This is the blocker's-end view of the
edge `/issue-unset-blocked-by` clears: `unset-blocks N B` is the same
removal as `unset-blocked-by B N`.

## Invocation

```text
/issue-unset-blocks <N> <blocked-N>
```

- `<N>` (required): the former blocker.
- `<blocked-N>` (required): the formerly blocked issue.

Either operand may be `N`, `#N`, or `owner/repo#N`; the last names an
issue in another GitHub repo.

## Execution

Run the `issue-unset-blocks` script, which this plugin puts on `PATH`,
with the Bash tool from inside the repo's working tree:

```bash
issue-unset-blocks <N> <blocked-N>
```

The script resolves each operand in the repo it names, is a no-op when
there is no such edge, and otherwise removes it and re-reads the
blocker, exiting non-zero when the edge is still there. Print its
stdout as it stands. On a non-zero exit, relay its stderr verbatim and
stop.

## Output

```text
Removed blocking relationship: issue <N> no longer blocks <B>.
<url of the former blocker>
```

The no-op prints `Issue <N> does not block <B>; no change.` and exits
zero. An issue prints as `#<N>` in the current repo and as
`owner/repo#N` in another.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Relationships" instead,
where an `owner/repo#N` operand is refused.
