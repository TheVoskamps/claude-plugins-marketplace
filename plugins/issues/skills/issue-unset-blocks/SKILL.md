---
name: issue-unset-blocks
description: Remove a blocking relationship between two issues (blocker's side). Idempotent.
---

Remove a blocking relationship: "issue N no longer blocks issue B".
This is the blocker's-side view of the same edge that
`/issue-unset-blocked-by` exposes — both verbs call `removeBlockedBy`
with swapped arguments.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, the "One edge, two sides" pattern, and error wording. This
file documents only what is specific to `/issue-unset-blocks`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-unset-blocks <N> <blocked-N>
```

- `<N>` (required): issue number of the former blocker.
- `<blocked-N>` (required): issue number of the formerly blocked
  issue.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Look up node IDs for both issues** using the node-ID lookup
   template from `skills/lib/issue.md`, trimmed to `id` plus
   `blocking(first: 50) { nodes { number } }` on the blocker side
   (to detect a missing relationship for the idempotency check).

2. **Idempotency check.** If `<blocked-N>` is not in the blocker's
   `blocking.nodes`, no-op: print one line (`Issue #<N> does not
   block #<B>; no change.`) and exit zero.

3. **Remove the edge** via the `removeBlockedBy` template from
   `skills/lib/issue.md`. Note the **swapped arguments** vs.
   `/issue-unset-blocked-by`:
   - `issueId = <node id of <blocked-N>>` (the **blocked** issue).
   - `blockingIssueId = <node id of <N>>` (the **blocker**).

4. **Issue not found**: if either node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue and abort.

## Output

```text
Removed blocking relationship: issue #<N> no longer blocks #<B>.
https://github.com/<owner>/<repo>/issues/<N>
```
