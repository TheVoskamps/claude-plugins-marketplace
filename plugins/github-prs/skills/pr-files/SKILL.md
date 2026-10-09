---
name: pr-files
description: List every file a GitHub pull request changes — change type, additions, deletions and path, one line per file — paging past the 100 files `pr-view --json files` stops at. Read-only.
---

# PR Files

List the files a pull request changes, every one of them. The `files`
field `/pr-view <PR> --json files` can ask for stops at the first 100,
so a caller that needs the whole list — a review that decides which of
a PR's paths it grades — calls this instead.

This skill is **GitHub-only by design**; there is no CodeCommit (or
other source-control) branch.

## Invocation

```text
/pr-files <PR>
```

- `<PR>` (required): the pull request, in any form
  `skills/lib/pr-reference.md` lists.

## Execution

Run the bundled script, spelled as a bare name:

```bash
pr-files <PR>
```

## Output and exit status

- **Exit 0** — stdout is one line per changed file, in the order GitHub
  lists them:

  ```text
  <changeType>\t<additions>\t<deletions>\t<path>
  ```

  `\t` is a tab. `<changeType>` is GitHub's word for the change —
  `ADDED`, `DELETED`, `RENAMED`, `COPIED`, `MODIFIED` or `CHANGED`.
  A PR that changes nothing prints nothing. Hand the lines to your
  caller unchanged.
- **Exit 1** — a command the script ran failed, such as the `gh` call
  for a PR that does not exist, and that command's own error is on
  stderr above the script's line. Surface it verbatim rather than
  inventing a replacement message.
- **Exit 2** — a usage error; the script called nothing. Its stderr
  names the argument at fault.
