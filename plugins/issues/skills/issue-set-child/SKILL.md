---
name: issue-set-child
description: Link a parent issue to a child (sub-issue edge) by adding the child as a sub-issue of the parent. Sugar for /issue-set-parent with inverted argument order.
---

Add a child issue as a sub-issue of a parent issue. This is the
"parent side" of the same sub-issue edge that `/issue-set-parent`
exposes — both verbs call `addSubIssue(issueId: P, subIssueId: C)`,
they only differ in argument order.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, the "One edge, two sides" pattern, and error wording. This
file documents only what is specific to `/issue-set-child`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-set-child <parent-N> <child-N>
```

- `<parent-N>` (required): issue number of the parent.
- `<child-N>` (required): issue number of the child to add as a
  sub-issue.

Mnemonic: argument order matches the verb — "set child of P to C"
reads left-to-right. Same edge as `set-parent C P`.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Look up node IDs for both issues** using the node-ID lookup
   template from `skills/lib/issue.md`, trimmed to `id` plus
   `parent { id number title }` on the child side (to detect an
   existing different-parent conflict).

2. **Idempotency check.** If the child's existing `parent.number`
   already equals `<parent-N>`, no-op: print one line (`Issue #<C>
   is already a sub-issue of #<P>; no change.`) and exit zero.

3. **Single-parent conflict check.** If the child already has a
   parent and that parent is **not** `<parent-N>`, abort with:

   > issue `#<C>` already has parent `#<existing-P>`; remove it first
   > with `/issue-unset-parent <C>` before setting a new parent

4. **Create the edge** via the `addSubIssue` template from
   `skills/lib/issue.md`. Pass:
   - `issueId = <parent node id>`
   - `subIssueId = <child node id>`

5. **Issue not found**: if either node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue and abort, identifying which issue was missing.

## Output

Print one confirmation line and the parent's URL:

```text
Linked issue #<C> as a sub-issue of #<P>.
https://github.com/<owner>/<repo>/issues/<P>
```
