---
name: issue-close
description: Close an issue by number; optionally post a summary comment first. Dispatches by repo's `issues:` tracker.
---

Close one issue, identified by its number. Optionally post a summary
comment **before** closing it.

## Invocation

```text
/issue-close <issue-number> [--comment "summary"]
```

- `<issue-number>` — required. The issue number, with or without a
  leading `#`.
- `--comment "summary"` — optional. Posted verbatim as a new comment
  before the issue is closed.

If `<issue-number>` is missing, ask the user for it. Do not search for
"relevant issues" by title or by recent work — this skill closes
exactly the issue whose number was passed.

## Execution

Run the `issue-close` script, which this plugin puts on `PATH`, with
the Bash tool from inside the repo's working tree:

```bash
issue-close <N> [--comment "<summary>"]
```

The script posts the comment first and stops without closing when the
comment fails, so the summary trail is never missing from a closed
issue. After closing, it re-reads the issue's state and exits non-zero
unless it reads `CLOSED`. Print its stdout as it stands. On a non-zero
exit, relay its stderr verbatim and stop.

## Output

```text
Closed issue #<N> "<title>".
  comment: posted
  state:   CLOSED
https://github.com/<owner>/<repo>/issues/<N>
```

`comment:` reads `not posted` when no `--comment` was given. When the
comment carries a closing keyword (`close`, `closes`, `closed`, `fix`,
`fixes`, `fixed`, `resolve`, `resolves`, `resolved`, any case) followed
by `#<N>`, the script appends a note naming each such issue, because
that pattern auto-closes it:

```text
note: your comment contained closing keyword(s) referencing #X, which will auto-close that/those issue(s).
```

The note does not block the close — the comment is the caller's, and
passes through verbatim either way.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Close" instead, with the
same comment-then-close order and the same closing-keyword note.

## Hard constraints

- **Never close an issue you weren't given by number.** The number is
  the only input that identifies the target.
- **Never place a closing keyword before an issue reference in a
  comment you write.** A closing keyword immediately followed by an
  issue reference (`#N`, `owner/repo#N`, `GH-N`, or an issue URL)
  cascade-closes the referenced issue. The same keywords as ordinary
  prose with no adjacent reference are fine. A user-supplied
  `--comment` with that pattern passes through verbatim — that's their
  call.
