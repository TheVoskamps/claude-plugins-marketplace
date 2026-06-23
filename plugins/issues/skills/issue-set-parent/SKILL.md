---
name: issue-set-parent
description: Link a child issue to a parent (sub-issue edge) by adding the child as a sub-issue of the parent.
---

Add a child issue as a sub-issue of a parent issue. This is the
"child side" of the sub-issue edge — `/issue-set-child` is the same
edge with inverted argument order.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, the "One edge, two sides" pattern, and error wording. This
file documents only what is specific to `/issue-set-parent`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-set-parent <child-N> <parent-N>
```

- `<child-N>` (required): issue number of the child (the issue
  becoming a sub-issue), with or without a leading `#`.
- `<parent-N>` (required): issue number of the parent (the
  containing issue).

Mnemonic: argument order matches the verb — "set parent of C to P"
reads left-to-right.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Look up node IDs for both issues** using the node-ID lookup
   template from `skills/lib/issue.md`, trimmed to `id` plus
   `parent { id number title }` on the child side (to detect an
   existing same-parent or different-parent state in one round-trip).
   The parent lookup needs only `id` — the idempotency check in step
   2 reads the child's `parent.number`, not the parent's sub-issues
   list.

2. **Idempotency check.** If the child's existing `parent.number`
   already equals `<parent-N>`, no-op: print one line (`Issue #<C>
   is already a sub-issue of #<P>; no change.`) and exit zero. Do
   not call the mutation.

3. **Single-parent conflict check.** An issue can only have one
   parent in GitHub's sub-issue model. If the child already has a
   parent and that parent is **not** `<parent-N>`, abort with:

   > issue `#<C>` already has parent `#<existing-P>`; remove it first
   > with `/issue-unset-parent <C>` before setting a new parent

   Use the existing parent's number from the lookup in step 1.

4. **Create the edge** via the `addSubIssue` template from
   `skills/lib/issue.md`. Pass:
   - `issueId = <parent node id>` (the parent — `addSubIssue.issueId`
     names the **parent** by GitHub's API convention; see the lib).
   - `subIssueId = <child node id>`.

5. **Issue not found**: if either node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue and abort. Identify which issue was missing so the
   user can correct the typo.

## Output

Print one confirmation line and the parent's URL:

```text
Linked issue #<C> as a sub-issue of #<P>.
https://github.com/<owner>/<repo>/issues/<P>
```
