---
name: issue-set-status
description: Set the status (single-select field) on a single issue's project board entry by human-readable name.
---

Set the status option on a single issue's entry in the configured
GitHub Project V2 board. Status is the single-select field whose ID
is stored under `github-project.fields.status` in
`.claude/rules/repo-config.md`; option names (e.g. `Todo`,
`In Progress`) resolve case-insensitively to option IDs in the
`options:` map under that block.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, name -> ID lookup rules, error wording, and
graceful-degradation rules. This file documents only what is specific
to `/issue-set-status`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-set-status <issue-number> <status-name>
```

- `<issue-number>` (required): issue number in the current repo, with
  or without a leading `#`.
- `<status-name>` (required): a human-readable status name (e.g.
  `Todo`, `In Progress`, `Done`). Matched case-insensitively against
  the `github-project.fields.status.options` map. Multi-word names
  must be quoted on the CLI.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Required repo-config

This command **requires** a `github-project:` block in
`.claude/rules/repo-config.md`. If the block is absent, abort with
the "No `github-project:` block in repo-config" error from the
catalogue in `skills/lib/issue.md`. This is an abort, not a
warning-and-skip — without the option map there is no way to resolve
the requested status name.

## Execution (GitHub backend)

1. **Resolve the status name to an option ID** per the
   "Name -> ID lookup rules" in `skills/lib/issue.md`. Case-folding
   is applied; whitespace is significant. If the name does not match
   any key in `fields.status.options`, abort with the "Slot value not
   in options map" error from the catalogue (with `<slot>` = `status`).
   Capture the canonical capitalization of the matched key for the
   report-back.

2. **Look up the issue node ID and current project item** using the
   node-ID lookup template from `skills/lib/issue.md`. Trim the query
   to `id` and the `projectItems` block.

3. **Resolve the project-item ID** per the "Project-item lookup"
   section in `skills/lib/issue.md`. If the issue is not yet on the
   configured board, call `addProjectV2ItemById` (template in the lib)
   to add it and capture the returned `item.id`.

4. **Set the status field** via the
   `updateProjectV2ItemFieldValue` single-select-field template from
   `skills/lib/issue.md`. Pass:
   - `projectId = github-project.project-id`
   - `itemId = <resolved item id>`
   - `fieldId = github-project.fields.status.id`
   - `optionId = <option id resolved in step 1>`

5. **Handle stale field IDs.** If the mutation returns a GraphQL
   error indicating the field ID is unknown to the project, surface
   the "Project field ID no longer exists on the project" error from
   the catalogue in `skills/lib/issue.md`.

6. **Issue not found**: if the node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue and abort.

## Output

Print one confirmation line using the **canonical capitalization** of
the option key (not whatever casing the user typed), then the issue
URL:

```text
Set status on issue #<N> to <canonical-name>.
https://github.com/<owner>/<repo>/issues/<N>
```
