---
name: issue-set-blocks
description: Declare that one issue blocks another (blocked-by edge from the blocker's side). Sugar for /issue-set-blocked-by with inverted args.
---

Record "issue N blocks issue B". This is the blocker's-end view of the
edge `/issue-set-blocked-by` writes: `set-blocks N B` is the same edge
as `set-blocked-by B N`.

## Invocation

```text
/issue-set-blocks <N> <blocked-N>
```

- `<N>` (required): the **blocker**, the prerequisite.
- `<blocked-N>` (required): the issue being **blocked** by N.

Each operand is `N` or `#N` in the current repo, or `repo#N`,
`owner/repo#N`, `host/owner/repo#N` or
`https://host/owner/repo/issues/N` in another, as `skills/lib/issue.md`
→ "Repositories and issue references" resolves them, so the two need not
share a repo. Mnemonic: "set blocks of N to B" — "N blocks B".

## Execution

Run the `issue-set-blocks` script, which this plugin puts on `PATH`,
with the Bash tool from inside the repo's working tree:

```bash
issue-set-blocks <N> <blocked-N>
```

The script resolves each operand in the repo it names, is a no-op when
the edge already exists, and otherwise creates it and re-reads the
blocker, exiting non-zero when the edge is not there. Print its stdout
as it stands. On a non-zero exit, relay its stderr verbatim and stop;
an operand that does not resolve is reported against its own repo.

## Output

```text
Marked issue <N> as blocking <B>.
<url of the blocker>
```

The no-op prints `Issue <N> already blocks <B>; no change.` and exits
zero. An issue reference prints as
`skills/lib/issue.md` → "Repositories and issue references" states.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Relationships" instead,
where a `<repository>#N` operand is refused.
