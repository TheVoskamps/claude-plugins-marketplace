---
name: issue-comment
description: Add a comment to an issue by number, with the body read from a file. Dispatches by repo's `issues:` tracker.
---

Post a single comment to one issue, identified by its number. The
comment body is read from a file path the caller provides — never
composed inline by this skill.

See `skills/lib/issue.md` for shared repo-config parsing, tracker
dispatch, and error wording. This file documents only what is specific
to `/issue-comment`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-comment <issue-number> --body-file PATH
```

- `<issue-number>` — required. The issue number, with or without the
  repo's `issue-link-prefix` (`#42` and `42` are both accepted).
- `--body-file PATH` — required. Filesystem path (absolute or relative
  to the repo root) to a file whose contents are posted verbatim as
  the comment body. Markdown is supported; the file is passed through
  unchanged.

Both arguments are required. If either is missing, prompt the user
for it and stop — do **not** search for "the right issue" by title or
fall back to composing a body from context. The skill no longer
guesses targets.

If the file at `PATH` does not exist, is empty or whitespace-only, or
is unreadable, abort with a clear error and stop. Do not post an
empty comment. "Whitespace-only" means the file's contents match
`\s*` — including a single trailing newline, a few spaces, or any
combination of spaces/tabs/newlines — so a template that was prepared
but never filled in is treated the same as a byte-empty file.

## Repo-config and tracker dispatch

Open with the standard repo-config read and `issues:` switch from
`skills/lib/issue.md` ("Repo-config parsing" and "Tracker dispatch").
This skill does **not** read the optional `github-project:` block —
commenting is a pure-issue operation and degrades fine without
project metadata.

## GitHub path (`issues: GitHub`)

Strip a leading `issue-link-prefix` (`#` for GitHub) from
`<issue-number>` before invoking `gh`. Use the normalized integer in
both the `gh` calls below and the report-back. `gh issue comment #42`
is not a valid invocation; `gh issue comment 42` is.

1. Fetch the issue title for the report-back:

   ```bash
   gh issue view <N> --json number,title,url --jq '.title'
   ```

   `gh issue comment` returns the new comment's URL but not the issue
   title, so this lookup happens up front. Cache the result for use
   in the report-back. Surface any non-zero exit verbatim and stop —
   if `gh issue view` fails, the issue likely doesn't exist or isn't
   accessible, and the comment should not be posted.

2. Post the comment:

   ```bash
   gh issue comment <N> --body-file <PATH>
   ```

   `gh` returns the new comment's URL on success; surface it in the
   report back along with the issue number and the title fetched in
   step 1. Surface any non-zero exit verbatim.

## Jira path (`issues: Jira`)

Follow the Jira backend "Comment" path in `skills/lib/issue.md` → "Jira
backend" → "Comment". Concretely:

1. Normalize `<issue-number>` to a Jira key (`SET-42`; both `42` and
   `SET-42` are accepted) per the Jira-backend "Preconditions". Confirm
   `acli` is present and authenticated first.
2. Fetch the work item's summary (title) for the report-back via the
   `workitem view` template from the `/issues-jira:jira-lib` skill. Surface any
   non-zero exit verbatim and stop — if the item can't be read, do not
   post.
3. Validate `--body-file` per the rules above (must exist and be
   non-empty / non-whitespace-only), then post the comment via the
   `comment create` template from the `/issues-jira:jira-lib` skill
   (`acli jira workitem comment create --key "<KEY>" --body-file "<path>"`).
   The body always comes from the file — never composed inline.
4. Report back the issue key, the title fetched in step 2, and the new
   comment's URL/identifier if `acli` returns one.

Do not partially implement on an `acli`-absent or auth failure: handle
those per the Jira-backend "Preconditions" (the "`acli` not installed"
catalogue entry, or the `acli jira auth login --web` recovery) rather
than posting.

## Hard constraints

- **Never comment on an issue you weren't given by number.** No
  title-search, no "find the right issue", no "recent work"
  inference. The number is the only input that identifies the
  target.
- **Never compose the body inline.** The body always comes from
  `--body-file`. If the caller wants to comment a short string, they
  write it to a file (a temp file under `.claude/tmp/` is fine) and
  pass that path. Keeping the body in a file makes the exact posted
  text reviewable and reproducible.
- **Never close the issue from this skill.** Closing is
  `/issue-close`'s job. If the caller wants comment-then-close,
  they invoke `/issue-close <N> --comment "..."` instead.
