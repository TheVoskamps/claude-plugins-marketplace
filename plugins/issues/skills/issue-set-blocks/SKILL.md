---
name: issue-set-blocks
description: Declare that one issue blocks another (blocked-by edge from the blocker's side). Sugar for /issue-set-blocked-by with inverted args.
---

Add a blocking relationship: "issue N blocks issue B". This is the
blocker's-side view of the same edge that `/issue-set-blocked-by`
exposes — both verbs call `addBlockedBy`, just with the arguments
swapped.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, the "One edge, two sides" pattern, and error wording. This
file documents only what is specific to `/issue-set-blocks`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-set-blocks <N> <blocked-N>
```

- `<N>` (required): issue number of the **blocker** (the
  prerequisite).
- `<blocked-N>` (required): issue number of the issue being
  **blocked** by N.

Mnemonic: "set blocks of N to B" — "N blocks B". Same edge as
`set-blocked-by B N`.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Look up node IDs for both issues** using the node-ID lookup
   template from `skills/lib/issue.md`, trimmed to `id` plus
   `blocking(first: 50) { nodes { number } }` on the blocker side
   (to detect an existing relationship for the idempotency check).
   If the blocker issue might already be blocking more than 50 other
   issues, the idempotency check may miss an existing edge and the
   mutation will then no-op on the server side; the mutation itself
   is safe to retry, so this is acceptable.

2. **Idempotency check.** If `<blocked-N>` is already in the
   blocker's `blocking.nodes`, no-op: print one line (`Issue #<N>
   already blocks #<B>; no change.`) and exit zero.

3. **Create the edge** via the `addBlockedBy` template from
   `skills/lib/issue.md`. Note the **swapped arguments** vs.
   `/issue-set-blocked-by`:
   - `issueId = <node id of <blocked-N>>` (the **blocked** issue is
     what `addBlockedBy.issueId` names; see the lib's call-site
     mapping).
   - `blockingIssueId = <node id of <N>>` (the **blocker** — i.e.
     the first CLI argument).

4. **Issue not found**: if either node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue and abort.

## Output

```text
Marked issue #<N> as blocking #<B>.
https://github.com/<owner>/<repo>/issues/<N>
```
