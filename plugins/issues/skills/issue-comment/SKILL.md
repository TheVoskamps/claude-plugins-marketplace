---
name: issue-comment
description: Add a comment to an issue by its reference, in this repo or another, with the body read from a file; or, by a marker line, edit that issue's marker comment in place or read it back. Dispatches by repo's `issues:` tracker.
---

Post a single comment to one issue, identified by its reference. The
comment body is read from a file the caller provides — never composed
inline by this skill. Two marker forms keep one comment per issue
current instead of posting a new one each time.

## Invocation

```text
/issue-comment <issue> --body-file PATH
/issue-comment <issue> --body-file PATH --marker <header>
/issue-comment <issue> --read --marker <header>
```

- `<issue>` — required. An issue reference.
- `--body-file PATH` — a file whose contents are posted verbatim as the
  comment body; a relative path resolves against the current directory,
  then the repo root. Markdown passes through unchanged. Required in
  the first two forms, refused in the third.
- `--marker <header>` — one line, non-empty. The **marker comment** is
  the most recent comment on the issue whose first line, a trailing
  carriage return ignored, is `<header>`, whoever wrote it.
  - With `--body-file`, the file's first line must be `<header>`. The
    marker comment is edited to the file's text, or, when the issue has
    none, the file is posted as a new comment.
  - With `--read`, the marker comment's body is printed; with none,
    nothing is printed and the exit is 0.

If the issue or the body file is missing, ask the user for it and stop
— never search for "the right issue" by title, and never compose a body
from context. When the caller wants to comment a short string, write it
to a file under `.claude/tmp/` first and pass that path, so the exact
posted text is reviewable.

## Execution

Run the `issue-comment` script, which this plugin puts on `PATH`, with
the Bash tool from inside the repo's working tree, with the arguments
of the form you were given:

```bash
issue-comment <issue> --body-file <PATH> [--marker <header>]
issue-comment <issue> --read --marker <header>
```

The script refuses a body file that is missing, unreadable, or empty
or whitespace-only, and, with `--marker`, one whose first line is not
the header; it posts and edits nothing in those cases. After posting
it re-reads the new comment and exits non-zero unless the comment
exists on this issue; after an edit it re-reads the comment and exits
non-zero unless it carries the file's text, carriage returns and
trailing whitespace aside. Print its stdout as it
stands. On a non-zero exit, relay its stderr verbatim and stop.

## Output

A post prints:

```text
Commented on issue #<N> "<title>".
<comment URL>
```

An edit prints:

```text
Updated the comment on issue #<N> "<title>".
<comment URL>
```

`--read` prints the marker comment's body and nothing else.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before it reads or writes an
issue; follow
`skills/lib/issue.md` → "Jira backend" → "Comment" instead, with the
same body-file rules. The two marker forms have no Jira path: given one
under `issues: Jira`, relay the script's Jira message and stop.

## Hard constraints

- **Never comment on an issue you weren't given.** The `<issue>`
  operand is the only input that identifies the target.
- **Never compose the body inline.** The body always comes from
  `--body-file`.
- **Never close the issue from this skill.** Closing is
  `/issue-close`'s job; for comment-then-close, invoke
  `/issue-close <issue> --comment "..."` instead.
