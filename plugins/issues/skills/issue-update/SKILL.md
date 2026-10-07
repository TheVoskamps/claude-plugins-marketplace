---
name: issue-update
description: Update a single issue's title, body (replace/append/prepend), labels, or assignees in one invocation.
---

Update fields on a single existing issue: title, full body
replacement, additive body edits (append/prepend a line), label
add/remove, and assignee add/remove. One issue per invocation; loop
in conversation when editing multiple issues.

## Invocation

```text
/issue-update <issue>
              [--title "..."]
              [--body-file PATH]
              [--append "line to append"]
              [--prepend "line to prepend"]
              [--add-labels a,b] [--remove-labels a,b]
              [--add-assignees u1] [--remove-assignees u2]
```

- `<issue>` (required): an issue reference.
- `--title` (optional): replace the title.
- `--body-file` (optional): replace the whole body with the file's
  contents.
- `--append` (optional, repeatable): append one line to the current
  body; several append in CLI order.
- `--prepend` (optional, repeatable): prepend one line; the first
  `--prepend` ends up as the body's first line.
- `--add-labels` / `--remove-labels` (optional): comma-separated label
  names.
- `--add-assignees` / `--remove-assignees` (optional): comma-separated
  GitHub logins. Either also accepts the literal token
  `@default-assignee`, which the script resolves to `default-assignee`
  from the repo-level user-config — for an issue in the current repo
  only — then the user-global one
  (`skills/lib/user-config.md`), then the authenticated GitHub user.
  A user-config file that exists but predates schema-version `1`
  aborts rather than being skipped.

At least one update flag is required. `--body-file` cannot be combined
with `--append` or `--prepend` — a full replace makes line-additive
edits ambiguous — and the script refuses the combination.

## Execution

Run the `issue-update` script, which this plugin puts on `PATH`, with
the Bash tool from inside the repo's working tree, passing only the
flags the user asked for:

```bash
issue-update <issue> [--title "..."] [--body-file PATH] [--append "..."]... [--prepend "..."]... \
  [--add-labels a,b] [--remove-labels a,b] [--add-assignees u1] [--remove-assignees u2]
```

GitHub accepts an unknown label or assignee without an error and
drops it. The script therefore re-reads the issue after the edit and
reports what actually landed, not what was requested; when any
requested change did not land it still prints the full report, then
exits non-zero. Print its stdout as it stands. On a non-zero exit,
relay its stderr too, and tell the user which requested change did
not land.

## Output

One line per field that changed, then a blank line and the issue URL:

```text
Updated issue #<N>:
  title:           <new title>
  body:            replaced (<lines> lines)
  body:            appended <N> line(s), prepended <M> line(s)
  labels added:    a, b
  labels removed:  c
  assignees added: u1
  assignees removed: u2

https://github.com/<owner>/<repo>/issues/<N>
```

The `@default-assignee` token appears as the login it resolved to. A
requested change that did not land gets its own line under the others,
naming what was asked for:

```text
  labels requested but not added: bugg (not a valid label on this repo)
  assignees requested but not added: octocat-typo (not a valid assignee on this repo, or permission denied)
  labels requested but not removed: needs-triage (label is on the issue but could not be removed — permission denied, or label-management is restricted)
  assignees requested but not removed: u2 (assignee is on the issue but could not be removed — permission denied, or some other gh-side filter)
```

A title or body whose re-read differs from what was sent is reported
the same way. A label or assignee that was already in the requested
state is neither a change nor a failure.

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before it reads or writes an
issue; follow
`skills/lib/issue.md` → "Jira backend" → "Update" instead, resolving
`@default-assignee` the same way with the `acli` account as the last
fallback.
