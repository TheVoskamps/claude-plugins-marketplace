---
name: pr-view
description: Print a GitHub pull request — a fixed dump of it by default, its canonical host/owner/repo#N reference with `--ref`, or the fields a caller names with `--json`, optionally filtered with `--jq`. Read-only.
---

# PR View

Read one pull request. With no flags you get a fixed dump a human can
read; with `--ref` you get the PR's canonical reference, the form to
carry the PR onward in; with `--json <fields>` you get exactly the
fields you named, as `gh pr view --json` spells them, for a caller that
needs specific data — the body, the reviews, the comments, the state,
the head and base refs, `createdAt`.

This skill is **GitHub-only by design**; there is no CodeCommit (or
other source-control) branch.

## Invocation

```text
/pr-view <PR> [--ref | --json <fields> [--jq <expression>]]
```

- `<PR>` (required): the pull request, in any form
  `skills/lib/pr-reference.md` lists.
- `--ref` (optional, never with `--json`): print the PR's canonical
  reference alone, as `skills/lib/pr-reference.md` defines it.
- `--json <fields>` (optional): a comma-separated field list, passed
  through unchanged.
- `--jq <expression>` (optional, only with `--json`): a jq expression
  over those fields, passed through unchanged. A string result prints
  raw, without quotes.

## Execution

Run the bundled script, spelled as a bare name, with the arguments you
were given:

```bash
pr-view <PR> [--ref | --json <fields> [--jq <expression>]]
```

When your caller asked for the output in a file, redirect the script's
stdout to that path; the script writes nothing else there.

## Output and exit status

- **Exit 0** — stdout is the PR. The default dump is the canonical
  reference, title, state and draft flag on one line, then the URL, the
  author, the head and base branches, a blank line, and the body
  verbatim. With `--ref`, stdout is the canonical reference alone,
  `<host>/<owner>/<repo>#<N>`. With `--json`, stdout is gh's JSON for
  those fields, or the `--jq` result.
  Hand it to your caller unchanged.
- **Exit 2** — a usage error; the script called nothing. Its stderr
  names the argument at fault.
- **Exit 3** — a command the script ran failed, such as the `gh` call,
  and its own error is on stderr above the script's line. Surface it
  verbatim rather than inventing a replacement message.
