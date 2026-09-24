---
name: issue-unset-blocks
description: Remove a blocking relationship between two issues (blocker's side). Idempotent.
---

Remove a blocking relationship: "issue N no longer blocks issue B".
This is the blocker's-side view of the same edge that
`/issue-unset-blocked-by` exposes — both verbs clear that one edge
with the `removeBlockedBy` template; which CLI argument names the
blocker is what differs.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, the "One edge, two sides" pattern, and error wording. This
file documents only what is specific to `/issue-unset-blocks`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.issues/repo-config.md`.

## Invocation

```text
/issue-unset-blocks <N> <blocked-N>
```

- `<N>` (required): the former blocker.
- `<blocked-N>` (required): the formerly blocked issue.

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
   `id` plus, on the blocker side, `url` and
   `blocking(first: 50) { nodes { id } }` (to detect a missing
   relationship for the idempotency check).

2. **Idempotency check.** If the blocked issue's resolved node ID is
   not among the blocker's `blocking.nodes` IDs, no-op: print one
   line (`Issue <N> does not block <B>; no change.`) and exit zero.
   Match on the node ID, never on `number`: either list can carry an
   issue from another repo.

3. **Remove the edge** via the `removeBlockedBy` template from
   `skills/lib/issue.md`, with the two roles **inverted** vs.
   `/issue-unset-blocked-by`: `<blocked-N>` is the **blocked** issue
   and `<N>` is the **blocker**. Supply each as its node ID.

4. **Issue not found**: if either node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue and abort.

## Output

```text
Removed blocking relationship: issue <N> no longer blocks <B>.
<url of the former blocker>
```

`<N>` and `<B>` print as `#<N>` for an issue in the current repo and
as `owner/repo#N` for an issue in another repo, per "Operand
resolution" in `skills/lib/issue.md`. The URL is the `url` the
former blocker's lookup returned.
