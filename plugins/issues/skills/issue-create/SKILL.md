---
name: issue-create
description: Create a new issue in this repo end-to-end (title, body, type, priority, size, status, parent, assignees, labels) in a single invocation.
---

Create a new issue in the current repo with all metadata set in one
shot: title, body, issue type, parent link, priority, size, status,
assignees, and labels. The command runs the full GraphQL chain so the
issue is fully configured before the URL is printed.

See `skills/lib/issue.md` for the shared GraphQL templates,
default-resolution order, name -> ID lookup rules, tracker dispatch,
and error wording. This file documents only what is specific to
`/issue-create`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-create --title "..." --body-file PATH
              [--type T] [--labels a,b,c] [--assignee u1,u2]
              [--parent N]
              [--priority V] [--size V] [--status S]
```

- `--title` (required): issue title.
- `--body-file` (required): path to a file whose contents are used as
  the issue body verbatim. Use a file rather than `--body "..."` so
  long bodies and Markdown survive the CLI unchanged.
- `--type` (optional): issue type name (case-insensitive match against
  `issue-types:` in the repo's `github-project:` block). Default
  resolves via the order in `skills/lib/issue.md` ("Default-resolution
  order"): CLI flag, then `issue-types.default` in the repo's
  `github-project:` block, then built-in default `Feature`.
- `--labels` (optional): comma-separated label names. Passed straight
  through to `gh issue create --label`. Default: none.
- `--assignee` (optional): comma-separated GitHub usernames. Default
  resolves in this order (this is the demonstration consumer of the
  user-config read path from `skills/lib/user-config.md`, proving the
  contract end-to-end):
  1. The `--assignee` CLI flag, if given.
  2. `default-assignee` from the **repo-level** user-config
     (`<repo-root>/.claude/rules/user-config.md`), if present.
  3. `default-assignee` from the **user-global** user-config
     (`~/.claude/rules/user-config.md`), if present. (Repo-level
     overrides user-global, per `skills/lib/user-config.md` →
     "Resolution order across the two scopes".)
  4. The authenticated GitHub user (`gh api user --jq '.login'`).

  Steps 2–3 follow the canonical read sequence in
  `skills/lib/user-config.md` (this reader requires user-config
  schema-version `1`). Both user-config files are **optional**: when
  neither exists or neither defines `default-assignee`, the resolver
  **degrades** straight to step 4 — the pre-existing behavior — so
  this consumer adds capability without changing the default outcome
  for any user who has not created a user-config file. A user-config
  file that *exists* but is schema-stale aborts per that library's
  "Schema-version stale" message rather than degrading.
- `--parent` (optional): parent issue number. When set, the new issue
  is linked as a sub-issue of the given parent via the `addSubIssue`
  template from `skills/lib/issue.md`. Default: none.
- `--priority` (optional): a single token whose parse rules depend
  on `fields.priority.kind:` in the repo's `github-project:` block.
  Per-kind parse rules (same as the "Set-slot dispatcher" in
  `skills/lib/issue.md`):
  - **`kind: number`** — base-10 integer in
    `[fields.priority.min, fields.priority.max]`.
  - **`kind: single-select`** — option name from
    `fields.priority.options`, matched case-insensitively (canonical
    capitalization from the option map).
  - **`kind: label`** — option name from `fields.priority.options`
    (flat list), matched case-insensitively.
  - **`kind: issue-field`** — option name from
    `fields.priority.options` (the native GitHub Issue Field's option
    map), matched case-insensitively (canonical capitalization from
    the option map).
  - **`kind: skip` or slot absent** — warn-and-skip the flag (per
    "Graceful degradation" in `skills/lib/issue.md`). The value is
    not parsed or validated.

  Default resolves via the order in `skills/lib/issue.md`
  ("Default-resolution order"). For create-time slot flags the full
  order is: CLI flag, then an **interactive prompt** (see Step 2 in
  the execution chain below and the "Interactive prompt rung"
  section in `skills/lib/issue.md`), then `fields.priority.default`
  in the repo's `github-project:` block. There is no built-in
  default — if none of those produce a value, the slot is skipped.
- `--size` (optional): a single token whose parse rules depend on
  `fields.size.kind:`. Same kind dispatch as `--priority`:
  - **`kind: number`** — base-10 integer in
    `[fields.size.min, fields.size.max]`.
  - **`kind: single-select`** — option name from `fields.size.options`,
    matched case-insensitively (canonical capitalization from the
    option map).
  - **`kind: label`** — option name from `fields.size.options` (flat
    list), matched case-insensitively.
  - **`kind: issue-field`** — option name from `fields.size.options`
    (the native GitHub Issue Field's option map — e.g. the native
    `Effort` field's `High` / `Medium` / `Low`), matched
    case-insensitively (canonical capitalization from the option map).
  - **`kind: skip` or slot absent** — warn-and-skip the flag.

  Default resolves via CLI flag, then the interactive prompt
  (Step 2 in the execution chain), then `fields.size.default`. No
  built-in default; an unset slot is skipped. The interactive
  prompt's recommendation for `--size` is generated by evaluating
  the issue body — see the "Size evaluation heuristic" section
  below.
- `--status` (optional): a single token whose parse rules depend on
  `fields.status.kind:`. Same kind dispatch as `--priority` and
  `--size`. Default resolves via CLI flag, then the interactive
  prompt (Step 2 in the execution chain), then
  `fields.status.default`. No built-in default; an unset slot is
  skipped.

Build the `gh issue create` invocation only from flags the user
actually passed or that resolved to a concrete value. Do not pass
empty arguments (`--label ""`, `--assignee ""`); skip the flag.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`
("Tracker dispatch"). Under `issues == Jira`, follow the Jira backend
path documented there (`skills/lib/issue.md` → "Jira backend" →
"Create"), which creates the work item via `acli`
(the `/issues-jira:jira-lib` skill) and resolves type/status/priority/size from
the `jira:` block the same way the GitHub backend resolves them from
`github-project:`; it no longer aborts.

## Execution chain (GitHub backend)

Run these steps in order; each step takes the output of the previous
step as input. If any step fails, stop and report what completed and
what didn't — do not roll back successful steps.

1. **Resolve defaults (non-prompted rungs).** Apply the
   default-resolution order from `skills/lib/issue.md` to `--type`,
   `--labels`, and `--parent` — i.e. CLI flag, then repo-config
   default, then built-in default where applicable. Resolve
   `--assignee` through its own four-rung order from the flag spec
   above (lines 36–57): CLI flag, then `default-assignee` from the
   **repo-level** user-config, then `default-assignee` from the
   **user-global** user-config (both read via the canonical sequence
   in `skills/lib/user-config.md`, which this consumer pins to
   user-config schema-version `1`), then the authenticated GitHub
   user as the final fallback. None of these four flags prompt; their
   resolution is complete after this step. The slot flags
   (`--priority`, `--size`, `--status`) get rung 1 here (CLI flag,
   if passed); the remaining rungs are handled in Step 2 below.

   If `github-project:` is absent in repo-config, `--type` and
   `--assignee` still resolve via their defaults (for `--assignee`,
   the user-config rungs then the authenticated GitHub user; both
   user-config files are optional and absence degrades straight to
   the authenticated user), but the slot
   flags warn-and-skip per "Graceful degradation" — no prompt either
   (Step 2 is a no-op for any slot whose `kind:` resolves to `skip` /
   slot-absent).

2. **Interactive prompts for slot flags.** For each slot in
   `{priority, size, status}` whose CLI flag was **not** passed in
   Step 1, run the "Interactive prompt rung" from
   `skills/lib/issue.md`:

   - Skip the prompt for any slot whose `fields.<slot>.kind:` is
     `skip` or whose entry is absent from `fields:` — those slots
     warn-and-skip per "Graceful degradation" without any prompt.
   - For `--size`, evaluate the issue body per the "Size evaluation
     heuristic" section below to pick the recommended option, then
     issue a single `AskUserQuestion` for size with that option
     first / `(Recommended)`.
   - For `--priority` and `--status`, the recommended option is
     `fields.<slot>.default` from repo-config (if set). Issue one
     `AskUserQuestion` per slot.
   - The three prompts MAY be combined into a single
     `AskUserQuestion` call when convenient (the harness allows up
     to four questions per call) — the user experience is
     equivalent.

   The user's answer for a given slot resolves it for the remainder
   of the run, exactly as if they had passed the CLI flag. If a
   prompt is unanswered (harness time-out, non-interactive context),
   fall through to `fields.<slot>.default`; if that is also absent,
   warn-and-skip.

   Skip this step entirely when no slot needs a prompt — i.e. when
   every slot was either passed on the CLI in Step 1 or is
   `kind: skip` / absent.

3. **Create the issue.**

   ```bash
   gh issue create \
     --title "<title>" \
     --body-file "<path>" \
     [--label "<labels>"] \
     [--assignee "<assignees>"]
   ```

   `gh issue create` prints the new issue URL on stdout. Capture it.
   Extract the issue number from the URL tail.

4. **Look up the issue node ID** using the node-ID-lookup template
   from `skills/lib/issue.md`. Trim the query to just `id` and the
   `projectItems` block (the rest of the template's fields aren't
   needed here).

5. **Look up the project-item ID** per the "Project-item lookup"
   section in `skills/lib/issue.md`. If `github-project:` is present
   and the issue is not yet on the configured board, call
   `addProjectV2ItemById` (template in the lib) to add it and capture
   the returned `item.id`.

6. **Set the issue type** via the `updateIssueIssueType` template,
   using the resolved type name -> ID lookup. Skip if there is no
   `github-project:` block (no `issue-types:` map to look up against).

7. **Link to parent**, if `--parent` was passed. Look up the parent's
   node ID (re-use the node-ID lookup template, trimmed to `id`), then
   call the `addSubIssue` template with `issueId: <parent-id>` and
   `subIssueId: <new-issue-id>`.

8. **Set priority**, if `--priority` resolved to a concrete value.
   Dispatch on `github-project.fields.priority.kind:` and follow the
   matching write path from the "Set-slot dispatcher" routine in
   `skills/lib/issue.md`:
   - **`kind: number`** — validate the parsed integer against
     `[min, max]`, then call the
     `updateProjectV2ItemFieldValue` number-field template with
     `fieldId = fields.priority.id`.
   - **`kind: single-select`** — resolve the option name to an
     option ID via the case-insensitive lookup rules
     ("Name -> ID lookup rules"), then call the
     `updateProjectV2ItemFieldValue` single-select-field template
     with `fieldId = fields.priority.id` and that `optionId`.
   - **`kind: label`** — resolve the option name against
     `fields.priority.options` (flat list, case-insensitive), then
     follow the "Label-namespace update" recipe with
     `<namespace> = fields.priority.namespace` and
     `<requested> = <canonical>`. This is a `gh issue edit`
     invocation, not GraphQL.
   - **`kind: issue-field`** — resolve the option name against
     `fields.priority.options` (case-insensitive), then follow the
     **issue-field write path** from the "Set-slot dispatcher" routine
     in `skills/lib/issue.md`: check `viewerCanSetFields`, then call
     the `setIssueFieldValue` template with
     `fieldId = fields.priority.field-id` and the resolved option's
     node ID. This writes on the issue itself and does **not** depend
     on the project-item lookup from step 5 — it works even when the
     issue is not on (or there is no) project board.
   - **`kind: skip` or slot absent** — emit the slot-skipped warning
     from "Graceful degradation" in `skills/lib/issue.md` and skip.

   If the `github-project:` block is missing entirely, emit the same
   warning and skip — there is no slot configuration to dispatch on.
   (A `kind: issue-field` slot still lives under `github-project.fields`
   in repo-config even though its write does not touch the board; if
   the whole block is absent there is no slot to dispatch on.)

9. **Set size**, if `--size` resolved to a concrete value. Same
   dispatch shape as step 8, against
   `github-project.fields.size.kind:`:
   - **`kind: number`** — validate against `[min, max]`, then call
     the `updateProjectV2ItemFieldValue` number-field template with
     `fieldId = fields.size.id`.
   - **`kind: single-select`** — resolve the option name to an
     option ID, then call the `updateProjectV2ItemFieldValue`
     single-select-field template with `fieldId = fields.size.id` and
     that `optionId`.
   - **`kind: label`** — resolve the option name against
     `fields.size.options`, then follow the "Label-namespace update"
     recipe with `<namespace> = fields.size.namespace`.
   - **`kind: issue-field`** — resolve the option name against
     `fields.size.options` (case-insensitive), then follow the
     **issue-field write path** from the "Set-slot dispatcher" routine
     in `skills/lib/issue.md`: check `viewerCanSetFields`, then call
     the `setIssueFieldValue` template with
     `fieldId = fields.size.field-id` and the resolved option's node
     ID. This writes on the issue itself and does **not** depend on the
     project-item lookup from step 5 — it works even when the issue is
     not on (or there is no) project board. GitHub's native `Effort`
     field is the size analogue here; its options are `High` /
     `Medium` / `Low`, not the t-shirt buckets.
   - **`kind: skip` or slot absent** — emit the slot-skipped warning
     and skip.

   If the `github-project:` block is missing entirely, warn and skip
   as above.

10. **Set status**, if `--status` resolved to a concrete value. Same
    dispatch shape as steps 8 and 9, against
    `github-project.fields.status.kind:`. Most repos configure
    `status` as `kind: single-select`, in which case this step
    resolves the status name to an option ID via the
    case-insensitive lookup rules ("Name -> ID lookup rules") and
    calls the `updateProjectV2ItemFieldValue` single-select-field
    template with `fieldId = fields.status.id` and that `optionId`.
    The other three kinds (`number`, `label`, `skip`/absent) follow
    the same per-kind write paths as in step 8.

    If the `github-project:` block is missing entirely, warn and
    skip as above.

## Size evaluation heuristic

Step 2 of the execution chain calls into this section to pick the
`--size` prompt's recommended option. The heuristic is read off the
issue body (and title) **before** any work is done — there is no
code-walking, no `git grep`, no project-file inspection. The
recommendation is a first-cut estimate the user is free to override
in the prompt.

The heuristic is documented here (not prompt-engineered ad-hoc per
invocation) so the recommendation is reproducible across runs.

### The option set is the slot's own, not a fixed t-shirt set

The buckets named below (`XS` / `S` / `M` / `L` / `XL`) are the
**conventional** size options for a `kind: label` or
`kind: single-select` size slot, and the worked examples use them. But
the heuristic operates on **whatever options the slot actually
declares** in `fields.size.options` — it does not assume the
six-bucket t-shirt set. When the `size` slot is backed by a native
GitHub Issue Field (`kind: issue-field`, e.g. the native `Effort`
field), the slot's effective option set is the native field's own
options (`High` / `Medium` / `Low`), and the heuristic ranks and steps
across **those** three options instead.

To apply the heuristic to any option set, first establish a
**magnitude order** — the options sorted from least-work to most-work —
then run the same heuristic against that order:

- For the t-shirt set the magnitude order is the YAML order
  (`XS` < `S` < `M` < `L` < `XL`): least-work first.
- For the native `Effort` field the YAML order is
  `High`, `Medium`, `Low`, which runs most-work-first, so the
  magnitude order is its **reverse**: `Low` < `Medium` < `High`.
  Determine the direction from the option semantics (an "effort" or
  "size" magnitude), not from the raw YAML position, so "+1 step"
  always means *more* work regardless of which end the YAML lists
  first.

With the magnitude order fixed:

- The **base size** (signal 2, file count) maps onto the magnitude
  order by position: divide the file-count bands below proportionally
  across the available options. For the 3-option `Effort` scale that
  collapses to: 0–2 files → `Low`, 3–7 files → `Medium`, >7 files →
  `High`.
- A **step** (signals 3 and 4) moves one position along the magnitude
  order toward more / less work, clamped to the smallest / largest
  option — exactly as the "Combining signals" rule states, just over
  the magnitude order rather than raw YAML order.
- The **triviality / doc-only overrides** select the **least-work**
  option (the `XS` end for t-shirts, `Low` for `Effort`).
- The **median fallback** picks the middle of the magnitude order (the
  same as the YAML middle when the list is symmetric, e.g. `Medium`
  for `Effort`).

The file-count → t-shirt mapping in signal 2 below is the canonical
example for the six-bucket set; for any other option set, derive the
analogous proportional mapping over the magnitude order as described
above rather than forcing the t-shirt labels.

### Signals

Read each signal off the issue body and combine them per the
"Combining signals" rule below. None of the signals require running
code or reading files in the repo.

1. **Doc-only marker.** Title or body contains language like "rename",
   "rewrite the docs", "clarify wording", "update README", or
   "documentation"; no acceptance criterion mentions executable
   behavior. Heavy bias toward XS / S.

2. **Estimated file count.** Scan the body for explicit "Files
   affected" / "Files most likely affected" sections — `/issue-address`
   produces these in its Phase 1 analysis. Count the file paths
   listed. Mapping:
   - 0-1 files mentioned: XS
   - 2-3 files: S
   - 4-7 files: M
   - 8-15 files: L
   - >15 files: XL

   If the body has no such section, fall back to a rough count of
   file paths mentioned anywhere in the body (anything that looks
   like `path/to/file.ext` or `<dir>/<name>`).

3. **Distinct concerns / acceptance items.** Count the bullets under
   "Acceptance" / "Acceptance criteria" / numbered task lists in the
   body. Mapping:
   - 1-2 items: -1 size step (one bucket smaller)
   - 3-5 items: no adjustment
   - 6-9 items: +1 size step
   - >9 items: +2 size steps

4. **Complexity signals.** The body uses language like "refactor",
   "rewrite", "migrate", "introduce a new abstraction", "cross-cuts",
   "must touch every", "schema change", or names ≥3 distinct
   subsystems / skills / agents that all need coordinated edits. Each
   signal bumps the size up by one step (cap at +2 from this signal
   alone).

5. **Triviality signals.** Body language like "typo", "one-liner",
   "small follow-up", "drive-by", or a body shorter than ~10 lines
   with no acceptance section. Bias toward XS regardless of other
   signals.

### Combining signals

1. Start with the file-count signal (signal 2) as the base size.
2. Apply the acceptance-items adjustment (signal 3) in steps. A
   "step" for `kind: single-select` / `kind: label` / `kind: issue-field`
   slots means moving one option along the **magnitude order** (see
   "The option set is the slot's own" above), clamped to the
   smallest / largest option. For `kind: number`, a step is one
   increment along `[min, max]` in equal-thirds buckets (so a slot with
   `min: 1, max: 9` has steps of 3).
3. Apply complexity signals (signal 4) as additional upward steps.
4. Override to the **least-work option** (the start of the magnitude
   order — `XS` for the t-shirt set, `Low` for `Effort`) if the
   triviality signal (signal 5) fires.
5. Override to the least-work option, or one step above it, if the
   doc-only marker (signal 1) fires strongly (entire issue is
   documentation work) — `XS` / `S` for the t-shirt set, `Low` /
   `Medium` for `Effort`.

If the model genuinely cannot pick a size from the body (e.g. an
issue with one sentence and no other signals), it picks the **median
option** for `kind: single-select` / `kind: label` / `kind: issue-field`
(the middle of the magnitude order — for a 5-option list
`[XS, S, M, L, XL]` that's `M`; for the 3-option `Effort` field
`[High, Medium, Low]` that's `Medium`). For `kind: number`, it picks
`floor((min + max) / 2)`. This avoids biasing every "I can't tell"
toward the same default and matches the issue's intent that
`repo-config.md`'s `default:` is no longer the recommendation.

### Worked examples

- **"Fix typo in README.md"** — triviality marker + 1 file → XS.
- **"Add a new `--foo` flag to `/issue-create`"** with body listing
  `skills/issue-create/SKILL.md` and `skills/lib/issue.md` and one
  acceptance bullet — 2 files, 1 item → S - 1 step → XS (XS is the
  floor).
- **"Add interactive prompts to `/issue-create`"** (this issue,
  conceptually) — 2 files affected, ~4 acceptance items, "documented
  not prompt-engineered ad-hoc" complexity marker → S → no
  adjustment → +1 from complexity → M.
- **"Migrate the repo from CodeCommit to GitHub"** — many files,
  >15 distinct concerns, multiple subsystems → L → +2 from
  complexity → XL.

## Output

The output is a **hard checklist, not a suggestion**. The runbook is
**not complete** until every required line below has been emitted.
Each applicable field must echo **either** a concrete value **or** the
literal word `skipped` followed by a reason (`skipped: <reason>`).
Printing the URL line without all of the required field lines above it
means the skill has **not** finished its work — the URL is the *last*
line, never a substitute for the checklist.

Echo back the canonical capitalization for type and for any
single-select / label slot value (per "Name -> ID lookup rules" in
`skills/lib/issue.md`), not whatever casing the user typed.
`kind: number` slots echo the integer as-is.

### Required lines

Emit each of these whenever the stated condition holds. "Required"
means the line must appear — as a value or as `skipped: <reason>` —
before the URL.

- **`type:`** — required when `github-project.issue-types` exists in
  repo-config. Either the canonical type name (e.g. `Feature`) or
  `skipped: no issue-types map in repo-config`.
- **`priority:`** — required when `github-project.fields.priority`
  exists and is not `kind: skip`. Either the canonical value or
  `skipped: <reason>` (e.g. `skipped: slot kind: skip`,
  `skipped: flag not passed and no default`).
- **`size:`** — same shape as `priority:` (keyed on
  `github-project.fields.size`).
- **`status:`** — same shape as `priority:` (keyed on
  `github-project.fields.status`).
- **`assignee:`** — required. Either the canonical login(s) that were
  set, or `skipped: no --assignee passed and no built-in default
  applies`. Before printing this line, **post-fetch verify** (see
  below).

### Optional line

- **`parent:`** — either `#<N>` or **omitted entirely**. This is the
  one optional field: it is omitted (no `skipped:` annotation needed)
  when `--parent` was not passed.

### Assignee post-fetch verification

Before emitting the `assignee:` line, re-read the issue's assignees
from GitHub (`gh issue view <N> --json assignees --jq
'.assignees[].login'`) and compare the result to the set you intended
to assign:

- If every intended login is present, echo the canonical login(s) on
  the `assignee:` line.
- If any intended login is **missing** from the re-read set (a silent
  assignee-add failure — e.g. an invalid or non-collaborator login
  that `gh issue create --assignee` accepted without error), do
  **not** print a clean value line. Instead surface the mismatch:
  print `assignee: <set-that-landed> (requested <full-set>; <missing>
  did not land)` so the failure is visible in the output rather than
  silently lost.

(This post-fetch verification overlaps with #108, which adds the same
re-read-and-compare to `/issue-update`'s assignee path. Whichever
lands first carries the change; the other becomes a no-op.)

### Warnings

When a step was warning-skipped, print the warning line on its own
(per the catalogue in `skills/lib/issue.md`) before the URL, in
addition to the corresponding `skipped: <reason>` checklist line.

### Examples

A fully-configured issue on this repo's typical `single-select`
priority, size, and status:

```text
Created issue #1042 "Add /issue-create skill"
  type:       Feature
  priority:   P0
  size:       M
  status:     Backlog
  assignee:   edwinvoskamp
  parent:     #18

https://github.com/<owner>/<repo>/issues/1042
```

An issue in a repo whose `size` slot is intentionally `kind: skip`
and where `--status` was neither passed nor defaulted — the required
lines still appear, as `skipped: <reason>`, and `parent:` is omitted
because `--parent` was not passed:

```text
Created issue #1043 "Tidy up the create runbook"
  type:       Tech Debt
  priority:   P2
  size:       skipped: slot kind: skip
  status:     skipped: flag not passed and no default
  assignee:   edwinvoskamp

https://github.com/<owner>/<repo>/issues/1043
```

## Migration note

This skill replaces the legacy `skills/issue-add/SKILL.md`. That file
now contains a one-line pointer to this skill for muscle memory.
