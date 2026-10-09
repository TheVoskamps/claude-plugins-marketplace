---
name: pr-closing-issues
description: Report the set of issues a GitHub pull request's body closes, by relaying the line the bundled script prints. The parse is gp_closing_issues, shared by the pr-closing-issues and pr-link-issue scripts; every skill and agent outside github-prs reads a body's closing set by invoking this skill.
---

# PR Closing Issues

Answer one question: **which issues does this PR close?** The bundled
script fetches the pull request's body, recognizes every issue a
closing keyword in it is aimed at, and prints the set.

The parse is `gp_closing_issues`, in this plugin's
`bin/lib/github-prs-common.sh`, which the `pr-closing-issues` and
`pr-link-issue` scripts share. Every skill and agent outside
`github-prs` that acts on which issues a body closes — for a
standalone review's claim, a status flip, or a before-and-after
comparison around a body edit — reads that set by invoking
`/github-prs:pr-closing-issues` rather than scanning the body itself.
Skill invocation crosses the plugin sandbox boundary that a `Read`
cannot, since an enabled plugin's skills are invocable from anywhere
by their namespaced name while file access stays sandboxed per plugin.
Each consumer keeps its own action on the result; none re-derives the
result itself.

This skill is **GitHub-only by design**. Its script reads the body
through `gh` and recognizes GitHub's closing-keyword syntax; there is
no CodeCommit (or other source-control) branch, and none is planned
here.

## Invocation

```text
/pr-closing-issues <PR>
```

- `<PR>` (required): the pull request, in any form
  `skills/lib/pr-reference.md` lists.

A single-PR primitive. A caller holding several PRs invokes it
once per PR.

## Repo-config

This skill reads no repo-config. The body needs only the PR, and the
closing-keyword syntax is GitHub's rather than anything the repo
configures.

## Execution

1. Run the bundled script, spelled as a bare name:

   ```bash
   pr-closing-issues <PR>
   ```

   On exit 0 its stdout is the one-line report "Output" shows. Exit 2
   is a usage error. Exit 1 means a command the script ran failed, such
   as the `gh` call for a PR that does not exist, with its own error on
   stderr above the script's line: surface it verbatim rather than
   inventing a replacement message, and stop.

2. Relay the script's line as it stands, and nothing else: this skill
   applies no syntax of its own and makes no decision about whether the
   set is the right one. A caller that needs the set checked against
   the branch's own issue set gets that from
   `/git-tools:git-issues-from-branch`, which owns the reconciliation
   rule.

## Output

One line, naming the PR and the set in ascending numeric order:

```text
PR #224 closes issues 196, 201, 206
```

A body with no closing line at all is a normal outcome, not an error:

```text
PR #224 closes no issues
```
