---
name: pr-diff
description: Fetch the full unified diff of a GitHub pull request, verbatim.
---

# PR Diff

Fetch the full unified diff of a GitHub pull request. This is the
diff-fetch that PR consumers run before
reading a PR's changes: the agents `sdlc:theorem-based-pr-reviewer`
spawns — every `theorem-generator` variant, `theorem-disprover`, and
`counterexample-verifier` —
and `/sdlc:orchestrate`'s own `issue-fixer`, `code-documenter`,
`style-checker`, and `docs-writer`. Each
declares this skill in its `skills:` frontmatter rather than writing
out a raw `gh pr diff` of its own.

This skill is **GitHub-only by design**. Its script is a thin wrapper
around `gh`'s own diff; there is no CodeCommit (or other source-control) branch,
and none is planned here — CodeCommit is deliberately out of scope for
this plugin.

## Invocation

```text
/pr-diff <PR>
```

- `<PR>` (required): the pull request, in any form
  `skills/lib/pr-reference.md` lists.

## Repo-config

This skill reads no repo-config. The PR is all the diff needs. (The
`source-control` value that a caller would previously have read to
choose between `gh` and CodeCommit is not consulted — this plugin is
GitHub-only, so there is nothing to branch on.)

## Execution

Run the bundled script, spelled as a bare name:

```bash
pr-diff <PR>
```

## Output and exit status

- **Exit 0** — stdout is the diff. Emit it verbatim for the caller to
  read. Do not summarize or truncate it — the caller decides what to
  do with the full diff.
- **Exit 2** — a usage error; nothing was read.
- **Exit 3** — the `gh` call failed (e.g. the PR does not exist), and
  gh's own error is on stderr above the script's line. Surface it
  verbatim rather than inventing a replacement message.
