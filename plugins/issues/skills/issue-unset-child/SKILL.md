---
name: issue-unset-child
description: Remove one specific sub-issue from a parent (sub-issue edge), addressed from the parent side.
---

Remove a specific child from a parent's sub-issue list. Takes both
issue numbers so the parent's other sub-issues are untouched.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, the "One edge, two sides" pattern, and error wording. This
file documents only what is specific to `/issue-unset-child`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-unset-child <parent-N> <child-N>
```

- `<parent-N>` (required): issue number of the parent.
- `<child-N>` (required): issue number of the specific child to
  remove. Required because a parent may have many children;
  `unset-child P` with no child argument would be ambiguous.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Look up the child's node ID and current parent** using the
   node-ID lookup template from `skills/lib/issue.md`, trimmed to
   `id` and `parent { id number title }`. (The parent's node ID is
   read off the child's `parent` field; this saves the extra lookup
   that `gh issue view <parent-N>` would otherwise require.)

2. **Idempotency check.** If the child's `parent` is `null`, or if
   `parent.number` is **not** `<parent-N>`, no-op: print one line
   (`Issue #<C> is not a sub-issue of #<P>; no change.`) and exit
   zero. Do not call the mutation. Mismatch here is treated as a
   no-op (not an error) because the requested end state — "child is
   not under that parent" — already holds.

3. **Remove the edge** via the `removeSubIssue` template from
   `skills/lib/issue.md`. Pass:
   - `issueId = <parent.id from step 1>`
   - `subIssueId = <child node id from step 1>`

4. **Issue not found**: if the node-ID lookup returns
   `repository.issue: null` for the child, emit the "Issue not
   found" error from the catalogue and abort.

## Output

Print one confirmation line and the parent's URL:

```text
Removed issue #<C> as a sub-issue of #<P>.
https://github.com/<owner>/<repo>/issues/<P>
```
