---
name: issue-set-blocked-by
description: Declare that one issue is blocked by another (blocked-by edge). Idempotent.
---

Record "issue N is blocked by issue B". This is one side of the
blocked-by edge — `/issue-set-blocks` writes the same edge named from
the blocker's end.

## Invocation

```text
/issue-set-blocked-by <issue> <blocker-issue>
```

- `<issue>` (required): the **blocked** issue, which can't proceed until
  the blocker is done.
- `<blocker-issue>` (required): the **blocker**, the prerequisite.

Each operand is an issue reference, and the two need not share a repo.
Mnemonic: "set blocked-by of N to B" reads left-to-right.

## Execution

Run the `issue-set-blocked-by` script, which this plugin puts on
`PATH`, with the Bash tool from inside the repo's working tree:

```bash
issue-set-blocked-by <issue> <blocker-issue>
```

The script resolves each operand in the repo it names, is a no-op when
the edge already exists, and otherwise creates it and re-reads the
blocked issue, exiting non-zero when the edge is not there. Print its
stdout as it stands. On a non-zero exit, relay its stderr verbatim and
stop; an operand that does not resolve is reported against its own
repo.

## Output

```text
Marked issue <N> as blocked by <B>.
<url of the blocked issue>
```

The no-op prints `Issue <N> is already blocked by <B>; no change.` and
exits zero. An issue reference prints as
`skills/lib/issue.md` → "Repositories and issue references" states.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Relationships" instead,
where a `<repository>#N` operand is refused.
