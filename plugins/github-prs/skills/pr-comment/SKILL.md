---
name: pr-comment
description: Post a comment on a GitHub pull request from a file, then verify the comment GitHub holds carries that file's text.
---

# PR Comment

Post one comment on a pull request, its text read from a file. The
text arrives by path rather than inline, so a comment that quotes code,
check names or hunks reaches GitHub as written instead of being read by
the shell.

This skill is **GitHub-only by design**; there is no CodeCommit (or
other source-control) branch.

## Invocation

```text
/pr-comment <PR> --body-file <path>
```

- `<PR>` (required): the pull request, in any form
  `skills/lib/pr-reference.md` lists.
- `--body-file <path>` (required): a file holding the comment's text.

## Execution

Run the bundled script, spelled as a bare name:

```bash
pr-comment <PR> --body-file <path>
```

The script posts the comment, then re-reads that one comment by the id
GitHub gave it and compares its text with the file, trailing newlines
aside.

## Output and exit status

- **Exit 0** — the comment is on the PR with the file's text. Stdout is
  the comment's URL; report it back.
- **Exit 1** — the comment did not land as written: GitHub named no
  comment, or the comment it named carries different text. Stderr says
  which. Report the failure rather than posting again, since a second
  post would leave two comments if the first did land.
- **Exit 2** — a usage error, such as a path that is not a readable
  file; nothing was posted.
- **Exit 3** — the `gh` call failed, and gh's own error is on stderr
  above the script's line. Surface it verbatim.
