---
name: pr-list
description: List the GitHub pull requests whose head is a given branch, optionally filtered by state, as a JSON array. Read-only.
---

# PR List

List the pull requests opened from one head branch. The match is by
branch **name**, not by commit: a branch deleted and later recreated
under the same name matches the PRs of both.

This skill is **GitHub-only by design**; there is no CodeCommit (or
other source-control) branch.

## Invocation

```text
/pr-list --head <branch> [--state <state>]
```

- `--head <branch>` (required): the head branch name.
- `--state <state>` (optional): `open` (the default), `closed`,
  `merged`, or `all`.

## Execution

Run the bundled script, spelled as a bare name:

```bash
pr-list --head <branch> [--state <state>]
```

## Output and exit status

- **Exit 0** — stdout is a JSON array with one object per matching PR,
  each carrying `number`, `title`, `state`, `headRefName`,
  `baseRefName`, `mergedAt`, `closedAt` and `url`. An empty array, `[]`,
  means no PR matched, which is a normal outcome rather than an error.
- **Exit 2** — a usage error, such as a missing `--head` or an unknown
  state; nothing was read.
- **Exit 3** — the `gh` call failed, and gh's own error is on stderr
  above the script's line. Surface it verbatim.
