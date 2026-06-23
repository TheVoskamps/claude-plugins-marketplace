---
name: issue-view-tree
description: Walk an issue tree downward via sub-issues, listing blockedBy/blocking inline at each node, depth-capped at 5.
---

Print an issue and its descendants, recursing **downward only** via
`subIssues`. At each node, list the node's `blockedBy` and `blocking`
inline as plain lines (do not recurse into them). Depth is capped at
5 to keep output bounded and avoid runaway traversal on pathological
trees.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, and error wording. This file documents only what is
specific to `/issue-view-tree`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-view-tree <issue-number>
```

A single positional argument: the root issue number. No flags.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

For each node visited (starting at the root):

1. Run the node-ID lookup template from `skills/lib/issue.md`,
   trimmed to:

   ```graphql
   query($owner: String!, $repo: String!, $number: Int!) {
     repository(owner: $owner, name: $repo) {
       issue(number: $number) {
         id title url
         subIssues(first: 50) { nodes { number title url } }
         blockedBy(first: 50) { nodes { number title url } }
         blocking(first: 50)  { nodes { number title url } }
       }
     }
   }
   ```

   That subset is the minimum needed to render the tree. Do not pull
   project fields or `issueDependenciesSummary` — the walker doesn't
   render them.

2. Print one line for the issue itself (see "Output" below).

3. Print zero or more `Blocked by` and `Blocking` lines for the
   current node, one per related issue. These are **inline only** —
   never recurse into a `blockedBy` or `blocking` node.

4. Recurse into each entry of `subIssues.nodes`, in returned order,
   with depth incremented by 1.

## Depth cap

The root is depth 0. At depth 5, if the current node still has
sub-issues, do not recurse further. Instead, print a single
`... (depth cap)` line at the next indentation level and stop the
descent for that branch. Continue with the next sibling at a shallower
level.

If `repository.issue` is null for the root, emit the "Issue not
found" error and abort. If `repository.issue` is null for a
descendant (e.g. a referenced sub-issue was deleted), print
`#<N> (not found)` at that node's indent and skip its subtree.

## Cycle handling

GitHub's sub-issue feature does not enforce acyclicity (an issue can
theoretically appear under two different parents, and cycles are not
prevented by the API). To stay bounded, the depth cap alone is
sufficient — do not maintain a visited set. A cycle will print up to
depth 5 and then stop.

## Output

Indent each level by two spaces. The root is unindented. Each node
prints a single-line summary; relationship lines for that node print
one indent deeper than the node line, each prefixed with a `-`
bullet (so they look like a sub-bullet of the node).

```text
#<root-N> <title>  <url>
  Blocked by: (none, or repeated lines below)
    - #<N> <title>
  Blocking:
    - #<N> <title>
    - #<N> <title>
  #<child-N> <title>  <url>
    Blocked by: (none)
    Blocking: (none)
    #<grandchild-N> <title>  <url>
      ...
```

When a relationship list is empty, print `Blocked by: (none)` /
`Blocking: (none)` on one line (do not omit the section — predictable
shape matters for grep-ability). When non-empty, print the section
header followed by indented `- #<N> <title>` lines.

When the depth cap fires, the placeholder line uses the same indent
the next child would have used:

```text
  #<cap-node> <title>  <url>
    Blocked by: (none)
    Blocking: (none)
      ... (depth cap)
```
