---
name: pr-update
description: Replace a GitHub pull request's body with the contents of a file, then verify the body GitHub holds is that file.
---

# PR Update

Replace a pull request's body — the whole body — with the contents of
a file. The body arrives by path rather than inline, so a body full of
backticks and `$` reaches GitHub as written instead of being read by
the shell.

Which callers may edit a body at all, and when, is theirs to rule on,
not this skill's.

This skill is **GitHub-only by design**; there is no CodeCommit (or
other source-control) branch.

## Invocation

```text
/pr-update <pr-number> --body-file <path>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.
- `--body-file <path>` (required): a file holding the complete new
  body.

## Execution

Run the bundled script, spelled as a bare name:

```bash
pr-update <pr-number> --body-file <path>
```

The script writes the body, then re-reads it from GitHub and compares
it with the file, trailing newlines aside.

## Output and exit status

- **Exit 0** — the body GitHub holds is the file. Stdout is one line
  naming the PR and the file; report it back.
- **Exit 1** — the edit did not land: the re-read body differs from
  the file. Stderr says so. Report the failure; do not retry on top of
  a body you have not read back.
- **Exit 2** — a usage error, such as a path that is not a readable
  file; nothing was sent to GitHub.
- **Exit 3** — the `gh` call failed, and gh's own error is on stderr
  above the script's line. Surface it verbatim.
