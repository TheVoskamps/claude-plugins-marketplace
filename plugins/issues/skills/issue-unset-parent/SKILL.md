---
name: issue-unset-parent
description: Remove a child issue from its current parent (sub-issue edge), looked up from the child side.
---

Remove a child issue from its current parent in the sub-issue
hierarchy. Takes only the child's issue number; the parent is
determined by lookup so the user doesn't have to remember it.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, the "One edge, two sides" pattern, and error wording. This
file documents only what is specific to `/issue-unset-parent`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-unset-parent <child-N>
```

- `<child-N>` (required): issue number of the child whose parent
  link should be removed, with or without a leading `#`.

There is no second argument: an issue has at most one parent, so the
operation is unambiguous given the child.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Look up the child's node ID and current parent** using the
   node-ID lookup template from `skills/lib/issue.md`, trimmed to:

   ```graphql
   query($owner: String!, $repo: String!, $number: Int!) {
     repository(owner: $owner, name: $repo) {
       issue(number: $number) {
         id
         parent { id number title }
       }
     }
   }
   ```

   The `parent.id` field is what makes this a single round-trip — the
   `removeSubIssue` mutation needs the parent's node ID, and reading
   it here avoids a second lookup. (The lib's catch-all template has
   been widened to include `parent.id` for exactly this reason.)

2. **Idempotency check.** If `parent` is `null`, no-op: print one line
   (`Issue #<C> has no parent; no change.`) and exit zero. Do not
   call the mutation.

3. **Remove the edge** via the `removeSubIssue` template from
   `skills/lib/issue.md`. Pass:
   - `issueId = <parent.id from step 1>`
   - `subIssueId = <child node id from step 1>`

4. **Issue not found**: if the node-ID lookup returns
   `repository.issue: null` for the child, emit the "Issue not
   found" error from the catalogue and abort.

## Output

Print one confirmation line referencing the former parent (captured
in step 1) and the child's URL:

```text
Removed issue #<C> as a sub-issue of #<former-P>.
https://github.com/<owner>/<repo>/issues/<C>
```
