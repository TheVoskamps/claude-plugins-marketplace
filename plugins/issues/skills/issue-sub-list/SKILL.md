---
name: issue-sub-list
description: List all direct sub-issues of a parent issue, paginated.
---

List the direct sub-issues (one level down only — no recursion) of a
given parent. The script pages through GitHub's per-page limit, so a
parent with more children than one page is listed in full;
`/issue-view-tree` is the verb for recursive walks.

## Invocation

```text
/issue-sub-list <parent-N>
```

- `<parent-N>` (required): the parent: `N` or `#N` in the current repo,
  or `repo#N`, `owner/repo#N`, `host/owner/repo#N` or
  `https://host/owner/repo/issues/N` in another, as
  `skills/lib/issue.md` → "Repositories and issue references" resolves
  them.

## Execution

Run the `issue-sub-list` script, which this plugin puts on `PATH`,
with the Bash tool from inside the repo's working tree:

```bash
issue-sub-list <parent-N>
```

Print its stdout as it stands. On a non-zero exit, relay its stderr
verbatim and stop.

## Output

A header naming the parent, then one bullet per direct sub-issue in
the order GitHub returns them, or `(none)`:

```text
Sub-issues of #<parent-N> "<title>":
  - #<N> <title>
  - #<N> <title>
```

No URLs are printed. The parent and each sub-issue print as
`skills/lib/issue.md` → "Repositories and issue references" states.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Read / view" instead, which
lists every sub-task with a JQL search.
