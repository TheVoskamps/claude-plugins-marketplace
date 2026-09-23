---
name: issue-unset-blocked-by
description: Remove a blocked-by relationship between two issues. Idempotent.
---

Remove a blocked-by relationship: "issue N is no longer blocked by
issue B". This is one side of the blocked-by edge —
`/issue-unset-blocks` is the same edge from the blocker's
perspective.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, the "One edge, two sides" pattern, and error wording. This
file documents only what is specific to `/issue-unset-blocked-by`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.issues/repo-config.md`.

## Invocation

```text
/issue-unset-blocked-by <N> <blocker-N>
```

- `<N>` (required): the formerly blocked issue.
- `<blocker-N>` (required): the blocker to detach.

Either operand may be `N`, `#N`, or `owner/repo#N` — the last names
an issue in another GitHub repo, so the two issues need not share a
repo. See "Operand resolution" in `skills/lib/issue.md`.

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
   `blockedBy(first: 50) { nodes { id } }` (to detect a missing
   relationship for the idempotency check).

2. **Idempotency check.** If the blocker's resolved node ID is not
   among the blocked issue's `blockedBy.nodes` IDs, no-op: print one
   line (`Issue <N> is not blocked by <B>; no change.`) and exit
   zero. Match on the node ID, never on `number`: either list can
   carry an issue from another repo.

3. **Remove the edge** via the `removeBlockedBy` template from
   `skills/lib/issue.md`, with `<N>` as the **blocked** issue and
   `<blocker-N>` as the **blocker**, each supplied as its node ID.

4. **Issue not found**: if either node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue and abort.

## Output

```text
Removed blocked-by relationship: issue <N> is no longer blocked by <B>.
<url of the formerly blocked issue>
```

`<N>` and `<B>` print as `#<N>` for an issue in the current repo and
as `owner/repo#N` for an issue in another repo, per "Operand
resolution" in `skills/lib/issue.md`. The URL is the `url` the
formerly blocked issue's lookup returned.
