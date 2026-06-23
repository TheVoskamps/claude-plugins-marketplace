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
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-unset-blocked-by <N> <blocker-N>
```

- `<N>` (required): issue number of the formerly blocked issue.
- `<blocker-N>` (required): issue number of the blocker to detach.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Look up node IDs for both issues** using the node-ID lookup
   template from `skills/lib/issue.md`, trimmed to `id` plus
   `blockedBy(first: 50) { nodes { number } }` on the blocked side
   (to detect a missing relationship for the idempotency check).

2. **Idempotency check.** If `<blocker-N>` is not in the blocked
   issue's `blockedBy.nodes`, no-op: print one line (`Issue #<N> is
   not blocked by #<B>; no change.`) and exit zero.

3. **Remove the edge** via the `removeBlockedBy` template from
   `skills/lib/issue.md`. Pass:
   - `issueId = <node id of N>`
   - `blockingIssueId = <node id of B>`

4. **Issue not found**: if either node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue and abort.

## Output

```text
Removed blocked-by relationship: issue #<N> is no longer blocked by #<B>.
https://github.com/<owner>/<repo>/issues/<N>
```
