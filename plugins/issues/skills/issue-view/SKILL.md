---
name: issue-view
description: Dump a single issue with body, all project fields, and parent/sub-issues/blockedBy/blocking relationships in one shot.
---

Print everything about a single issue in one pass — title, body,
labels, assignees, issue type, priority, status, parent, sub-issues,
blockedBy, and blocking — without requiring follow-up commands.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, error wording, and graceful-degradation rules. This file
documents only what is specific to `/issue-view`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-view <issue-number>
```

A single positional argument: the issue number in the current repo.
No flags.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Fetch labels and assignees** via `gh issue view`:

   ```bash
   gh issue view <N> --json number,title,body,url,labels,assignees,state
   ```

   These fields are convenient to read via `gh` and avoid a second
   GraphQL round-trip.

2. **Fetch relationships and project fields** via the node-ID lookup
   template from `skills/lib/issue.md` ("Node-ID lookup by issue
   number"). Use the template as-shown — `/issue-view` is the canonical
   caller, so it consumes the full shape (issue type, parent,
   subIssues, blockedBy, blocking, issueDependenciesSummary, and
   projectItems with fieldValues).

3. **Resolve per-slot field values by `kind:`.** Iterate the
   `github-project.fields` map in repo-config and, for each slot,
   dispatch on its `kind:` per the "Field-value read by kind" recipe
   in `skills/lib/issue.md`. There are exactly five cases:

   - **`kind: number`** — scan the project item's `fieldValues` for
     the `ProjectV2ItemFieldNumberValue` whose `field.id` matches
     `fields.<slot>.id`. Display the `number` as-is. Render `(none)`
     when the entry is absent.
   - **`kind: single-select`** — scan the project item's `fieldValues`
     for the `ProjectV2ItemFieldSingleSelectValue` whose `field.id`
     matches `fields.<slot>.id`. Display the `name` (the canonical
     option label, e.g. `P0`, `Backlog`). Render `(none)` when the
     entry is absent.
   - **`kind: issue-field`** — does **not** read from `projectItems`.
     Native issue fields live on the issue itself, so read from
     `Issue.issueFieldValues` (extend the node-ID lookup query per the
     `kind: issue-field` branch of the "Field-value read by kind"
     recipe). Find the `IssueFieldSingleSelectValue` whose `field.id`
     matches `fields.<slot>.field-id` and display its `name` (the
     canonical option label, e.g. `Medium`). Render `(none)` when no
     entry matches. This works regardless of project-board membership.
   - **`kind: label`** — does **not** read from `projectItems`. Read
     the issue's labels (from step 1's `gh issue view --json labels`
     payload), filter to labels that both start with
     `fields.<slot>.namespace` **and** strip to an option name that
     appears in `fields.<slot>.options` (case-insensitive match;
     canonical capitalization comes from `<options>`). The display
     depends on how many matched:
     - **zero matches** → `(none)`
     - **exactly one match** → the option name without the namespace
       prefix (e.g. `M`, not `size:M`)
     - **more than one match** → `(multiple)` — the read path does
       **not** delete extras; the user runs `/issue-set-<slot>` to
       converge. The "Label-namespace update" recipe enforces the
       at-most-one invariant on the next write.
   - **`kind: skip`** — the slot is omitted entirely from the output.
     No row, no `(none)` placeholder, no "skipped" notice.

   Slots that are **absent entirely** from `fields:` are also omitted
   entirely from the output (the same shape as `kind: skip`, per
   "Graceful degradation" in `skills/lib/issue.md`).

   The list of slots, their canonical names, and the row order in
   the output are all derived from `fields:` as read from repo-config.
   This skill hardcodes nothing about which slots exist — a repo that
   adds e.g. a `priority` slot under any of the five kinds gets a
   `priority:` row for free.

   If `github-project:` is missing from repo-config, omit the
   project-fields section entirely per "Graceful degradation" — do
   not warn; reads degrade quietly.

   If the configured project is present but the issue has no item on
   it, render every `kind: number` and `kind: single-select` slot as
   `(not on project board)` rather than failing. `kind: label` and
   `kind: issue-field` slots are unaffected by the project-board state
   — they read from the issue's labels and native issue fields
   respectively, and continue to render normally.

4. **Issue not found**: if the node-ID lookup returns
   `repository.issue: null`, emit the "Issue not found" error from
   the catalogue in `skills/lib/issue.md` and abort.

## Output

Print a single block in this order. Sections with no content (no
labels, no assignees, no parent, empty sub-issues, etc.) are still
printed with a `(none)` placeholder so the shape is predictable for
the reader — except project-field rows for slots that are absent or
`kind: skip` (those are omitted entirely), and the whole
project-fields group when there is no `github-project:` block.

```text
#<N> <title>                                       (<state>)
<url>

Labels:     <comma-separated names>
Assignees:  <comma-separated logins>
Type:       <issue-type name>
Priority:   <option name>
Size:       <option name>
Status:     <option name>

Parent:     #<N> <title>

Sub-issues:
  - #<N> <title>
  - #<N> <title>

Blocked by:
  - #<N> <title>
  - #<N> <title>

Blocking:
  - #<N> <title>
  - #<N> <title>

Body:
<body verbatim>
```

The `Priority:`, `Size:`, and `Status:` rows in the block above
are illustrative — they are the three conceptually-standard slots
today. The actual rows emitted come from iterating `fields:` in
repo-config (per step 3) in the order the slots appear in YAML.
`Size:` is positioned adjacent to `Priority:` when both are
present. Rows for slots that are absent or `kind: skip` are not
emitted at all.

When a section has no entries, replace its body with a single
`(none)` line — for the inline fields (`Labels:`, `Assignees:`,
`Type:`, the per-slot rows, and `Parent:`), that means the value
column reads `(none)`; for the three list sections (`Sub-issues:`,
`Blocked by:`, `Blocking:`), that means the section header is
followed by one `(none)` line at the bullet indent instead of any
`- #<N>` lines.

`kind: label` slot rows have one additional display state: when
more than one of the slot's own labels is set on the issue (an
inconsistent state), the value column reads `(multiple)`. The view
path does **not** delete the extras — `/issue-view` is read-only.
The user converges the state with `/issue-set-<slot>`.

The body is printed verbatim, including its own Markdown. Do not
re-wrap or re-format it.

Parent is a single value (an issue can only have one parent). The
three other relationship sections are lists. Render
`subIssues`/`blockedBy`/`blocking` from the GraphQL `nodes` arrays in
their returned order; do not re-sort.
