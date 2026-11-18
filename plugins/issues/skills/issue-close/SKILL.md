---
name: issue-close
description: Close an issue by its reference, in this repo or another; optionally post a summary comment first, and set the close reason — completed, not planned, or a duplicate of a named issue. Dispatches by repo's `issues:` tracker.
---

Close one issue, identified by its reference. Optionally post a summary
comment **before** closing it, and optionally name the reason it is
closed.

## Invocation

```text
/issue-close <issue> [--comment "summary"] [--reason completed | not-planned | duplicate-of <issue>]
```

- `<issue>` — required. An issue reference.
- `--comment "summary"` — optional. Posted verbatim as a new comment
  before the issue is closed.
- `--reason` — optional, its keyword matched case-insensitively:
  - `completed` closes the issue as completed.
  - `not-planned` closes it as not planned.
  - `duplicate-of <issue>` closes it as a duplicate of `<issue>`, an
    issue reference that need not share the closed issue's repo.

  With no `--reason`, the issue closes with GitHub's default reason.

The script refuses these before the comment is posted, so the issue is
left untouched:

- a `--reason` value other than those three, bare `duplicate` included;
- `--reason duplicate-of` with nothing after it, or with another flag
  after it;
- a `duplicate-of` reference that does not resolve to an issue, or
  that names the issue being closed.

If `<issue>` is missing, ask the user for it. Do not search for
"relevant issues" by title or by recent work — this skill closes
exactly the issue that was passed.

## Execution

Run the `issue-close` script, which this plugin puts on `PATH`, with
the Bash tool from inside the repo's working tree:

```bash
issue-close <issue> [--comment "<summary>"] [--reason <reason>]
```

The script posts the comment first and stops without closing when the
comment fails, so the summary trail is never missing from a closed
issue. After closing, it re-reads the issue's state and exits non-zero
unless it reads `CLOSED`. Print its stdout as it stands. On a non-zero
exit, relay its stderr verbatim and stop.

With `--reason`, an issue that is already closed is handled by what it
was closed as, since a close changes nothing on a closed issue:

- **Closed with the requested reason**, and for `duplicate-of` as a
  duplicate of the requested issue: the comment is posted if given,
  and nothing else changes.
- **Closed any other way**: the comment is posted if given, then the
  issue is reopened and closed with the requested reason.

With no `--reason`, an already-closed issue is closed as before, with
nothing reopened.

A requested reason is checked against the re-read too: the script
prints its report, then exits non-zero when the re-read reason is not
the one requested, or for `duplicate-of` when the re-read does not name
the requested issue as the one duplicated — a `DUPLICATE` with no
issue named included.

## Output

```text
Closed issue #<N> "<title>".
  comment: posted
  state:   CLOSED
  reason:  DUPLICATE of #<M>
https://github.com/<owner>/<repo>/issues/<N>
```

The `reason:` line is printed only when `--reason` was given, and reads
the re-read reason: `COMPLETED`, `NOT_PLANNED`, or `DUPLICATE of
<issue>`. When the issue was already closed with the requested reason,
the first line reads `Issue #<N> "<title>" is already closed with that
reason; no change.` instead.

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
exits non-zero with its fixed Jira message before it reads or writes an
issue; follow
`skills/lib/issue.md` → "Jira backend" → "Close" instead, with the
same comment-then-close order and the same closing-keyword note.

## Hard constraints

- **Never close an issue you weren't given.** The `<issue>` operand is
  the only input that identifies the target.
- **Never place a closing keyword before an issue reference in a
  comment you write.** A closing keyword immediately followed by an
  issue reference (`#N`, `owner/repo#N`, `GH-N`, or an issue URL)
  cascade-closes the referenced issue. The same keywords as ordinary
  prose with no adjacent reference are fine. A user-supplied
  `--comment` with that pattern passes through verbatim — that's their
  call.
