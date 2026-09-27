---
name: issue-view-tree
description: Walk an issue tree downward via sub-issues, listing blockedBy/blocking inline at each node, depth-capped at 5.
---

Print an issue and its descendants, recursing **downward only** through
sub-issues. Each node lists its blocked-by and blocking issues inline,
without recursing into them. Depth is capped at 5 to keep output
bounded.

## Invocation

```text
/issue-view-tree <issue-number>
```

A single positional argument: the root issue number, with or without
a leading `#`. No flags.

## Execution

Run the `issue-view-tree` script, which this plugin puts on `PATH`,
with the Bash tool from inside the repo's working tree:

```bash
issue-view-tree <N>
```

Print its stdout as it stands. On a non-zero exit, relay its stderr
verbatim and stop.

## Output

Each level indents two spaces; the root is unindented. A node prints
one summary line, then its relationship sections one level deeper,
then its children:

```text
#<root-N> <title>  <url>
  Blocked by:
    - #<N> <title>
  Blocking: (none)
  #<child-N> <title>  <url>
    Blocked by: (none)
    Blocking: (none)
```

- An empty relationship section prints `Blocked by: (none)` /
  `Blocking: (none)` on one line; it is never omitted.
- The root is depth 0. A node at depth 5 that still has sub-issues
  prints `... (depth cap)` at the indent its children would have used,
  and its branch stops there. The depth cap is also what bounds a
  cycle, since GitHub does not prevent one.
- A descendant that no longer resolves prints `#<N> (not found)` and
  its subtree is skipped; a root that does not resolve is an error.
- A related issue in another repo prints as `owner/repo#N`.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Read / view" instead, and
render the same shape.
