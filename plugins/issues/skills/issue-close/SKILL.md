---
name: issue-close
description: Close an issue by number; optionally post a summary comment first. Dispatches by repo's `issues:` tracker.
---

Close one issue, identified by its number. Optionally post a summary
comment **before** closing it.

See `skills/lib/issue.md` for shared repo-config parsing, tracker
dispatch, and error wording. This file documents only what is specific
to `/issue-close`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-close <issue-number> [--comment "summary"]
```

- `<issue-number>` — required. The issue number, with or without the
  repo's `issue-link-prefix` (`#42` and `42` are both accepted).
- `--comment "summary"` — optional. If present, post this string as a
  new comment on the issue **before** closing it. Use shell-style
  quoting; the value is passed verbatim to the tracker.

If `<issue-number>` is missing, prompt the user for it. Do not search
for "relevant issues" by title or by recent work — this skill closes
exactly the issue whose number was passed.

## Repo-config and tracker dispatch

Open with the standard repo-config read and `issues:` switch from
`skills/lib/issue.md` ("Repo-config parsing" and "Tracker dispatch").
This skill does **not** read the optional `github-project:` block —
closing an issue is a pure-issue operation and degrades fine without
project metadata.

## GitHub path (`issues: GitHub`)

Strip a leading `issue-link-prefix` (`#` for GitHub) from
`<issue-number>` before invoking `gh`. Use the normalized integer in
both the `gh` calls below and the report-back. `gh issue close #42`
is not a valid invocation; `gh issue close 42` is.

1. Fetch the issue title for the report-back:

   ```bash
   gh issue view <N> --json number,title,url --jq '.title'
   ```

   `gh issue close` and `gh issue comment` do not print the title, so
   this lookup happens up front. Cache the result for use in step 4.
   Surface any non-zero exit verbatim and stop — if `gh issue view`
   fails, the issue likely doesn't exist or isn't accessible, and
   neither commenting nor closing should proceed.

2. If `--comment` was passed, post it first:

   ```bash
   gh issue comment <N> --body "<summary>"
   ```

   Surface any non-zero exit verbatim and stop — do **not** close the
   issue if the comment failed to post, otherwise the summary trail
   the user requested is missing.

3. Close the issue:

   ```bash
   gh issue close <N>
   ```

4. Report back:
   - The issue number and title (the title fetched in step 1).
   - Whether a comment was posted.
   - The new state (closed) and the URL.
   - **Closing-keywords safety net.** If `--comment` was supplied,
     scan the comment body for a closing keyword (case-insensitive:
     `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`,
     `resolves`, `resolved`) immediately followed by `#<N>` (allowing
     whitespace between the keyword and the `#`). If any match, append
     one line to the report-back:

     > note: your comment contained closing keyword(s) referencing
     > #X, which will auto-close that/those issue(s).

     List every distinct `#X` that matched. Do **not** block the
     operation; the user-supplied `--comment` is passed through
     verbatim either way — this warning just makes the cascade-close
     consequence visible.

## Jira path (`issues: Jira`)

Follow the Jira backend "Close" path in `skills/lib/issue.md` → "Jira
backend" → "Close". Jira has no separate close verb — closing is a
transition to the project's done-equivalent status, resolved from the
`jira:` `status` slot. Concretely:

1. Normalize `<issue-number>` to a Jira key (`SET-42`; both `42` and
   `SET-42` are accepted) per the Jira-backend "Preconditions". Confirm
   `acli` is present and authenticated first.
2. Fetch the work item's summary (title) for the report-back via the
   `workitem view` template from the `/issues-jira:jira-lib` skill. Surface any
   non-zero exit verbatim and stop.
3. If `--comment` was passed, post it first via the `comment create`
   template (the same comment-then-close ordering as the GitHub path),
   and stop if it fails — do not transition if the comment failed.
4. Transition to the done-equivalent status via the `workitem
   transition` template (`--status "<Done>" --yes`).
5. Report back the same fields as the GitHub path (number/key, title,
   whether a comment was posted, new state, URL), including the
   closing-keywords safety-net scan on any `--comment` body.

Do not partially implement on an `acli`-absent or auth failure: handle
those per the Jira-backend "Preconditions" (the "`acli` not installed"
catalogue entry, or the `acli jira auth login --web` recovery) rather
than transitioning.

## Hard constraints

- **Never close an issue you weren't given by number.** No
  title-search, no "recent work" inference, no "find the relevant
  issues". The number is the only input that identifies the target.
- **Never close before commenting** when `--comment` was provided.
  Order is comment-then-close so the summary is preserved even if a
  later step fails.
- **Never place closing keywords adjacent to issue references in the
  comment body.** A closing keyword (`close`/`closes`/`closed`/
  `fix`/`fixes`/`fixed`/`resolve`/`resolves`/`resolved`,
  case-insensitive) **immediately followed by** an issue reference
  (`#N`, `owner/repo#N`, `GH-N`, or issue URL) inside a comment
  cascade-closes the referenced issue(s). The same keywords as
  ordinary English prose with no adjacent issue reference are fine.
  If the user-supplied `--comment` contains the parser-triggering
  pattern, pass it through verbatim — that's their call — but do
  not add such patterns yourself.
