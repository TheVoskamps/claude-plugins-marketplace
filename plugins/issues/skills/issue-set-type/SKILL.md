---
name: issue-set-type
description: Set the issue type (e.g. Task, Bug, Feature) on a single existing issue by human-readable name.
---

Set the issue type on a single existing issue. Issue type is an
**issue-level** attribute, not a project-field-level one: it is *not*
a `github-project.fields.<slot>` entry and does not flow through the
set-slot dispatcher. It is written via the `updateIssueIssueType`
mutation and resolved against the repo's `github-project.issue-types`
map (which lives at the same level as `fields:` but is its own thing).

`/issue-create` already accepts `--type` at creation time; this verb
closes the "set type on an existing issue" gap.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, name -> ID lookup rules, error wording, and
graceful-degradation rules. This file documents only what is specific
to `/issue-set-type`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-set-type <issue-number> <type-name>
```

- `<issue-number>` (required): issue number in the current repo, with
  or without a leading `#`.
- `<type-name>` (required): a human-readable issue-type name (e.g.
  `Task`, `Bug`, `Feature`). Matched case-insensitively against the
  `github-project.issue-types` map keys. Multi-word names must be
  quoted on the CLI.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Required repo-config

This command **requires** a `github-project.issue-types` map in
`.claude/rules/repo-config.md`. If the `github-project:` block is
absent entirely, abort with the "No `github-project:` block in
repo-config" error from the catalogue in `skills/lib/issue.md`. If the
block is present but carries no `issue-types:` map, abort with the
"No `issue-types:` map in repo-config" error from the same catalogue.

This is an abort, not a warning-and-skip — without the issue-types map
there is no way to resolve the requested type name.

## Execution (GitHub backend)

1. **Resolve the type name to an `issueTypeId`** per the
   "Name -> ID lookup rules" in `skills/lib/issue.md`. Case-folding is
   applied; whitespace is significant. If the name does not match any
   key in `github-project.issue-types` (excluding the `default:` key,
   which is not a type), abort with the "Issue-type name not in repo's
   issue-types map" error from the catalogue in `skills/lib/issue.md`.
   Capture the canonical capitalization of the matched key for the
   report-back.

2. **Look up the issue node ID and current type** using the
   "Node-ID lookup by issue number" template from
   `skills/lib/issue.md`. Trim the query to `id` and
   `issueType { id name }` — the project-item and dependency blocks
   are not needed for this verb.

3. **Issue not found**: if the node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from the
   catalogue and abort.

4. **Pre-check (idempotency)**: if the issue's current
   `issueType.id` already equals the `issueTypeId` resolved in step 1,
   print the no-op echo (below) and exit zero without calling the
   mutation.

5. **Set the issue type** via the `updateIssueIssueType` template from
   `skills/lib/issue.md`. Pass:
   - `issueId = <resolved issue node id>`
   - `issueTypeId = <type id resolved in step 1>`

## Output

Print one confirmation line using the **canonical capitalization** of
the matched `issue-types:` key (not whatever casing the user typed):

- Success:

  ```text
  #<N> type set to <CanonicalName>.
  ```

- No-op (idempotent pre-check matched):

  ```text
  #<N> type already set to <CanonicalName>.
  ```

No trailing URL line. This terse echo intentionally follows the
set-slot echo convention shared by `/issue-set-priority` and
`/issue-set-size` (a single `#<N> ... set to ...` line, `already set
to` for the no-op), not the fuller two-line `Set ... on issue #<N>
... \n <URL>` form that `/issue-set-status` prints. The omission is
deliberate, not an oversight.
