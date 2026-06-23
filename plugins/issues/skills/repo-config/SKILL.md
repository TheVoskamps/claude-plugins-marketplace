---
name: repo-config
description: Interactively create or fully rewrite `.claude/rules/repo-config.md` by interviewing the user about VCS, issue tracker, and (for GitHub repos) the associated Project V2 board.
---

You are running the `/repo-config` skill. Your job is to create the
**target repo's** `.claude/rules/repo-config.md` from scratch, or to
fully rewrite it when it already exists, by interviewing the user.
This file is read by `/issue-address` and the `issue-developer`,
`issue-fixer`, `doc-updater`, and `pr-reviewer` subagents at the
start of every run, so it must be present and well formed before
any of those flows will work.

`/repo-config` does **not** merge with the existing file or rewrite
parts of it in place. When the file already exists, the user confirms
an overwrite up front in Step 2.5; the final write in Step 5 replaces
the entire file with content built from the user's answers in the
current run. However, the existing file is **not** discarded before
the interview: its current values are parsed in Step 2 and become the
recommended default for each interview question, so an
accept-everything run reproduces the prior file (plus any fields the
schema has added since). When the file does not exist, the recommended
option for every interview question is the built-in default baked into
this skill. If the user wants the prior file's contents preserved
verbatim, they decline the Step 2.5 overwrite prompt and the file is
left untouched.

Follow the steps below in order. Do not write the file until the
user has explicitly approved the proposed content.

---

## Step 1: Pre-flight

Verify you are inside a git working tree by running:

```bash
git rev-parse --show-toplevel
```

If the command fails (non-zero exit, or stderr indicates "not a git
repository"), abort with a clear message:

> `/repo-config` must be run from inside a git repository. The current
> directory is not a git working tree.

Do not continue past this step on failure.

Treat the path printed by `git rev-parse --show-toplevel` as the
**repo root** for the rest of the skill — the skill writes
`<repo-root>/.claude/rules/repo-config.md` regardless of which
subdirectory of the worktree the user invoked the command from. Do
**not** string-compare the printed path against the user's current
working directory: `git rev-parse --show-toplevel` returns a real
path, while the user's cwd may traverse symlinks (for example, on
macOS `/tmp` resolves to `/private/tmp`, and project trees frequently
sit under symlinked workspace directories). A naive equality check
would mis-flag a legitimate repo as "not a repo root".

## Step 2: Detect existing config

Check whether `.claude/rules/repo-config.md` already exists in the
target repo (relative to the repo root from Step 1).

`/repo-config` is a **full-rewrite** tool: the final write in Step 5
replaces the entire file with content assembled from the user's
answers in this run, and it does not preserve the existing body
verbatim. But the existing file is treated as a **source of
recommended defaults** for the interview — its current values are
carried over so an accept-everything run reproduces them.

- **If it exists**: read the file's full contents into memory. Use
  the bytes for two purposes:
  1. Display to the user in Step 2.5 before they decide whether to
     overwrite.
  2. Parse for carry-over defaults. Parse the YAML front-matter into
     per-field values, and parse whichever **tracker-metadata block**
     the existing file carries (or note a skip marker) for the
     downstream per-slot recommendations: the `github-project:` block
     when present, feeding the Step 3b per-slot recommendations, and
     the `jira:` block when present, feeding the Step 3c per-slot
     recommendations. The two are mutually exclusive (selected by the
     `issues:` value), so at most one is present; parse the one that
     is. Each recognized field's parsed value becomes the recommended
     (first, `(Recommended)`-suffixed) option for its interview
     question in Step 3 (and Step 3b or Step 3c). A field present in
     the file but unrecognized by the current schema is ignored,
     not surfaced. A field absent or unparseable falls back to the
     built-in default. Do **not** validate parsed values against the
     live project — carry-over is convenience, not authority (see
     Step 3b).
- **If it does not exist**: nothing to read; the recommended option
  for every interview question is the **built-in default** baked into
  this skill. Proceed straight to Step 3.

A file whose `schema-version` is **below** the current version is
still parsed for carry-over: the version check is a *reader* concern,
and `/repo-config` is the *writer* — it treats any existing file as a
source of defaults regardless of its declared version.

The built-in front-matter defaults (used when the file is absent, or
per-field when a field is missing or unparseable) are:

- `source-control`: `GitHub`
- `issues`: `GitHub`
- `issue-link-prefix`: `#`
- `default-issue-source-branch`: `main`
- `default-pr-target-branch`: `main`
- `issue-branch-naming-prefix`: `none`

`schema-version` is **not** in this list — it is a write-time
constant (currently `7`) baked into this skill, not an interview
question, and it is never carried over from the existing file. See
`skills/lib/repo-config.md` for the reader contract that consumes it.

Also, before Step 3, gather the local branch list with
`git branch --format='%(refname:short)'` so you can offer real
branches as options for the two branch fields.

## Step 2.5: Confirm overwrite (existing file only)

This step runs **only if the file existed** in Step 2. If the file
did not exist, skip directly to Step 3.

`/repo-config` rewrites the entire file from the user's answers in
this run. Before running the interview — which is wasted effort if
the user actually wanted to inspect, not overwrite — confirm intent
with a single overwrite prompt.

1. Display the **full current contents** of
   `.claude/rules/repo-config.md` to the user — front-matter and
   body, byte-for-byte as read from disk. Do not paraphrase or
   summarize; the user is deciding whether to discard the real file.
2. Ask via `AskUserQuestion`: "This will replace
   `.claude/rules/repo-config.md` with a fresh file built from your
   answers — continue?" with options `Yes` and `No`.
3. **On `No`**: end the skill cleanly. Report that the file was
   left unchanged at `<repo-root>/.claude/rules/repo-config.md`.
   Do **not** enter the interview. Do **not** write or edit
   anything. Skip Steps 3 through 6.
4. **On `Yes`**: continue into Step 3. Each interview question
   recommends the value carried over from the existing file (parsed
   in Step 2) when one is present and parseable, falling back to the
   **built-in default** otherwise.

## Step 3: Interview

Use the `AskUserQuestion` tool to interview the user. Ask the six
fields **in the order below**. Group them into multiple
`AskUserQuestion` calls as feels natural — the tool allows 1–4
questions per call, and exact grouping is left to your judgment.

For every question:

- The **first option** must be the recommended value, with its label
  suffixed `(Recommended)`. The recommendation is the value carried
  over from the existing file (parsed in Step 2) when one is present
  and parseable for this field; otherwise it is the built-in default
  for the field as listed below.
- Always include an "Other" option so the user can type a custom
  value.
- Keep option labels short; put any explanation in the question
  text.

For each field below, "carry-over value" means the value parsed from
the existing file in Step 2 for that field, if present and parseable.
When a carry-over value exists, recommend it; otherwise recommend the
built-in default named in the field's description.

The six fields, in order:

1. **`source-control`** — choose `GitHub` or `CodeCommit`. Recommend
   the carry-over value; built-in default `GitHub`.
2. **`issues`** — choose `GitHub` or `Jira`. Recommend the carry-over
   value; built-in default `GitHub`.
3. **`issue-link-prefix`** — the literal string concatenated with
   the issue number in commit messages and PR bodies. Recommend the
   carry-over value if present and parseable. Otherwise the
   recommended value depends on the **just-chosen** value of `issues`
   (field 2):
   - If the user picked `GitHub` for `issues`, recommend `#`
     (`#123` is the only sensible GitHub form).
   - If the user picked `Jira` for `issues`, do not pre-recommend a
     value — prompt the user to enter the Jira project key plus a
     trailing dash via "Other" (e.g. `SET-`, `PROJ-`).
4. **`default-issue-source-branch`** — branch that new issue work
   branches FROM. Offer the local branches you gathered in Step 2
   as options, plus "Other" for any branch name. Recommend the
   carry-over value if present in the local branch list; else
   recommend `main` if it is present; otherwise present the gathered
   branches without a recommendation and require the user to pick.
   (If the carry-over branch is no longer a local branch, still offer
   it via "Other" — do not validate it against the remote.)
5. **`default-pr-target-branch`** — branch that issue PRs target.
   Same option set as field 4. Recommend the carry-over value if
   present; else recommend whatever the user just chose for
   `default-issue-source-branch` (often the same).
6. **`issue-branch-naming-prefix`** — branch naming style.
   Choose one of `none`, `initials`, `name`. Recommend the carry-over
   value; built-in default `none`.

Do not validate that the chosen branches actually exist on the
remote; that is out of scope for this skill.

## Step 3b: GitHub Project interview (conditional)

This step runs **only when the just-chosen `issues` value is `GitHub`**.
If `issues` is `Jira`, skip this step entirely and run **Step 3c**
(the Jira interview) instead. If `issues` is anything other than
`GitHub` or `Jira`, skip both Step 3b and Step 3c and proceed to
Step 4. The `github-project:` block is a GitHub-only concept; the
Jira repo gets the parallel `jira:` block built in Step 3c.

The purpose of this step is to populate (or intentionally omit) the
`github-project:` body block defined in `skills/lib/issue.md`. The
block carries project node IDs, status option IDs, and issue type
IDs so the `/issue-*` commands can translate human-readable names
into the GraphQL IDs the GitHub API requires.

Because `/repo-config` is a full-rewrite tool (see Step 2), this
step re-runs auto-discovery against the live project rather than
copying the prior block wholesale. But where the existing file
already recorded a choice — which slot a field maps to, which option
is the default — that prior choice is offered as the recommended
answer (parsed in Step 2), so an accept-everything run reproduces the
block. The carry-over is **not** live-validated: if the user renamed
a slot or removed an option in the project since the file was last
written, recommending the now-stale value is fine — the user knows
what they are doing and will pick the right answer.

### 3b.1 — Decide whether to populate

Use `AskUserQuestion` to ask the user how to handle the
`github-project:` block. Offer two options:

- **Populate** — run auto-discovery (Steps 3b.2 – 3b.5) and build the
  block, using the existing file's parsed values as per-slot
  recommendations.
- **Skip** — do not add a block. Write a skip marker instead with a
  short reason captured via "Other". Skip the rest of Step 3b
  except 3b.6 (which writes the marker).

Mark the recommended option per the carry-over from Step 2:

- If the existing file had a `github-project:` block, recommend
  **Populate**.
- If the existing file had a skip marker, recommend **Skip**, and
  pre-fill the marker's prior reason as the recommended free-text
  reason (the user can re-enter it verbatim or change it).
- If the file did not exist (or had neither), recommend **Populate**.

There is no `Keep` / `Update` option in this skill: the block is
always rebuilt from this run's answers (seeded by carry-over
recommendations), not copied verbatim. If the user wants the previous
block back byte-for-byte without re-confirming each slot, they should
answer `No` at the Step 2.5 overwrite prompt and the file stays
untouched.

### 3b.2 — Pick the owner and project

Auto-discover the repo's owner from the local remote:

```bash
git remote get-url origin
```

Parse the `owner/repo` from the URL (both SSH and HTTPS forms; strip
any trailing `.git`). The owner is typically a GitHub organization but
may be a user; both work as `--owner` arguments to `gh project list`.

List accessible projects for that owner:

```bash
gh project list --owner <owner> --format json
```

Parse the JSON. The shape is `{ projects: [ { number, title, id,
... } ] }`. Each project's `id` is the ProjectV2 node ID (`PVT_...`),
which is the literal value that goes into `project-id`.

Show the user the discovered projects with their numbers and titles,
plus options:

- One option per discovered project (label: `<number>: <title>`).
- `Other` to type a project number by hand (useful when the project
  belongs to an upstream org `gh project list` can't see, or when the
  list is truncated by `--limit`).
- `Skip` to abandon the github-project block. On `Skip`, jump to
  3b.6 to record the skip marker.

Common failure modes to handle gracefully:

- `gh project list` exits non-zero or returns an empty list. Surface
  the error/empty result and offer `Other` (manual entry) or `Skip`.
- The user picks `Other` and enters a project number. Resolve its
  node ID by running `gh project view <number> --owner <owner>
  --format json` and reading `.id` (also `.title` for the summary).

If the project node ID does not start with `PVT_`, treat the response
as invalid and let the user retry or skip.

Record:

- `project-id` — the `PVT_...` node ID.
- The numeric project number and title (for the summary in Step 6;
  these are not written to the file).

### 3b.3 — Discover fields (per-slot interview)

This step runs the same generic interview once per conceptually-standard
slot. The slot list is hardcoded: `status`, `priority`, `size`. Making
the slot list user-configurable is out of scope; a repo that wants a
different slot (e.g. `effort`) hand-edits the block after the wizard
runs, per the schema in `skills/lib/issue.md`.

#### 3b.3.a — Enumerate project fields once

Before asking about any slot, enumerate the project's fields a single
time and keep the result in memory for the per-slot loop below. The
goal is one unified list of `(id, name, kind, options?)` tuples where
`kind` is one of `number` or `single-select` — the only two kinds that
correspond to project fields. Iteration, text, date, and built-in
fields (Title, Assignees, Labels, Milestone, etc.) are filtered out:
they are not surfaceable as slot backings.

Detecting which fields are number-typed is the tricky part. The
`gh project field-list` JSON returns `type == "ProjectV2Field"` for
**every** non-single-select, non-iteration field — Title, Assignees,
Labels, Milestone, Repository, Reviewers, Parent issue, Sub-issues
progress, Estimate, Start date, Target date, Priority, and any
custom text/number/date field the user has added. The `type`
discriminator alone is not enough to identify a number field. Use the
GraphQL `dataType` probe as the canonical discriminator:

```bash
gh api graphql -F number=<project-number> -F owner=<owner> -f query='
query($owner: String!, $number: Int!) {
  # Replace `organization(login:)` with `user(login:)` if the owner
  # is a user account, not an organization.
  organization(login: $owner) {
    projectV2(number: $number) {
      fields(first: 100) {
        nodes {
          ... on ProjectV2Field             { id name dataType }
          ... on ProjectV2SingleSelectField { id name dataType
            options { id name } }
          ... on ProjectV2IterationField    { id name dataType }
        }
      }
    }
  }
}'
```

`dataType` is one of `NUMBER`, `TEXT`, `DATE`, `SINGLE_SELECT`,
`ITERATION`, `TITLE`, `ASSIGNEES`, `LABELS`, `MILESTONE`,
`REPOSITORY`, `REVIEWERS`, `LINKED_PULL_REQUESTS`, `TRACKS`,
`TRACKED_BY`.

From the response, build two lists for the per-slot loop:

- **Number fields**: every node with `dataType == "NUMBER"`. Capture
  `id` (`PVTF_...`) and `name`. No options.
- **Single-select fields**: every node with `dataType == "SINGLE_SELECT"`.
  Capture `id` (`PVTSSF_...`), `name`, and the full `options` list
  (each `{ id, name }`). The option IDs are short hex strings, not
  `PVT_*`-prefixed node IDs — that is correct for single-select option
  IDs in ProjectV2.

`gh project field-list <project-number> --owner <owner> --format json`
also works as a fallback for the name/type pass when the GraphQL probe
is unavailable, but it cannot distinguish number from text/date and
does not expose option IDs, so prefer the GraphQL form when both are
available.

##### Enumerate native Issue Fields (for the `issue-field` kind)

Separately from the project fields above, enumerate the repo's
**native GitHub Issue Fields** — the preview feature that attaches
ProjectV2-style fields directly to issues, independent of any project
board. These back the `kind: issue-field` slot (see "Field kinds" in
`skills/lib/issue.md`). Query the repository, not the project:

```bash
gh api graphql -F owner=<owner> -F repo=<repo> -f query='
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    issueFields(first: 20) {
      nodes {
        __typename
        ... on IssueFieldCommon { name dataType }
        ... on IssueFieldSingleSelect {
          id
          options { id name }
        }
      }
    }
  }
}'
```

The `kind: issue-field` backing consumes the **single-select** native
fields only: keep every node whose `__typename` is
`IssueFieldSingleSelect` (`dataType == SINGLE_SELECT`), capturing its
`id` (`IFSS_...`), `name`, and the full `options` list (each
`{ id, name }`, with `IFSSO_...` option IDs). GitHub ships two such
single-select native fields today — `Priority` (options `Urgent` /
`High` / `Medium` / `Low`), the `priority`-slot backing, and `Effort`
(options `High` / `Medium` / `Low`), the `size`-slot backing — so both
are surfaced by this enumeration and offered to the matching slot in
the per-slot loop. Filter out the `IssueFieldDate` /
`IssueFieldNumber` / `IssueFieldText` / `IssueFieldMultiSelect` nodes —
those data-types have no slot kind yet.

If `issueFields` is `null` or empty (the preview is not enabled for
this repo, or no native fields are defined), there are simply no
`issue-field` options to offer in the per-slot loop — skip that
option. The query failing outright (e.g. the field is not in the
schema for this `gh`/GHES version) is also non-fatal: proceed without
the `issue-field` option and note it to the user.

#### 3b.3.b — Per-slot interview

**Carry-over takes precedence over the discovery chains below.** When
the existing file (parsed in Step 2) recorded this slot, recommend the
kind it used (`number`, `single-select`, `issue-field`, `label`, or
`skip`) by matching it to the corresponding enumerated option — e.g. a
slot the file recorded as `single-select` with field id `X` recommends
the enumerated single-select field whose id is `X` (fall back to
matching by field name if the id is no longer enumerated; if neither
matches, fall through to the discovery chain). Do **not** live-validate
the carried-over kind against the project — recommending a stale choice
is acceptable per Step 3b's intro. Only when the file recorded nothing
for this slot (or the file did not exist) do the discovery chains
below choose the recommendation.

Run the **same** four-step procedure once per slot, in this order:

1. **`status`** — strongly recommended. Discovery-recommendation chain
   for which kind to pick (used when there is no carry-over): a
   single-select field named `Status` (case-insensitive) if exactly
   one such field is enumerated.
2. **`priority`** — optional. Discovery-recommendation chain for
   which kind to pick (used when there is no carry-over), in this
   order:
   1. A **native Issue Field** named `Priority` (case-insensitive)
      from the native-field enumeration above — the `kind:
      issue-field` backing. If exactly one such single-select native
      field exists, recommend it. It is preferred over the project
      fields below because native fields are not tied to a project
      board (the issue's stated selling point of this kind).
   2. Otherwise a **number** field named `Priority` or `Importance`
      (case-insensitive — `Priority` matches GitHub's native field
      name; `Importance` is kept so boards that still use the older
      name resolve). If exactly one such field exists, recommend it.
   3. Otherwise a **single-select** project field with the same name.
      If exactly one such field exists, recommend it.
   4. Otherwise no auto-recommendation — present the full option set
      and let the user pick.

   If multiple fields match at the same tier (e.g. both a `Priority`
   and an `Importance` number field), present all of them as
   options and let the user pick; do not silently prefer one.
3. **`size`** — optional. Discovery-recommendation chain for which
   kind to pick (used when there is no carry-over), in this order:
   1. A **native Issue Field** named `Effort` or `Size`
      (case-insensitive) from the native-field enumeration above — the
      `kind: issue-field` backing. `Effort` is GitHub's native
      size-analogue field (`dataType: SINGLE_SELECT`, options `High` /
      `Medium` / `Low`), the size-slot counterpart of the native
      `Priority` field. If exactly one such single-select native field
      exists, recommend it; it is preferred over the project fields
      below because native fields are not tied to a project board.
   2. Otherwise a **single-select** project field named `Size` or
      `T-Shirt` (case-insensitive). If exactly one such field exists,
      recommend it.
   3. Otherwise a **number** field with the same name. If exactly one
      such field exists, recommend it.
   4. Otherwise recommend `kind: label` with namespace `size:` (the
      built-in fallback for repos with no project field for size).

   If multiple fields match at the same tier (e.g. both `Size` and
   `T-Shirt`), present them as options and let the user pick — no
   auto-recommendation.

   Note the slot keeps its name (`size`) even when backed by the
   native `Effort` field — "size" is the clearer term in this tooling,
   so only a new backing kind is added, not a rename. When `size` is
   backed by `Effort`, the slot's effective options become the native
   field's own (`High` / `Medium` / `Low`), captured verbatim in
   Step 3 below — **not** the six-bucket t-shirt set.

For every slot, the procedure is:

##### Step 1 — Show every option the user could pick

Present, in one `AskUserQuestion` call, the full set of choices for
this slot:

- One option per enumerated **number field** from 3b.3.a (label:
  `<name> (number field)`).
- One option per enumerated **single-select field**, with its option
  list shown inline so the user can see what they would be choosing
  (label: `<name> (single-select: opt1, opt2, opt3, ...)`). If the
  inline list would overflow the question UI, truncate with `, ...`
  after the first few — the user is selecting the field, not the
  option, so a partial list is enough to disambiguate.
- One option per enumerated **native Issue Field** (from the
  native-field enumeration in 3b.3.a), with its option list shown
  inline (label: `<name> (issue field: opt1, opt2, ...)`). This kind
  corresponds to `kind: issue-field` in the rendered block. Offered
  only when at least one single-select native field was enumerated;
  most relevant for the `priority` slot (GitHub's native `Priority`
  field), but presented for any slot so a repo can back e.g. `size`
  with a native field too.
- One option for **labels**: `As labels (with namespace prefix)` —
  independent of project fields. This kind corresponds to
  `kind: label` in the rendered block.
- One option for **skip**: `None / skip` — slot stays unconfigured
  and is rendered as `kind: skip`. Per `skills/lib/issue.md`'s "Field
  kinds" section, an emitted `kind: skip` and a slot-absent entry are
  intentionally equivalent in verb behavior; the wizard always emits
  `kind: skip` for visibility. The slot-absent path only occurs when
  the user never reached the per-slot interview at all (e.g. they
  chose `Skip` at the block level in Step 3b.1).

Mark the recommended choice with `(Recommended)` in its label — the
carried-over kind if the file recorded one for this slot, else per the
discovery chain above. For `status`, when there is no carry-over and
no `Status`-named single-select field exists, fall back to
recommending the first single-select field, then `None / skip` as a
last resort — status is strongly recommended but not enforced.

##### Step 2 — Ask the user which to use

Use the option set from Step 1 directly. There is no slot-specific
override; the user picks one of the enumerated kinds.

##### Step 3 — Follow up based on the user's pick

Dispatch on the chosen kind:

In every case below, when the existing file (parsed in Step 2)
recorded this slot with the **same kind** the user just picked,
recommend that slot's carried-over values for the follow-up prompts
(`default`, `min`, `max`, namespace, option list). Carry-over is not
live-validated. When there is no carry-over for the slot, or the user
picked a different kind than the file recorded, use the per-kind
recommendation noted below.

- **Number field** (`kind: number`):
  - Capture the field `id` (`PVTF_...`) from the enumeration.
  - Ask for `default` (integer or float). Recommend the carried-over
    `default` if present; otherwise no built-in recommendation — the
    user owns the value.
  - Ask for `min` (integer or float). Recommend the carried-over
    `min` if present; otherwise no built-in recommendation — the user
    owns the range.
  - Ask for `max` (integer or float). Recommend the carried-over
    `max` if present; otherwise no built-in recommendation — the user
    owns the range.

- **Single-select field** (`kind: single-select`):
  - Capture the field `id` (`PVTSSF_...`) and the full option
    name→id map from the enumeration.
  - Ask which option should be the **default** for new issues.
    Recommend the carried-over `default` option if present in the
    enumerated option list; otherwise use the slot-aware chain
    (see "Default-option recommendation" below).
  - Always include an `Other` choice to free-type one of the
    enumerated option names.

- **Native Issue Field** (`kind: issue-field`):
  - Capture the native field's node `id` (`IFSS_...`) under
    `field-id:`, its `name` under `field-name:`, `data-type:
    single-select`, and the full option name→id map (option `IFSSO_...`
    IDs) from the native-field enumeration in 3b.3.a.
  - Ask which option should be the **default** for new issues.
    Recommend the carried-over `default` option if present in the
    enumerated option list; otherwise use the slot-aware chain
    (see "Default-option recommendation" below). For GitHub's native
    `Priority` field the options are `Urgent`, `High`, `Medium`,
    `Low`; for the native `Effort` field — the `size`-slot backing —
    they are `High`, `Medium`, `Low`. Always include an `Other`
    choice to free-type one of the enumerated option names.
  - This kind is single-select-only for now; the other native
    data-types (date, number, text, multi-select) are out of scope.

- **Labels** (`kind: label`):
  - Ask for the **namespace prefix**. Recommend the carried-over
    `namespace` if present; otherwise `<slot>:` (e.g. `size:` for the
    `size` slot). Free-text via `Other` for any other value; trailing
    colon is conventional but not enforced by the wizard.
  - Ask for the **option list** as a comma-separated string (e.g.
    `XS, S, M, L, XL`). Recommend the carried-over option list if
    present; otherwise no built-in recommendation — the user owns the
    list. Split on commas, trim whitespace from each entry; reject
    empty entries.
  - Ask for the **default** option (must be one of the entered
    options, case-insensitive match against the list). Recommend the
    carried-over `default` if present in the entered list; otherwise
    use the slot-aware chain (see "Default-option recommendation"
    below).
  - No field `id` is captured — labels are not project fields and
    the label name is its own identifier.

- **Skip** (`kind: skip`):
  - Nothing to capture beyond `kind: skip`. The slot is explicitly
    declared as unused. Verbs that target the slot warn and exit
    zero per the "Field kinds" section of `skills/lib/issue.md`.
  - For the `status` slot specifically, `Skip` is allowed but
    discouraged — surface a brief note to the user that
    `/issue-set-status` and the `--status` flag will warn-and-skip,
    then accept the user's choice without re-prompting.

##### Default-option recommendation (single-select, issue-field, label)

When no carried-over `default` is available, the wizard recommends a
default by this slot-aware chain. This is only the *recommended*
prompt value — the user owns the final choice — but the recommendation
should be sensible rather than blindly the first YAML option, because
an option set whose YAML order runs most-work-first (e.g. the native
`Effort` field's `High`, `Medium`, `Low`) would otherwise default a
`size` slot to its **most-work** option.

- **`status` slot**: `Backlog` if present (case-insensitive),
  otherwise the first option in the list. (Status options have no
  magnitude; first-in-list is the natural "new issue" state.)
- **`size` slot**: the **least-work option** along the slot's
  *magnitude order* (least-work → most-work), not the first YAML
  option. Establish the magnitude order from the option semantics
  exactly as the size heuristic does (see "The option set is the
  slot's own" in `skills/issue-create/SKILL.md`): for the t-shirt set
  `XS, S, M, L, XL` the YAML order already runs least-work-first, so
  the least-work option is `XS` (the first entry); for the native
  `Effort` field `High, Medium, Low` the magnitude order is the
  **reverse**, so the least-work option is `Low` (the last entry), not
  `High`. Recommending the middle option (`M` / `Medium`) is an
  acceptable alternative when a least-work default would skew new
  issues too small — what must be avoided is defaulting `size` to the
  most-work option.
- **Any other slot** (e.g. `priority`): the first option in the list.
  Priority option sets are conventionally authored most-important-first
  (`P0`, `P1`, …; `Urgent`, `High`, …) and the first entry is the
  intended high-salience default, so this preserves the existing
  priority-slot behavior.

##### Step 4 — Defer rendering to 3b.5

Hold the captured per-slot state in memory. Step 3b.5 assembles all
slots into the final YAML block once the loop finishes; do not write
or edit the file from inside this loop.

### 3b.4 — Discover issue types

GitHub Issue Types are an org-level (and now repo-scoped) enum. There
is no `gh issue-type` command yet; query via GraphQL:

```bash
gh api graphql -F owner=<owner> -F repo=<repo> -f query='
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    issueTypes(first: 50) {
      nodes { id name isEnabled }
    }
  }
}'
```

Filter to `isEnabled: true`. Each enabled type contributes
`<Name>: <id>` to the `issue-types:` map (preserve the capitalization
GitHub returns). Skip types that are disabled.

If the query returns an empty list or the field is `null` (older repos
without issue types enabled), ask the user whether to:

- `Skip issue-types` — omit the `issue-types:` sub-block entirely.
- `Other` — manually enter `Name: IT_...` pairs.

Ask the user which type should be the **default**. Recommend the
carried-over `issue-types.default` (parsed in Step 2) if present in
the enumerated list; otherwise, in order: `Feature` (if present,
case-insensitive), then the first type in the list. Include `Other`
for free-type.

### 3b.5 — Assemble the proposed block

From the captured per-slot state in 3b.3.b and the issue-types map in
3b.4, render the YAML block that will be written to the file. Use the
exact indentation and key order shown below (matching the schema in
`skills/lib/issue.md`). Every populated slot under `fields:` carries
its `kind:` discriminator (`number`, `single-select`, `issue-field`,
`label`, or `skip`) — there is no implicit default and no
backwards-compat shim for the old `type:` shape.

The renderer is purely a function of the captured state — it never
invents defaults or substitutes built-in fallbacks for kind-specific
keys. Every key in the rendered block traces back to a value the user
either supplied directly (via "Other") or selected from an enumerated
option in 3b.3.b or 3b.4.

#### Per-kind render shapes

For each populated slot, emit one of the following shapes based on the
slot's captured `kind`:

- **`kind: number`** — emit `kind`, `id`, `default`, `min`, `max`:

  ```yaml
  <slot-name>:
    kind: number
    id: <field-id>
    default: <number>
    min: <number>
    max: <number>
  ```

- **`kind: single-select`** — emit `kind`, `id`, `default`, and the
  option name→id map:

  ```yaml
  <slot-name>:
    kind: single-select
    id: <field-id>
    default: <option-name>
    options:
      <Option Name>: <option-id>
      ...
  ```

- **`kind: issue-field`** — emit `kind`, `data-type`, `field-id`,
  `field-name`, `default`, and the option name→id map. The IDs are
  native-field IDs (`IFSS_...` for the field, `IFSSO_...` for each
  option), not project field/option IDs:

  ```yaml
  <slot-name>:
    kind: issue-field
    data-type: single-select
    field-id: <IFSS_...>
    field-name: <Field Name>
    default: <option-name>
    options:
      <Option Name>: <IFSSO_...>
      ...
  ```

- **`kind: label`** — emit `kind`, `namespace`, `default`, and the
  flat option list. No `id` (labels are not project fields). The
  `namespace` value is double-quoted because trailing-colon strings
  like `size:` would otherwise be interpreted as a YAML mapping key:

  ```yaml
  <slot-name>:
    kind: label
    namespace: "<namespace>"
    default: <option-name>
    options: [<opt1>, <opt2>, ...]
  ```

- **`kind: skip`** — emit `kind: skip` and nothing else:

  ```yaml
  <slot-name>:
    kind: skip
  ```

#### Full-block shape

The assembled block looks like:

```yaml
github-project:
  project-id: <project-id>
  fields:
    status:
      <per-kind shape from above>
    priority:
      <per-kind shape from above>
    size:
      <per-kind shape from above>
  issue-types:
    default: <Type Name>
    <Type Name>: <type-id>
    ...
```

Slot order under `fields:` is fixed: `status`, then `priority`,
then `size`. Because `/repo-config` is a full-rewrite tool, the
emitted block is exactly what this run's auto-discovery produced —
any hand-edited slot the wizard doesn't know about (e.g. a
user-added `effort` slot) is dropped. Users who want
to preserve hand-edited slots should decline the Step 2.5 overwrite
prompt and hand-edit instead.

#### Conditional rendering rules

- A populated slot with `kind: skip` is still emitted under `fields:`
  — it is the user's explicit declaration that the slot is unused,
  which `/issue-*` verbs treat as equivalent to slot-absent but more
  visible. Only omit a slot entirely if the user never reached the
  per-slot interview (e.g. the user aborted out of Step 3b before the
  loop covered that slot).
- If **all** slots are emitted as `kind: skip` or were never reached,
  omit the `fields:` key entirely — the block is still valid without
  it.
- Omit `issue-types` entirely if issue types were skipped or the repo
  has none enabled.
- Preserve the case-sensitive option and type names from the GitHub
  API verbatim — they are the canonical keys the `/issue-*` commands
  match against.
- If any option or type name contains consecutive spaces, or starts
  with a YAML-special character — any of these:

  ```text
  ? : - & * ! [ { , > | % @ ` " '
  ```

  — quote the key with double quotes to keep the YAML well-formed.
  The common case (single-word or space-separated names like `In
  Progress`) is fine unquoted, matching the example in
  `skills/lib/issue.md`. The same quoting rule applies to label
  options inside the `kind: label` flat-list shape: if any option
  contains a YAML-special character or consecutive spaces, quote
  that individual entry with double quotes inside the `[...]` list.

### 3b.6 — Skip marker (when the user chose to skip)

When the user chose `Skip` in 3b.1, do not write a `github-project:`
block. Instead, plan to write a single-line HTML comment of the
exact form:

```text
<!-- github-project: intentionally omitted; <reason>. -->
```

Place the comment where the block would have gone (see Step 5's
compose order). Use the reason captured from the user (free-text
trimmed to a single line, period appended if missing). When the
existing file (parsed in Step 2) already had a skip marker, its prior
reason is the recommended default for this free-text prompt per 3b.1,
so an accept-everything run reproduces the marker.

The skip marker documents the deliberate omission so anyone reading
the file later knows it was a choice, not an oversight.

## Step 3c: Jira interview (conditional)

This step runs **only when the just-chosen `issues` value is `Jira`**.
If `issues` is `GitHub`, Step 3b ran instead and this step is skipped.
If `issues` is anything else, both are skipped.

The purpose of this step is to populate (or intentionally omit) the
`jira:` body block defined in `skills/lib/repo-config.md` ("`jira:`
block") and the `/issues-jira:jira-lib` skill. The block carries the Jira project
key plus the status / priority / size slot maps and issue-type map
so the `/issue-*` commands (delivered in #9) can translate
human-readable names into the identifiers `acli` consumes. It is the
Jira analogue of the Step 3b `github-project:` interview, run through
`acli` instead of `gh`.

All discovery here uses the `acli` command templates in
the `/issues-jira:jira-lib` skill — read that file's "Discovery primitives" section
for the exact command shapes and their version caveat. Do not invent
`acli` flags inline; reference the library.

### 3c.0 — Preflight: `acli` and auth

1. **Detect `acli`.** Run `command -v acli`. If it is not on `PATH`,
   do **not** install it (host modification — forbidden). Surface a
   message that `acli` is required for the Jira interview and point
   the user at Atlassian's install docs, then offer to **Skip** the
   `jira:` block (jump to 3c.5 to record a skip marker) so the rest of
   the file can still be written.
2. **Check auth.** Run `acli jira auth status`. If unauthenticated or
   the session is expired, run `acli jira auth login --web` and wait
   for the user to complete the browser/SSO flow (a
   credential-prompting command, allowed per
   `~/.claude/rules/credential-surfaces.md`). On an auth failure that
   `--web` login does not resolve, **stop and report** — never
   introspect the user's Atlassian credential state. See
   the `/issues-jira:jira-lib` skill "Auth expectation and failure surface".

### 3c.1 — Decide whether to populate

Use `AskUserQuestion` to ask how to handle the `jira:` block. Offer:

- **Populate** — run discovery (3c.2 – 3c.4) and build the block,
  using the existing file's parsed `jira:` values (if any) as per-slot
  recommendations.
- **Skip** — write a skip marker instead, with a short reason captured
  via "Other". Skip the rest of Step 3c except 3c.5.

Recommend **Populate** when the existing file had a `jira:` block (or
no metadata block at all); recommend **Skip** when the existing file
had a `jira:` skip marker, pre-filling its prior reason. The carry-over
is not live-validated — recommending a stale value is fine.

### 3c.2 — Pick the project

List the projects visible to the authenticated user:

```bash
acli jira project list --json
```

Show the user the discovered projects (key + name), plus `Other` to
type a project key by hand and `Skip` (jump to 3c.5). Record the
chosen project **key** (e.g. `SET`) as `project-key`. Confirm the key
matches the `issue-link-prefix` chosen in Step 3 (e.g. key `SET` ↔
prefix `SET-`); if they disagree, note the mismatch to the user but do
not auto-correct — the front-matter answer stands.

### 3c.3 — Per-slot interview (status, priority, size)

Run the same generic interview once per conceptually-standard slot, in
this order: `status`, `priority`, `size`. The slot list is hardcoded
(matching Step 3b); a repo wanting a different slot hand-edits after
the wizard runs.

**Carry-over takes precedence over discovery.** When the existing file
recorded a slot, recommend the kind and values it used. Otherwise use
the discovery + per-slot defaults below. Carry-over is not
live-validated.

Discover the project's metadata once, up front, via the
the `/issues-jira:jira-lib` skill "Discovery primitives" templates:

- **Issue types** — from `acli jira project view --key <KEY> --json`,
  falling back to `acli jira workitem create --project <KEY>
  --generate-json` (which enumerates valid types and fields).
- **Statuses** — from a representative work item
  (`acli jira workitem search --jql "project = <KEY>" --json`, then
  `acli jira workitem view <KEY-N> --json` — the key is positional;
  `workitem view` has no `--key` flag); confirm/extend the
  status names with the user.
- **Custom fields** — from the `--generate-json` create template,
  which lists fields keyed by `customfield_NNNNN` with display names.

For each slot, present (via `AskUserQuestion`) the kinds the slot can
take, mark the recommended one, and follow up on the pick:

1. **`status`** — recommend `kind: status`. Capture the status
   `options:` as a name→name map from the discovered status names; ask
   which is the **default** (recommend `Backlog` if present, else the
   first). `Skip` is allowed but discouraged (warn that
   `/issue-set-status` will warn-and-skip).
2. **`priority`** — offer `kind: custom-field` (recommend when a
   custom field named `Priority`/`Importance`/`Severity` is discovered,
   capturing its `field-id:` and its allowed-value names as a name→name
   `options:` map), `kind: label`, or `kind: skip`. Ask for the
   **default** option.
3. **`size`** — offer `kind: custom-field` (when a `Size`/`T-Shirt`
   field is discovered), `kind: label` (recommend, with namespace
   `size:` and a user-entered option list, matching the GitHub size
   fallback), or `kind: skip`. Ask for the **default** option.

Hold each slot's captured state in memory for 3c.4's render. For
`kind: label`, ask for the namespace (recommend `<slot>:`) and a
comma-separated option list exactly as Step 3b.3 does.

### 3c.4 — Issue types and assemble the block

From the discovered (and user-confirmed) issue types, build the
`issue-types:` name→name map and ask which is the **default**
(recommend `Task` if present, else the first). If the project exposes
no enumerable types, offer to skip the `issue-types:` sub-block or let
the user enter names via `Other`.

Assemble the `jira:` block from the captured per-slot state and the
issue-types map, using the exact shapes in the
`skills/lib/repo-config.md` "`jira:` block" schema:

```yaml
jira:
  project-key: <KEY>
  fields:
    status:
      kind: status
      default: <name>
      options:
        <Name>: <Name>
        ...
    priority:
      <per-kind shape: custom-field | label | skip>
    size:
      <per-kind shape: custom-field | label | skip>
  issue-types:
    default: <Type Name>
    <Type Name>: <Type Name>
    ...
```

Per-kind render shapes:

- **`kind: status`** — emit `kind`, `default`, and the name→name
  `options:` map.
- **`kind: custom-field`** — emit `kind`, `field-id:`
  (`customfield_NNNNN`), `default`, and the name→name `options:` map.
- **`kind: label`** — emit `kind`, `namespace` (double-quoted),
  `default`, and the flat `options:` list — identical to Step 3b's
  label shape.
- **`kind: skip`** — emit `kind: skip` and nothing else.

The same conditional-rendering, YAML-quoting, and slot-order rules
from Step 3b.5 apply: slot order is fixed (`status`, `priority`,
`size`); a slot the user skipped is emitted as `kind: skip`; quote any
option/type key that contains consecutive spaces or a YAML-special
character. The renderer is purely a function of the captured state —
it never invents identifiers.

### 3c.5 — Skip marker (when the user chose to skip)

When the user chose `Skip` in 3c.1 (or `acli` was unavailable in
3c.0), do not write a `jira:` block. Instead, plan to write a
single-line HTML comment of the exact form:

```text
<!-- jira: intentionally omitted; <reason>. -->
```

Place the comment where the block would have gone (Step 5 compose
order). Use the reason captured from the user. When the existing file
already had a `jira:` skip marker, its prior reason is the recommended
free-text default per 3c.1, so an accept-everything run reproduces the
marker.

## Step 4: Show the proposed file and wait for approval

Render the **full file** that will be written, exactly as it will
appear on disk. This applies equally to the new-file case and the
overwrite case — there is no diff path, because Step 5 always
performs a full-file write rather than an in-place region edit. (The
existing file's values may have been carried over as recommended
defaults during the interview, but the write itself replaces the file
in full.)

Compose the preview in the same order Step 5 will write it:

1. The resolved YAML front-matter (the canonical seven-key block):

   ```yaml
   ---
   schema-version: 7
   source-control: <value>
   issues: <value>
   issue-link-prefix: "<value>"
   default-issue-source-branch: <value>
   default-pr-target-branch: <value>
   issue-branch-naming-prefix: <value>
   ---
   ```

   Notes:

   - `schema-version` is **always the first key** and **always
     `7`** in files this skill writes. It is a constant baked
     into the writer, not an interview question — see
     `skills/lib/repo-config.md` for how readers consume it.
     When the schema bumps, update this skill's constant and the
     library's `SCHEMA_VERSION`. Readers pin a **minimum**
     required version and accept any file at that version or
     newer (bumps are additive by construction), so a reader's
     pin is bumped only when that reader needs to consume a
     newly-added field — there is no lockstep requirement.
   - `issue-link-prefix` is always quoted because values like
     `#` are otherwise interpreted as a YAML comment.

2. A blank line.

3. The tracker-metadata block, selected by `issues`:
   - **GitHub** — **if Step 3b produced a `github-project:` block**
     (user chose `Populate`): the rendered block from 3b.5, followed
     by a blank line. **If Step 3b produced a skip marker** (user
     chose `Skip`): the single-line HTML comment from 3b.6, followed
     by a blank line.
   - **Jira** — **if Step 3c produced a `jira:` block** (user chose
     `Populate`): the rendered block from 3c.4, followed by a blank
     line. **If Step 3c produced a skip marker** (user chose `Skip`,
     or `acli` was unavailable): the single-line HTML comment from
     3c.5, followed by a blank line.
   - **Neither ran** (some other `issues` value): no extra content
     here.

4. The canonical body template (the same `# Repo Config` ... body
   used in Step 5).

Then ask explicitly for approval, e.g.:

> Write `.claude/rules/repo-config.md` with the content above? (y
> to proceed, or tell me what to change)

Wait for explicit approval (`y`, `yes`, `go`, `do it`, etc.) before
moving to Step 5. If the user asks for changes, loop back to Step
3, Step 3b, or Step 3c as appropriate, then re-render the full file
in this step.

## Step 5: Write the file

Use the `Write` tool to replace the entire file in a single call.
This applies whether the file existed before or not — `/repo-config`
is a full-rewrite tool, and the user already saw the full proposed
contents in Step 4 before approving.

Do not use `Edit` for in-place region rewrites. Do not copy any bytes
verbatim from the previous file. The new file's content is determined
entirely by the user's answers in this run plus the canonical body
template below — even though those answers may have been seeded by
values carried over from the previous file as recommended defaults
(Step 2). The carry-over influences the interview, not the write
mechanism: the write always emits a fresh full file.

In a brand-new repo `.claude/` and `.claude/rules/` may not exist
yet. The Claude Code `Write` tool creates missing parent directories
automatically, so calling `Write` on `.claude/rules/repo-config.md`
when neither directory exists is safe. If you are using a different
tool path that does not auto-create parents, run
`mkdir -p .claude/rules` first.

Compose the file in this order:

1. The resolved YAML front-matter (the canonical seven-key block
   from Step 4 — `schema-version: 7` followed by the six
   user-resolved fields, in that exact order).
2. A blank line.
3. The tracker-metadata block, selected by `issues`:
   - **GitHub** — **if Step 3b produced a resolved `github-project:`
     block**: that block exactly as rendered in 3b.5, followed by a
     blank line. **If Step 3b produced a skip marker**: the
     single-line HTML comment from 3b.6, followed by a blank line.
   - **Jira** — **if Step 3c produced a resolved `jira:` block**:
     that block exactly as rendered in 3c.4, followed by a blank
     line. **If Step 3c produced a skip marker**: the single-line
     HTML comment from 3c.5, followed by a blank line.
   - **Neither ran** (some other `issues` value): no extra content
     here.
4. The canonical body template (below), starting with `# Repo Config`.

The canonical body template (body only — front-matter and any
tracker-metadata content are composed in steps 1-3 above):

````markdown
# Repo Config

Read by `/issue-address` and by the `issue-developer`, `issue-fixer`,
`doc-updater`, and `pr-reviewer` subagents at the start of every run.
Do not assume values are already in context — re-read this file every
time.

## Fields

- **schema-version**: integer naming the file's schema version.
  The current version is `7`. The writer (`/repo-config`) stamps
  it into every file it produces; readers (see
  `skills/lib/repo-config.md`) consult it and abort cleanly when
  the value is missing or older than they require. Do not edit
  this by hand — re-run `/repo-config` to migrate to a newer
  version.
- **source-control**: `GitHub` or `CodeCommit`. Selects between `gh`
  and `aws codecommit` for VCS operations.
- **issues**: `GitHub` or `Jira`. Selects between `gh issue` and the
  Jira CLI/API for issue operations.
- **issue-link-prefix**: prefix used when referencing an issue in
  commit messages and PR bodies. The orchestrator and agents
  substitute it as a literal string concat: `<issue-link-prefix><N>`.
  For GitHub repos, set this to `#` so references render as `#123`.
  For Jira, use the project key plus dash, e.g. `SET-` (references
  like `SET-123`).
- **default-issue-source-branch**: branch that new issue work
  branches FROM. The orchestrator must pin this when creating the
  feature branch (e.g.
  `git switch -c <name> origin/<source-branch>`) so the branch is
  rooted at the right commit, not at whatever HEAD the worktree
  happened to start on.
- **default-pr-target-branch**: branch that issue PRs target. Often
  the same as `default-issue-source-branch`, but not always.
- **issue-branch-naming-prefix**: branch naming style.
  - `none`     -> `issue-917-slug`
  - `initials` -> `ev/issue-917-slug`
  - `name`     -> `edwin/issue-917-slug`

## Optional: `github-project:` block

This section is **body-only**; it is not part of the seven-key
front-matter. Add it below the front-matter when the repo has an
associated GitHub Project V2 board and you want the `/issue-*`
commands (and `/issue-create`'s `--type` / `--priority` / `--size`
/ `--status` flags in particular) to resolve human-readable names to
the project's field IDs and option IDs.

Repos without a project board **omit this block entirely**. The
`/issue-*` commands degrade gracefully: project-specific flags emit a
one-line warning and skip, while non-project operations work
normally.

Schema:

```yaml
github-project:
  project-id: PVT_kwDO...     # ProjectV2 node ID
  fields:
    status:
      kind: single-select
      id: PVTSSF_lADO...      # single-select field ID
      default: Backlog
      options:
        Backlog:     <option-id>
        Todo:        <option-id>
        In Progress: <option-id>
        In review:   <option-id>
        Done:        <option-id>
    priority:
      kind: number
      id: PVTF_lADO...        # number-field ID
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

The `priority` block's `min: 1` / `max: 9` values above are
illustrative — the wizard prompts the user for those and does not
auto-fill them.

Keys:

- **project-id**: the ProjectV2 node ID (starts with `PVT_`). Find
  with `gh project list --owner <org>` and convert the project
  number to a node ID via GraphQL.
- **fields.\<slot\>.kind**: required discriminator on every populated
  slot. One of `number`, `single-select`, `issue-field`, `label`, or
  `skip`. The remaining keys on the slot depend on the kind; see the
  "Field kinds" section of `skills/lib/issue.md` for the per-kind
  schema and examples. There is no implicit default and no
  backwards-compat shim for the old `type:` shape — a repo on the old
  shape is invalid and must be regenerated by re-running
  `/repo-config`.
- **fields.\<slot\>.id**: for `kind: number` and `kind: single-select`,
  the project field node ID (`PVTF_...` for number fields,
  `PVTSSF_...` for single-select). Find with
  `gh project field-list <project-number> --owner <org>`. Not used
  by `kind: label` (the label name is the identifier),
  `kind: issue-field` (which uses `field-id` instead), or
  `kind: skip`.
- **fields.\<issue-field-slot\>.field-id / .field-name / .data-type**:
  for `kind: issue-field`, the native GitHub Issue Field's node ID
  (`field-id`, `IFSS_...`), its human-readable name (`field-name`,
  for display and error messages), and its data-type
  (`data-type: single-select` — the only data-type supported today).
  `options:` maps option names to native-field option IDs
  (`IFSSO_...`). Unlike the project-field kinds, an `issue-field` slot
  reads and writes the value on the issue itself, so it works
  regardless of project-board membership.
- **fields.\*.default**: optional per-slot default. Resolution order
  for `/issue-create`'s slot flags (`--priority`, `--size`,
  `--status`) is: CLI flag > interactive prompt > this repo-config
  default > slot-skip. The interactive prompt rung shows the user
  the slot's options with this `default:` as the recommended /
  first option (or, for `--size`, the model's read of the issue
  body — see `skills/lib/issue.md` "Interactive prompt rung" and
  the "Size evaluation heuristic" in
  `skills/issue-create/SKILL.md`). Set-slot verbs
  (`/issue-set-priority`, `/issue-set-size`, `/issue-set-status`)
  do not consult this `default:` — they require an explicit
  `<value>` positional argument. Slot flags have no built-in
  default — if none of CLI flag, interactive prompt, or this
  `default:` produces a value, the slot is skipped per "Graceful
  degradation" in `skills/lib/issue.md`. The non-slot built-in
  defaults (`--type` = `Feature`, `--assignee` = current GitHub user,
  `--labels` = none, `--parent` = none) still apply to their
  respective flags.
- **fields.\<number-slot\>.min / .max**: bounds on a `kind: number`
  slot. Out-of-range values abort the verb cleanly rather than
  writing nonsense to the board.
- **fields.\<single-select-slot\>.options**: the human-readable option
  names mapped to their option IDs. The setter verb does a
  case-insensitive match against this map; canonical capitalization
  for display comes from the keys.
- **fields.\<label-slot\>.namespace / .options**: the label namespace
  (e.g. `"size:"`) and a flat list of option suffixes. Concrete
  labels are `<namespace><option>` (e.g. `size:XS`). The verb
  manages the slot via `gh issue edit --add-label/--remove-label`.
- **issue-types**: the human-readable issue-type names mapped to
  their type IDs (`IT_...`). `default:` selects which type
  `/issue-create` uses when `--type` is not passed.

The `/repo-config` skill auto-discovers and populates this block
interactively: pick the project from `gh project list`, then for each
conceptually-standard slot (`status`, `priority`, `size`) the wizard
offers every enumerated project field plus a label-namespace option
and a skip option, and writes `kind:` on every populated slot.
Issue-types are pulled separately via GraphQL. Hand-editing is
supported, but `/repo-config` is a full-rewrite tool: re-running it
replaces this entire file with content built from your answers in
that run. It does recommend the existing file's current values as the
default for each interview question, so an accept-everything re-run
reproduces the recognized fields — but any hand-edited content the
wizard does not interview for (e.g. a custom slot it doesn't know
about, or prose you added to the body) is dropped. To keep such hand
edits, decline the overwrite prompt at the start of the next run. See
`skills/lib/issue.md` for full details on how the block is consumed.

## Optional: `jira:` block

This section is the Jira analogue of `github-project:`. It is
**body-only**, appears only under `issues: Jira` (mutually exclusive
with `github-project:`), and lets the `/issue-*` commands resolve
human-readable metadata names to the identifiers `acli` uses. Where
GitHub addresses everything by opaque node IDs, `acli` addresses most
Jira things by **name**, so most `jira:` maps are name→name (identity
maps that pin the canonical spelling and the closed option set); only
custom-field slots carry an opaque `field-id:`.

Schema:

```yaml
jira:
  project-key: SET            # Jira project key (basis of issue-link-prefix)
  fields:
    status:
      kind: status            # transition by target status name
      default: Backlog
      options:
        Backlog:     Backlog
        In Progress: In Progress
        Done:        Done
    priority:
      kind: custom-field      # Jira custom field (customfield_NNNNN)
      field-id: customfield_10031
      default: Medium
      options:
        Low:    Low
        Medium: Medium
        High:   High
    size:
      kind: label             # label namespace (same as the GitHub label kind)
      namespace: "size:"
      default: M
      options: [XS, S, M, L, XL]
  issue-types:
    default: Task
    Task:  Task
    Bug:   Bug
    Story: Story
```

The Jira kinds are `status` (workflow status, written via a Jira
transition), `custom-field` (a Jira custom field with a `field-id:`),
`label` (a label namespace, identical to the GitHub `kind: label`),
and `skip`. See the `/issues-jira:jira-lib` skill for the full `acli` command
templates (auth, discovery, application) and the
`skills/lib/repo-config.md` "`jira:` block" section for the read
contract.

Repos using Jira without metadata tracking **omit this block
entirely** (or carry a skip marker); the `/issue-*` commands degrade
gracefully the same way they do for an absent `github-project:` block.

The `/issue-*` Jira **operations** that consume this block are
implemented (issue #9, built on the #249 foundation): they live in
the "Jira backend" section of `skills/lib/issue.md` and call `acli`
per the `/issues-jira:jira-lib` skill. A Jira repo without this block (or with a
skip marker) still degrades gracefully — metadata-requiring
operations warn-and-skip rather than aborting the run.

## Why this file exists

Different repos use different VCS, issue trackers, and branching
strategies. The `/issue-address` orchestrator and its subagents
(`issue-developer`, `issue-fixer`, `doc-updater`, `pr-reviewer`)
must not hardcode assumptions like "PR base is `main`", "use `gh`",
or "issue link is `#NNN`". When a repo deviates, the orchestrator
silently does the wrong thing. This file is the single source of
truth that everything reads at the start of every run.

If this file is missing, `/issue-address` aborts with an error
pointing at this skill (`/repo-config`) to create one
interactively.
````

The body is genericized: it does not reference any specific repo
(such as `macos-setup`) by name, and it points at `/repo-config`
as the way to create the file when it's missing.

### Verification

After the `Write` call, re-read the file with `Read` and confirm:

- The front-matter parses as YAML and contains exactly the seven
  canonical keys: `schema-version: 7` (first) followed by the six
  fields with the values the user approved in Step 4.
- If Step 3b produced a `github-project:` block (GitHub) or Step 3c
  produced a `jira:` block (Jira), the block appears at column 0 and
  parses as YAML; it terminates at a column-0 non-blank line (heading
  or next top-level key) as `skills/lib/issue.md` /
  `skills/lib/repo-config.md` expect.
- The canonical body template is present below the front-matter
  (and below the tracker-metadata block, if any).

If verification fails, surface the discrepancy to the user and stop
— do not attempt a corrective second write. The user should re-run
`/repo-config` after manually resolving the inconsistency.

## Step 6: Summarize

After the file is written, report back:

- The absolute path written.
- The final resolved values for all six front-matter fields.
- The tracker-metadata outcome — for the block matching `issues`
  (`github-project:` on GitHub, `jira:` on Jira), one of:
  - `populated` (GitHub: project title/number, count of status
    options, count of issue types; Jira: project key, count of status
    options, count of issue types).
  - `skipped` (no block present; skip marker written with reason).
  - `not applicable` (`issues` is neither `GitHub` nor `Jira`, so no
    tracker-metadata block applies).
- Whether the prior file (if any) was replaced. If the user
  declined the Step 2.5 overwrite prompt, this step is not reached
  — the skill exits in Step 2.5 with a "left unchanged" message.
- Next step: the user can now run `/issue-address` and the
  associated subagents in this repo.

---

## Hard constraints

- **Never write the file without explicit approval** in Step 4.
- **Never overwrite an existing file without the Step 2.5
  confirmation.** If the user declines, exit cleanly and leave the
  file untouched.
- **Carry values forward as recommended defaults, not as authority.**
  When the file exists, each interview question recommends the value
  parsed from the prior file (Step 2), falling back to the built-in
  default when a field is absent or unparseable. The user can always
  override. Never live-validate a carried-over value against the
  project (Step 3b), and never copy the prior file's bytes verbatim
  into the new file — the carry-over feeds the interview, the write is
  always a fresh full file built from this run's answers.
- **Never edit anything outside the target repo.** The skill writes
  exactly one file: `<repo-root>/.claude/rules/repo-config.md`.
- **Never run destructive git commands.** This skill does not
  commit, push, branch, reset, or otherwise change git state. The
  user commits the new file themselves.
- **Always go through `Write`** so the user sees the new contents
  applied as a single diff. Do not use `Edit` to rewrite regions
  of the prior file — the file is always replaced in full.
- **Do not validate remote branch existence** — out of scope.
- **Run the tracker-matching interview, never both.** Step 3b
  (`github-project:`) runs only under `issues: GitHub`; Step 3c
  (`jira:`) runs only under `issues: Jira`. The two blocks are
  mutually exclusive — never prompt for or emit a `github-project:`
  block on a Jira repo, or a `jira:` block on a GitHub repo. Under any
  other `issues` value, skip both.
- **Never invent project IDs, field IDs, option IDs, issue type IDs,
  Jira project keys, custom-field ids, status names, or type names.**
  All identifiers written to the `github-project:` block must come
  from a live `gh` query in Step 3b, and all identifiers written to
  the `jira:` block must come from a live `acli` query in Step 3c (or,
  in either case, with explicit user override via `Other`, from values
  the user typed in). Do not copy identifiers from the schema examples
  in this file, `skills/lib/issue.md`, or the `/issues-jira:jira-lib` skill — those
  are illustrative placeholders.
- **Never install `acli` or introspect Jira credential state.** If
  `acli` is missing in Step 3c, report and offer to skip — do not
  install it (host modification). On an `acli` auth failure, run
  `acli jira auth login --web` once and wait; never read or manipulate
  the user's Atlassian token cache. See the `/issues-jira:jira-lib` skill "Auth
  expectation and failure surface".
