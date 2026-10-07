# `/issue-*` shared reference (`skills/lib/issue.md`)

This file holds what the `/issue-*` verbs share that is not code: how
a GitHub repository and an issue reference are written, the schema of
the `github-project:` block in `.issues/repo-config.md`, and the Jira
backend.

The GitHub backend of every verb is a script in this plugin's `bin/`,
named after the verb, and every script sources
`bin/lib/issues-common.sh`. That code is the only statement of the
GitHub calls: the repo-config read, node-ID and field/option ID
resolution, the GraphQL documents, the post-write re-reads, and the
error wording. A verb's `SKILL.md` says when to run its script, with
which arguments, and what the output means. When the repo-config that
governs a run says `issues: Jira`, the script exits non-zero with one
fixed message before it reads or writes an issue, and the verb follows
"Jira backend" below instead.

## Repositories and issue references

A verb argument that names a GitHub repository takes one of these
forms, resolved against the current repository — the one the
checkout's remote names, on that remote's host:

| Form | Repository |
| --- | --- |
| `repo` | `repo` under the current repository's owner, on its host |
| `owner/repo` | that repository, on the current repository's host |
| `host/owner/repo` | that repository, on that host |
| `https://host/owner/repo` | the same as `host/owner/repo`; a trailing `/` is ignored |

Outside a git checkout there is no current repository: `repo` is a
usage error, and `owner/repo` goes to `gh`'s default host.

An argument that names an existing issue — every verb's issue operand,
and `/issue-create --parent` — takes one of these forms:

| Form | Issue |
| --- | --- |
| `N`, `#N` | issue `N` in the current repository; `N` may carry the repo-config's `issue-link-prefix` |
| `repo#N`, `owner/repo#N`, `host/owner/repo#N` | issue `N` in the repository, in any form above |
| `https://host/owner/repo/issues/N` | the same as `host/owner/repo#N`; a trailing `/` is ignored |

Each part of a repository is letters, digits, `.`, `_` and `-`.

The verbs take issues only. An operand that names a pull request — a
`https://host/owner/repo/pull/N` URL before any call, a number once it
is read — aborts with exit 1, naming it as a pull request.

A verb acts on an operand in its own repository, on its own host, and
only that repository's repo-config governs it. A run reads the current
repository's repo-config only when it acts there: an operand in the
current repository, or `/issue-create` and `/issue-field-options` with
no `<repo>`. A Jira-tracked checkout, or one with no repo-config, stops
a verb on its own issues and not on another repository's. For an
operand in another repository, the repo-config that governs it is that
repository's `.issues/repo-config.md`, read from its default branch:

- under `issues: Jira` the verb exits with the fixed Jira message
  before it reads or writes the issue, and at an unsupported
  schema-version with the canonical schema wording;
- a verb that reads a project-board slot or the issue-types map reads
  that repository's `github-project:` block. Where the repository has
  no repo-config, or no such block, a setter aborts naming the
  repository, and `/issue-view` prints no slot rows;
- with no repo-config there, every other verb proceeds.

A printed issue reference takes the shortest form that names the
issue back through the forms above: `#N` in the current repository,
`repo#N` under its owner on its host, `owner/repo#N` on its host, and
`host/owner/repo#N` on another host.

## Repo-config parsing

Every `/issue-*` verb reads a repo-config —
`<repo-root>/.issues/repo-config.md`, or another repository's —
following the read contract in `skills/lib/repo-config.md`, and
requires **schema-version 6**. The scripts do so in
`issues-common.sh`; the Jira path runs that library's canonical read
sequence and uses its abort messages verbatim — "File missing",
"Schema-version absent", "Schema-version stale", and "Front-matter
incomplete".

The read resolves **two sections**:

1. **Front-matter** — the canonical keys: `source-control`, `issues`,
   `issue-link-prefix`, `default-issue-source-branch`,
   `default-pr-target-branch`, `issue-branch-naming-prefix`. Used for
   tracker dispatch and issue-link formatting.
2. **`github-project:` block in the body** — optional. Parsed as YAML.
   When present, supplies the project ID, per-slot field configuration,
   and issue type IDs for the current repo. Schema:

   ```yaml
   github-project:
     project-id: PVT_kwDO...   # ProjectV2 node ID
     fields:
       status:
         kind: single-select
         id: PVTSSF_lADO...    # single-select field ID
         default: Todo
         options:
           Backlog:     <option-id>
           Todo:        <option-id>
           In Progress: <option-id>
           In review:   <option-id>
           Done:        <option-id>
       priority:
         kind: number
         id: PVTF_lADO...      # number-field ID
         default: 3
         min: 1
         max: 9
       size:
         kind: label
         namespace: "size:"
         default: M
         options: [XS, S, M, L, XL]
     issue-types:
       default: Feature
       Bug:     IT_kwDO...
       Feature: IT_kwDO...
       Goal:    IT_kwDO...
       Problem: IT_kwDO...
   ```

   The IDs shown are illustrative. Per-repo IDs are populated by
   `/repo-config` (which discovers them with the `issues-discover`
   script) and are stable for the life of the project board.

### Field kinds (`fields.<slot>.kind`)

Each populated slot under `fields:` carries a `kind:` discriminator
that tells the verb how to read and write it. There is **no implicit
default `kind:`** — every populated slot declares its kind. There is
**no backwards-compat shim** for the old `type: number` /
`type: single-select` shape; a repo on the old shape is invalid and
must be regenerated by re-running `/repo-config`.

The schema does not enumerate the allowed slot names. The
conceptually-standard slots today are `status`, `priority`, and
`size`, but verbs read whatever slot they're looking for and dispatch
on its `kind:`. A new verb that wants e.g. an `effort` slot just
declares one in repo-config under any of the kinds below.

The kinds:

- **`kind: number`** — a number-typed project field. `min` and `max`
  bound the accepted range; out-of-range values abort the verb
  cleanly (e.g. `/issue-set-priority N 10` aborts when `max: 9`)
  rather than writing nonsense to the board.

  ```yaml
  fields:
    priority:
      kind: number
      id: PVTF_...
      default: 3
      min: 1
      max: 9
  ```

- **`kind: single-select`** — a single-select project field with an
  `options:` map from canonical option name to option ID. Same shape
  `fields.status` uses, applied uniformly to any slot:

  ```yaml
  fields:
    priority:
      kind: single-select
      id: PVTSSF_...
      default: P1
      options:
        P0: <option-id>
        P1: <option-id>
        P2: <option-id>
  ```

- **`kind: label`** — a label **namespace**, not a project field at
  all. The verb manages the slot by adding/removing labels via
  `gh issue edit --add-label/--remove-label`. Concrete labels are
  formed as `<namespace><option>`, e.g. `size:XS`, `size:S`, etc.
  `options:` is a flat list (not a map) because labels carry no
  per-option ID — the label name is its own identifier.

  ```yaml
  fields:
    size:
      kind: label
      namespace: "size:"
      default: M
      options: [XS, S, M, L, XL]
  ```

  A slot owns only the labels its `options` form. Setting it adds
  the requested one and removes the slot's others, so at most one is
  ever set; a namespace label outside `options` (`size:XXL` above) is
  left alone.

- **`kind: skip`** — the slot is explicitly declared as unused: the
  repo does not track it. No other keys are allowed:

  ```yaml
  fields:
    priority:
      kind: skip
  ```

  A slot **absent** from `fields:` means exactly what `kind: skip`
  means. The two spellings are equivalent by design — `kind: skip`
  makes "we deliberately don't track this here" visible, and omission
  serves a repo whose author never thought about the slot — so a
  config may use either, and there is no third "missing slot" form.

- **`kind: issue-field`** — a **native GitHub Issue Field** (the
  preview feature that attaches ProjectV2-style fields directly to an
  issue, independent of any project board). Unlike `kind: number` and
  `kind: single-select` — which read/write a *project item's* field
  value and therefore require the issue to be on the configured board —
  an `issue-field` slot reads and writes the value **on the issue
  itself**, so it works regardless of board membership. That
  board-independence is the selling point of this kind.

  The kind ships the **single-select** native-field shape only.
  GitHub's two single-select native fields back two slots: `Priority`
  (`dataType: SINGLE_SELECT`, the `priority` slot, introduced by `#29`)
  and `Effort` (`dataType: SINGLE_SELECT`, options `High` / `Medium` /
  `Low`, the `size` slot, added by `#32`). The kind is fully parametric
  on `field-id` / `field-name` / `options`, so any slot can be backed
  by any single-select native field with no verb changes — the `size`
  slot reads and writes identically to `priority`, just against a
  different field id and option set. The slot carries
  `data-type: single-select`, the native field's node `id` under
  `field-id:`, the human-readable field name under `field-name:` (used
  for display and error messages), and an `options:` map from canonical
  option name to the option's node `id` — the same name→id map shape
  `kind: single-select` uses, except the IDs are native-field option
  IDs (`IFSSO_...`), not project single-select option IDs:

  ```yaml
  fields:
    priority:
      kind: issue-field
      data-type: single-select
      field-id: IFSS_...        # native issue-field node ID
      field-name: Priority      # for display / error messages
      default: Medium
      options:
        Urgent: IFSSO_...
        High:   IFSSO_...
        Medium: IFSSO_...
        Low:    IFSSO_...
    size:                       # backed by the native Effort field (#32)
      kind: issue-field
      data-type: single-select
      field-id: IFSS_...        # the Effort field's node ID
      field-name: Effort        # for display / error messages
      default: Medium
      options:                  # the Effort field's own — not t-shirt
        High:   IFSSO_...
        Medium: IFSSO_...
        Low:    IFSSO_...
  ```

  Scoping note: at the time `#29` was scoped, the `IssueFieldCommon`
  interface exposed no node `id`, so native fields were addressable
  only by `name`. Re-introspection against the live schema
  found the concrete `IssueFieldSingleSelect` object type
  **does** expose a stable node `id`, and `setIssueFieldValue`'s input
  (`IssueFieldCreateOrUpdateInput`) addresses the field by that node
  ID, not by name. The slot therefore stores `field-id:` as the
  authoritative identifier and keeps `field-name:` only for display.
  `#32` added the `Effort` single-select native field as the `size`
  slot's backing, reusing this same machinery unchanged. The remaining
  native fields (`Start date`, `Target date`) and the `DATE` / `NUMBER`
  / `TEXT` / `MULTI_SELECT` data-types are still **out of scope**; a
  future slot that needs them extends `data-type:` and the per-type
  value shape accordingly.

### Locating the `github-project:` block

Scan the body (everything after the closing front-matter `---`) for a
line that starts with `github-project:` at column 0. The block runs
until the next column-0 non-blank line (a new top-level key) or EOF.
Parse the indented YAML beneath it.

The block is optional. A repo without a Project V2 board omits it
entirely, and then configures no project, no `issue-types:` map and no
slot: every slot reads as unconfigured, as if declared `kind: skip`.

## Jira backend

This section is how every `/issue-*` verb runs when
`.issues/repo-config.md` says `issues: Jira`: the verb's script refuses
that tracker, so the verb is carried out from this prose. The surface
is the GitHub one — the same flags, the same default-resolution order,
the same name lookups, the same echo formats and the same
abort-if-missing contract as the verb's `SKILL.md` describes — and only
the calls underneath differ. Every operation talks to Jira through the
Atlassian CLI (`acli`); the concrete `acli` command shapes are **not**
restated here — they live in the `/issues-jira:jira-lib` skill and are
referenced by name ("uses the `workitem transition` template from the
`/issues-jira:jira-lib` skill").
This keeps the `acli` command surface in one place so a version drift
is fixed once.

The Jira path resolves metadata against the **`jira:`** block of
`.issues/repo-config.md` (schema in
`skills/lib/repo-config.md` → "`jira:` block"), exactly the way the
GitHub path resolves against `github-project:`. The block is optional
exactly as `github-project:` is (see "Locating the `github-project:`
block" above), and a `kind: skip` slot or an absent one means what it
means there.

### Preconditions (every Jira operation)

1. **`acli` present.** Detect with `command -v acli` per
   the `/issues-jira:jira-lib` skill → "`acli` availability". If absent, abort the
   Jira branch with the "`acli` not installed" wording below —
   do **not** fall back to the REST API or `jira-cli`.
2. **Authenticated.** Check with `acli jira auth status`. On a missing
   or expired session, the canonical recovery is a single
   `acli jira auth login --web` (a credential-prompting command per
   `~/.claude/rules/credential-surfaces.md` and
   the `/issues-jira:jira-lib` skill → "Auth expectation and failure surface"),
   then retry the original command. If one login does not resolve it,
   **stop and report** — never introspect or manipulate the Atlassian
   credential state.
3. **Issue key, not number.** Jira addresses work items by **key**
   (e.g. `SET-123`), not a bare integer. The caller's `<N>` argument
   is normalized to a key by concatenating the `issue-link-prefix`
   (`SET-`) with the number when the caller passed a bare number, or
   used as-is when the caller already passed a full key. Both `123`
   and `SET-123` are accepted, mirroring the GitHub side's `#42` / `42`
   tolerance.

### Resolution rules

#### Default-resolution order

For every flag with a default, resolve in this exact order — first
hit wins:

1. **CLI flag** explicitly passed on the command line.
2. **Interactive prompt** — slot flags on `/issue-create` only, per
   Step 2 of `skills/issue-create/SKILL.md`.
3. **Repo-config default** in the tracker block — `fields.<slot>.default`
   for a slot flag, `issue-types.default` for `--type`.
4. **Built-in default** — `Feature` for `--type`; for `--assignee`,
   `default-assignee` across the two user-config scopes
   (`skills/lib/user-config.md`), then the account
   `acli jira auth status` reports.

Slot flags have no built-in default: with none of the first three, or
on a `kind: skip` or absent slot, the slot resolves to no value.

#### Name -> ID lookup rules

Flags take **human-readable names**, never raw identifiers, resolved
against the tracker block:

- **Case-insensitive match**, with the canonical capitalization taken
  from the map key for every echo.
- **Whitespace is significant**: `In Progress` and `In  Progress` are
  different keys.
- **No fuzzy matching.** A name that matches nothing aborts with the
  "Slot value not in options map" or "Issue-type name not in repo's
  issue-types map" wording below.

#### Issue operands

An issue operand that names a repository — every form "Repositories
and issue references" lists but `N` and `#N` — is GitHub-only, because
a Jira key is already globally unique: under `issues: Jira` it aborts
with the "Cross-repo operand under Jira" wording below, before the
"Preconditions" run and so before any `acli` call.

#### One edge, two sides

`set-blocked-by N B` and `set-blocks B N` write one edge, as do
`set-parent C P` and `set-child P C`; the `unset-` verbs mirror them.
`unset-child P C` on a child whose parent is not `P` is a no-op, since
the end state already holds.

#### Label-slot update

A `kind: label` slot is written by computing two sets against the
issue's current labels: the **remove set**, every
`<namespace><option>` for the slot's other options that is present,
and the **add set**, `<namespace><requested>` when it is absent. Sort
both alphabetically, and make one call with both deltas, omitting an
empty one; when both are empty, make none. Labels in the namespace but
outside `options` are never touched. Afterwards at most one of the
slot's own labels is set.

#### Set-slot dispatch

`/issue-set-<slot> <N> <value>` re-reads the slot from the `jira:`
block every run and dispatches on its `kind:`: `skip` or absent prints
the verb's "nothing to do" line and exits zero; every other kind
resolves `<value>` against the slot's `options` per the lookup rules
above, then follows its write path under "Metadata setters" below. A
write whose value is already set prints the verb's `already set to`
echo and skips the call.

### Read / view (`/issue-view`, `/issue-view-tree`, `/issue-sub-list`)

Fetch a work item and its relationships with the `workitem view`
template from the `/issues-jira:jira-lib` skill (`acli jira workitem view "<KEY>"
--json`, with the key as a **positional** argument — `workitem view`
takes no `--key` flag). Read the summary (title), description (body),
status, labels, issue type, and the custom-field values
(priority/size) from its `--json` payload.

- **Slot values** are read by dispatching on the `jira:` slot's
  `kind:`:
  - **`kind: status`** — the work item's current status name from the
    `--json` payload. Render the status name; `(none)` if unset.
  - **`kind: custom-field`** — the value of the field whose id is the
    slot's `field-id:` (`customfield_NNNNN`) from the payload. Render
    the value as-is; `(none)` if the field is absent or empty.
  - **`kind: label`** — filter the work item's labels to
    `<namespace><option>` for each option in the slot's `options`,
    applying the same zero / exactly-one (render option name without
    prefix) / more-than-one (`(multiple)`) rules. Foreign labels in
    the namespace not in `options` are ignored for display.
  - **`kind: skip` / slot absent** — no value to read, as on GitHub.
- **Issue type** — the work item's type name from the payload.
- **Relationships** — parent/sub-task and issue links come from the
  same `workitem view --json` payload (its `parent` and issue-links
  arrays). For listing **all** sub-tasks of a parent (the
  `/issue-sub-list` need), use the `workitem search` template
  (`acli jira workitem search --jql "parent = <KEY>" --json`), which
  returns every child without a 50-item cap. `/issue-view` and
  `/issue-view-tree` read the inline parent/children from the
  `workitem view` payload and skip the search.

### Create (`/issue-create`)

Create a work item with the `workitem create` template from
the `/issues-jira:jira-lib` skill. Resolve each field through the **same
default-resolution order** ("Default-resolution order" above), then
map to `acli` flags / payload:

- **type** → `--type "<Type Name>"`, resolved from the `jira:`
  `issue-types:` map (name→name; identity). Abort-if-missing per the
  contract below.
- **summary** (title) → `--summary "<title>"`.
- **body** (description) → the `acli` description flag / payload field
  for the work item's description.
- **labels** → `--label "<comma,separated>"`.
- **parent** → `--parent "<PARENT-KEY>"`.
- **status** (`kind: status`) — `create` lands the item in the
  project's default status; to honor a resolved `--status` that
  differs, follow create with the **status transition** below.
- **priority / size** (`kind: custom-field` or `kind: label`) — set
  after create via the **metadata application** paths below, since
  `acli create` has no per-field flag for arbitrary custom fields
  (it goes through the JSON payload form — see
  the `/issues-jira:jira-lib` skill → "Create a work item").

After create, add a project/board entry is **not** needed on Jira (a
work item lives in its project inherently — there is no separate
"add to board" step like GitHub's `addProjectV2ItemById`).

### Metadata setters (set-status / -priority / -size / -type)

These follow "Set-slot dispatch" above: normalize `<N>` to a key,
re-read the slot's `jira:` config, dispatch on `kind:`, resolve
`<value>` against the slot's `options` (case-insensitive, canonical
capitalization from the map), and abort-if-missing with the live valid
list. The kind→write-path mapping:

- **`kind: status`** — write with the `workitem transition` template
  (`acli jira workitem transition --key "<KEY>" --status "<Name>"
  --yes`). This is the Jira analogue of the single-select status
  write. The target status name is resolved from the slot's `options`
  map. Idempotency pre-check: read the work item's current status
  first (via `workitem view --json`); if it already equals the
  requested status, emit the no-op echo and skip the transition.
- **`kind: custom-field`** — write with the `workitem edit` JSON-payload
  template (`acli jira workitem edit --key "<KEY>" --from-json
  "<payload.json>"`), where the payload sets the field by its
  `field-id:` (`customfield_NNNNN`) to the resolved option value. This
  is the Jira analogue of the number / single-select project-field
  write. The payload file is written under `.claude/tmp/<task-slug>/`
  and passed by path.
- **`kind: label`** — "Label-slot update" above, making the call with
  `acli jira workitem edit --key "<KEY>" --labels "<to-add>"
  --remove-labels "<to-remove>"` (note `--labels` / `--remove-labels`,
  plural — `workitem edit` has no singular `--label` flag; that exists
  only on `workitem create`).
- **issue type** (`/issue-set-type`) — there is no Jira "edit type"
  per-field flag in all `acli` versions; set it via `workitem edit`
  with the type in the JSON payload (or the `--type` flag where the
  installed `acli` exposes it on `edit`). Resolve the type name from
  the `jira:` `issue-types:` map, abort-if-missing per the contract.

### Update (`/issue-update`)

Title / body / labels / assignees go through `workitem edit`:

- **title** → the `--summary` field on `edit`.
- **body** → the description field on `edit`.
- **labels** → `--labels` / `--remove-labels` deltas on `edit`
  (note `acli`'s flags are plural and `--labels` sets the full
  intended list rather than appending — see the `workitem edit` label note in
  the `/issues-jira:jira-lib` skill).
- **assignees** → the assignee flag on `edit`. Jira work items
  typically carry a single assignee; map `--add-assignees` /
  `--remove-assignees` to setting / clearing the assignee
  accordingly, and note the single-assignee constraint in the
  report-back if the caller passed more than one.

### Comment (`/issue-comment`)

Post a comment with the `comment create` template from
the `/issues-jira:jira-lib` skill (`acli jira workitem comment create --key
"<KEY>" --body-file "<path>"` — `comment create` is a space-separated
subcommand of the `workitem comment` group, not a `comment-create`
token). The body comes from `--body-file` the
same way the GitHub path requires; validate the file exists and is
non-empty per `/issue-comment`'s rules, and pass the file through —
never compose the body inline.

### Close (`/issue-close`)

Jira has **no separate close verb** — closing is a transition to the
project's done-equivalent status. Resolve that status from the
`jira:` `status` slot (the option whose name is the project's
done-equivalent, e.g. `Done`), then apply the **status transition**
above (`workitem transition --status "<Done>" --yes`). If
`--comment` was passed, post it first via the comment path, then
transition — comment-then-close ordering matches the GitHub path so
the summary is preserved even if the transition fails.

### Relationships (parent/child, blocks/blocked-by)

"One edge, two sides" above applies: the two verbs per edge differ
only in how they take their arguments, and the underlying Jira link is
one edge.

- **parent / child** (`/issue-set-parent`, `/issue-set-child`,
  `/issue-unset-parent`, `/issue-unset-child`) — Jira models this as
  a parent / sub-task link (or epic→issue link, depending on the
  project's hierarchy). Set it via `workitem edit --parent
  "<PARENT-KEY>"` (or the project's issue-link create where sub-tasks
  are not used); unset by clearing the parent. `unset-child P C`
  treats a mismatched current parent as a no-op, exactly as on the
  GitHub side.
- **blocks / blocked-by** (`/issue-set-blocks`,
  `/issue-set-blocked-by`, `/issue-unset-blocks`,
  `/issue-unset-blocked-by`) — Jira models these as issue links of
  type "Blocks". Create the link with the `workitem link create`
  template from the `/issues-jira:jira-lib` skill (`acli jira workitem link create
  --out "<KEY-A>" --in "<KEY-B>" --type "Blocks"`); the **unset** verbs
  delete by link id (`link list --key` to find the id, then `link
  delete --id`) — there is no `workitem unlink` command.
  `set-blocks N B` writes "N blocks B"; `set-blocked-by N B` writes
  "N is blocked by B". Remove the link to unset.

### Abort-if-missing / no-silent-fallback (Jira)

The Jira backend enforces the **same** abort-if-missing contract the
GitHub side does — see the `/issues-jira:jira-lib` skill → "Abort-if-missing /
no-silent-fallback contract". A configured option that does not
resolve aborts with the actual valid list re-discovered from Jira
(issue types via the create template, statuses via a representative
work item, custom-field options via the field payload); it never
silently writes a fallback. The "Slot value not in options map" and
"Issue-type name not in repo's issue-types map" wordings below take
their known-options list from the `jira:` block.

### Error wording

Use these exact wordings, which are the Jira forms of the ones the
scripts emit. Variable parts are in backticks.

- **Issue not found**

  > issue `<KEY>` not found in project `<project-key>`

- **Cross-repo operand under Jira**

  > `owner/repo#N` operands are GitHub-only

- **Slot value not in options map**

  > value `<value>` is not in `<slot>`'s options. Known options:
  > `<comma-separated canonical names>`.

  The names are the slot's `options` keys, in the order the YAML lists
  them.

- **No `jira:` block in repo-config** — for a verb that needs the
  block:

  > no `jira:` block in `repo-config.md`; run `/repo-config` to add it

  `/issue-create` warns and skips the flag instead:

  > warning: no `jira:` block in `repo-config.md`;
  > skipping `--<flag>`. Run `/repo-config` to add it.

- **No `issue-types:` map in repo-config**

  > issue-types map missing from `jira:` in `repo-config.md`;
  > run `/repo-config` to add it

- **Issue-type name not in repo's issue-types map**

  > issue type `<name>` not in repo's `jira.issue-types`.
  > Known types: `<comma-separated canonical names>`

- **Slot kind doesn't match the operation**

  > `/issue-set-<slot>` was called with `<value>`, but this repo's
  > `<slot>` is configured as `kind: <kind>`. Use one of:
  > `<comma-separated canonical names>`. (Or run `/repo-config` to
  > reconfigure.)

- **`acli` not installed**

  > `issues: Jira` is configured, but `acli` (the Atlassian CLI) is
  > not on `PATH`. Install it per Atlassian's docs; do not fall back
  > to the REST API or `jira-cli`.

  Detect the absence and report it — never install `acli`. An **auth**
  failure is not this abort: it is the one `acli jira auth login --web`
  under "Preconditions", and only if that login does not resolve it do
  you stop and report.
