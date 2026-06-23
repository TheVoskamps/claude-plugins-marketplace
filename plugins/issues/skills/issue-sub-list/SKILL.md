---
name: issue-sub-list
description: List all direct sub-issues of a parent issue, paginated.
---

List the direct sub-issues (one level down only — no recursion) of a
given parent. Pagination is driven by GraphQL cursor so parents with
more than 50 children are fully enumerated; `/issue-view-tree` is the
right tool for recursive walks.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, and error wording. This file documents only what is
specific to `/issue-sub-list`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-sub-list <parent-N>
```

- `<parent-N>` (required): issue number of the parent whose sub-issues
  should be listed.

No flags. Output is direct children only; nested descendants are out
of scope (use `/issue-view-tree` for that).

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Page through sub-issues** using the "Sub-issues paginated lookup"
   template from `skills/lib/issue.md`. The loop:

   - First call: pass `$after: null` (omit the variable).
   - Record the parent's `title` from the first response (constant
     across pages; used in the output header below).
   - Record `subIssues.nodes` into an accumulator.
   - While `subIssues.pageInfo.hasNextPage` is `true`, re-run the
     query with `$after: <pageInfo.endCursor>` and append the new
     `nodes` to the accumulator.
   - Stop when `hasNextPage` is `false`.

   Use the paginated template (not the catch-all node-ID lookup) so
   parents with >50 sub-issues are listed correctly.

2. **Issue not found**: if the first page returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue and abort.

## Output

Print a header line naming the parent (number and title), then one
bullet line per direct sub-issue in the order GitHub returns them.
If there are no sub-issues, print `(none)` instead of the bullet
list.

```text
Sub-issues of #<parent-N> "<title>":
  - #<N> <title>
  - #<N> <title>
  - ...
```

When the parent has no sub-issues:

```text
Sub-issues of #<parent-N> "<title>":
  (none)
```

Do not re-sort. Do not print URLs (the parent number is enough for
the user to navigate; per-child URLs add noise on long lists).
