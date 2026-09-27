---
name: issue-create
description: Create a new issue in this repo end-to-end (title, body, type, priority, size, status, parent, assignees, labels) in a single invocation.
---

Create a new issue with all metadata set in one shot: title, body,
issue type, parent link, priority, size, status, assignees, and
labels — in the current repo, or with `--repo` in another. The issue
is fully configured before its URL is printed.

## Invocation

```text
/issue-create --title "..." --body-file PATH
              [--type T] [--labels a,b,c] [--assignee u1,u2]
              [--parent N]
              [--priority V] [--size V] [--status S]
              [--repo owner/repo]
```

- `--title` (required): issue title.
- `--body-file` (required): a file whose contents become the body
  verbatim, so long Markdown survives the CLI unchanged.
- `--type` (optional): issue type name, matched case-insensitively
  against the `issue-types:` map. Default: the map's `default:`, then
  `Feature`.
- `--labels` (optional): comma-separated label names. Default: none.
- `--assignee` (optional): comma-separated GitHub logins. Default:
  `default-assignee` from the repo-level user-config, then the
  user-global one (`skills/lib/user-config.md`), then the
  authenticated GitHub user. A user-config file that exists but
  predates schema-version `1` aborts rather than being skipped.
- `--parent` (optional): the parent's issue number, in the repo the
  issue is filed in. The new issue becomes its sub-issue.
- `--priority`, `--size`, `--status` (optional): one value per slot,
  whose meaning depends on the slot's `kind:` in repo-config — an
  integer within `min`/`max` for `kind: number`, an option name
  matched case-insensitively for `kind: single-select`,
  `kind: issue-field` and `kind: label`. Run `/issue-field-options`
  to see what a slot accepts. A slot with no value resolves through
  Step 2 below, then the slot's `default:`; there is no built-in
  default.
- `--repo` (optional): file the issue in `owner/repo` instead of the
  current repo. The script reads that repo's `.issues/repo-config.md`
  from its default branch and uses it exactly as a local create uses
  the local one. A target with no repo-config gets a plain issue —
  title, body, labels, and any `--assignee` or `--parent` passed — and
  one output line saying the project fields were skipped. A target
  whose repo-config is at an unsupported schema-version aborts before
  anything is filed. The repo-level user-config is this repo's, so a
  cross-repo default assignee comes from the user-global one only.

## Execution

1. **Collect the flags the user gave.** Nothing is resolved here that
   the script resolves itself.

2. **Ask for the slot values the user did not give.** For each slot in
   `priority`, `size`, `status` whose flag was not passed, and which
   `/issue-field-options <slot>` does not report as unconfigured, ask
   the user with `AskUserQuestion` — one question per slot, or up to
   four combined in one call. The options are the slot's option names
   in configured order; a `kind: number` slot gets an open-ended
   integer prompt in `[min, max]`. The first option is the
   recommendation and carries `(Recommended)`:

   - **size** — evaluate the issue body per "Size evaluation
     heuristic" below and put that pick first; the rest follow in
     configured order.
   - **priority**, **status** — the slot's `default:` from repo-config,
     echoed back first. With no `default:`, recommend nothing and keep
     the configured order.

   An answer resolves the slot exactly as if its flag had been passed.
   An unanswered prompt — a timeout, or a non-interactive caller —
   leaves the flag off, so the script falls back to the slot's
   `default:`. Skip this step when every slot was passed or is
   unconfigured. This step is create-time only; the set-slot verbs
   take an explicit value and never prompt.

3. **Run the script.** Run `issue-create`, which this plugin puts on
   `PATH`, with the Bash tool from inside the repo's working tree,
   passing the flags from steps 1 and 2 and no empty values:

   ```bash
   issue-create --title "<title>" --body-file <path> [--type <T>] [--labels <a,b>] \
     [--assignee <u1,u2>] [--parent <N>] [--priority <V>] [--size <V>] [--status <S>] [--repo <owner/repo>]
   ```

   The script validates every value against repo-config before it
   files anything, so a bad type or slot value aborts with nothing
   created. It then creates the issue, adds it to the configured
   project board, and sets the type, parent and slots, re-reading each
   write and exiting non-zero when a re-read does not show it. When a
   step fails after the issue exists, stderr names the issue, its URL,
   and the steps that completed; nothing is rolled back.

4. **Report.** Print the script's stdout as it stands. On a non-zero
   exit, relay its stderr verbatim — including which steps completed
   when the issue was already created.

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
declares** in `fields.size.options` — it does not assume the t-shirt
set. When the `size` slot is backed by a native GitHub Issue Field
(`kind: issue-field`, e.g. the native `Effort` field), the slot's
effective option set is the native field's own options (`High` /
`Medium` / `Low`), and the heuristic ranks and steps across **those**
options instead.

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
example for the t-shirt set; for any other option set, derive the
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

2. **Estimated file count.** Find the body's
   `## Files affected (floor)` section — that heading literal, not a
   substring of it — and count its bullets. Mapping:
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
   "The option set is the slot's own, not a fixed t-shirt set" above),
   clamped to the smallest / largest option. For `kind: number`, a
   step is one increment along `[min, max]` in equal-thirds buckets
   (so a slot with `min: 1, max: 9` has steps of 3).
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

The output is a checklist: each line shows **either** a concrete value
**or** `skipped: <reason>`, and the URL is the last line, never a
substitute for the checklist. Values carry the config's capitalization,
not the caller's.

```text
Created issue #1042 "Add /issue-create skill"
  type:       Feature
  priority:   High
  size:       M
  status:     Backlog
  assignee:   octocat
  parent:     #18

https://github.com/<owner>/<repo>/issues/1042
```

- `type:`, `priority:`, `size:`, `status:` and `assignee:` always
  appear. The skip reasons are `slot kind: skip`,
  `slot absent from fields:`, `flag not passed and no default`,
  `no github-project block in repo-config`,
  `no issue-types map in repo-config`, and
  `target repo has no repo-config`.
- `parent:` appears only when `--parent` was passed.
- An issue filed in another repo prints as `owner/repo#N`.
- The assignee line is the re-read set. When a requested login did not
  land — GitHub accepts an invalid login on create without an error —
  it reads `<landed> (requested <all>; <missing> did not land)` and the
  script exits non-zero after printing the checklist.

A flag skipped for missing project metadata also prints one warning
line before the URL, for `--type`, `--priority`, `--size` and
`--status` in that order, whether or not the flag was passed. The
warning shapes:

```text
warning: slot 'size' is kind: skip in repo-config.md; skipping --size.
warning: slot 'status' is missing from fields: in repo-config.md; skipping --status.
warning: no `github-project:` block in `repo-config.md`; skipping `--priority`. Run `/repo-config` to add it.
```

A `--repo` target without a repo-config prints, instead of warnings:

```text
note: project fields skipped: `<owner>/<repo>` has no `.issues/repo-config.md`.
```

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` — in
the current repo, or in a `--repo` target — it exits non-zero with its
fixed Jira message before filing anything; follow
`skills/lib/issue.md` → "Jira backend" → "Create" instead, running
Step 2's prompts the same way and producing the same checklist.
