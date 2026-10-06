---
name: issue-comment
description: Add a comment to an issue by its reference, in this repo or another, with the body read from a file. Dispatches by repo's `issues:` tracker.
---

Post a single comment to one issue, identified by its reference. The
comment body is read from a file the caller provides — never composed
inline by this skill.

## Invocation

```text
/issue-comment <issue> --body-file PATH
```

- `<issue>` — required. The issue: `N` or `#N` in the current repo, or
  `repo#N`, `owner/repo#N`, `host/owner/repo#N` or
  `https://host/owner/repo/issues/N` in another, as
  `skills/lib/issue.md` → "Repositories and issue references" resolves
  them.
- `--body-file PATH` — required. A file whose contents are posted
  verbatim as the comment body; a relative path resolves against the
  current directory, then the repo root. Markdown passes through
  unchanged.

If either is missing, ask the user for it and stop — never search for
"the right issue" by title, and never compose a body from context.
When the caller wants to comment a short string, write it to a file
under `.claude/tmp/` first and pass that path, so the exact posted text
is reviewable.

## Execution

Run the `issue-comment` script, which this plugin puts on `PATH`, with
the Bash tool from inside the repo's working tree:

```bash
issue-comment <issue> --body-file <PATH>
```

The script refuses a body file that is missing, unreadable, or empty
or whitespace-only, and posts nothing in that case. After posting it
re-reads the new comment and exits non-zero unless the comment exists
on this issue. Print its stdout as it stands. On a non-zero exit, relay
its stderr verbatim and stop.

## Output

```text
Commented on issue #<N> "<title>".
<comment URL>
```

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Comment" instead, with the
same body-file rules.

## Hard constraints

- **Never comment on an issue you weren't given.** The `<issue>`
  operand is the only input that identifies the target.
- **Never compose the body inline.** The body always comes from
  `--body-file`.
- **Never close the issue from this skill.** Closing is
  `/issue-close`'s job; for comment-then-close, invoke
  `/issue-close <issue> --comment "..."` instead.
