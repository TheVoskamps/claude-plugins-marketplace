---
name: issue-set-blocked-by
description: Declare that one issue is blocked by another (blocked-by edge). Idempotent.
---

Add a blocked-by relationship: "issue N is blocked by issue B".
This is one side of the blocked-by edge — `/issue-set-blocks` is the
same edge from the blocker's perspective.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, the "One edge, two sides" pattern, and error wording. This
file documents only what is specific to `/issue-set-blocked-by`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.issues/repo-config.md`.

## Invocation

```text
/issue-set-blocked-by <N> <blocker-N>
```

- `<N>` (required): the **blocked** issue (the one that can't proceed
  until the blocker is done).
- `<blocker-N>` (required): the **blocker** (the prerequisite).

Either operand may be `N`, `#N`, or `owner/repo#N` — the last names
an issue in another GitHub repo, so the two issues need not share a
repo. See "Operand resolution" in `skills/lib/issue.md`.

Mnemonic: "set blocked-by of N to B" reads left-to-right.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Look up node IDs for both issues.** Resolve each operand per
   "Operand resolution" in `skills/lib/issue.md`, then run the
   node-ID lookup template from the same file for each, trimmed to
   `id` plus, on the blocked side, `url` and
   `blockedBy(first: 50) { nodes { id } }` (to detect an existing
   relationship for the idempotency check).
   If the blocked issue might have more than 50 blockers, the
   idempotency check may miss an existing edge and the mutation will
   then no-op on the server side; the mutation itself is safe to
   retry, so this is acceptable.

2. **Idempotency check.** If the blocker's resolved node ID is
   already among the blocked issue's `blockedBy.nodes` IDs, no-op:
   print one line (`Issue <N> is already blocked by <B>; no
   change.`) and exit zero. Match on the node ID, never on `number`:
   either list can carry an issue from another repo.

3. **Create the edge** via the `addBlockedBy` template from
   `skills/lib/issue.md`, with `<N>` as the **blocked** issue and
   `<blocker-N>` as the **blocker**, each supplied as its node ID.

4. **Issue not found**: if either node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue and abort, identifying which issue was missing.

## Output

```text
Marked issue <N> as blocked by <B>.
<url of the blocked issue>
```

`<N>` and `<B>` print as `#<N>` for an issue in the current repo and
as `owner/repo#N` for an issue in another repo, per "Operand
resolution" in `skills/lib/issue.md`. The URL is the `url` the
blocked issue's lookup returned.
