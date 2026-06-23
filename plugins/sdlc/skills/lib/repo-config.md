# Repo-config reader contract (`skills/lib/repo-config.md`)

This file is the single source of truth for how readers should
consume `.claude/rules/repo-config.md`. It is **reference prose**,
not an executable script: a reader (orchestrator, subagent, or
skill) follows the patterns documented here when it loads the
target repo's config. Individual readers reference this doc rather
than re-deriving the parse rules or abort wording.

The analogous libraries are the `/issues:user-config` skill (the
per-user counterpart — private, never-committed settings),
the `/issues:issue-view` skill (`/issue-*` shared reference), and
the `/github-setup:gh-create-app` skill (GitHub App resolver); this file plays the
same role for the repo-config file itself.

## Current schema version

```text
SCHEMA_VERSION = 7
```

`7` is the version readers should require as of this writing. A
reader pins the **minimum** version it knows how to consume in its
own code (see "Reader-side version pin" below) and aborts cleanly
when the target file is older. The writer (`/repo-config`) stamps
`7` into every file it produces; see `skills/repo-config/SKILL.md`.

Version `7` adds the optional `jira:` body block (the Jira analogue
of `github-project:`), parallel to it and mutually exclusive with it
by tracker: a `github-project:` block appears under `issues: GitHub`,
a `jira:` block under `issues: Jira`. The bump is additive by
construction — the seven canonical front-matter keys are unchanged,
so a reader written against version `6` still reads a version `7`
file correctly (it simply ignores the `jira:` block it doesn't know
about). Only a reader that needs to **consume** the `jira:` block
bumps its required version to `7`.

Why a minimum rather than an exact match:

- Schema bumps are **additive by construction** — a bump adds new
  fields or new option values without changing the meaning of the
  existing seven canonical front-matter keys. A reader written
  against version `N` can therefore safely read a version `N+1`
  file: the keys it knows about still mean what they did, and the
  keys it doesn't know about are simply ignored.
- Readers accordingly accept **anything ≥ their pinned version**.
  Equal versions are read as-is; newer versions are read as if
  they were the pinned version, with unknown fields skipped. A
  reader still declares which version it was written against, so
  older files trigger a clean "Schema-version stale" abort with a
  re-run-`/repo-config` fix hint.
- Every bump to the schema is paired with a writer update and a
  bump to this constant. A future breaking-change bump (one that
  would invalidate the "additive by construction" guarantee) may
  revisit this policy and require readers to pin an exact value;
  until then, newer-is-fine.

## What the file looks like

`.claude/rules/repo-config.md` has three parts, in order:

1. A YAML front-matter block, delimited by `---` on the line above
   and the line below. Contains a fixed set of top-level keys: a
   `schema-version:` integer (first key, since version `6`) and
   the six canonical front-matter fields documented under
   "Front-matter fields" below.
2. A body. Everything after the closing `---`. The body may
   contain an optional tracker-metadata block — a `github-project:`
   block under `issues: GitHub`, or a `jira:` block under
   `issues: Jira` (both parsed as YAML at column 0) — and a prose
   section that documents the file's own fields. The two blocks are
   mutually exclusive: a file carries at most one, selected by the
   `issues` front-matter value. The prose is for humans reading the
   file directly; it is not part of the read contract.
3. (Optional) A single-line skip marker HTML comment in place of
   the tracker-metadata block when the repo author deliberately
   omitted it. See "Skip marker" below.

## Canonical read sequence

Every reader of `.claude/rules/repo-config.md` follows this exact
sequence. Each numbered step has a single canonical abort message
(see "Abort messages" below); use the wording verbatim so the
namespace presents consistent errors.

1. **Locate the file.** Find the repo root with
   `git rev-parse --show-toplevel`. The file lives at
   `<repo-root>/.claude/rules/repo-config.md`. Do not assume the
   caller's cwd is the repo root.

2. **Read the file.** If the file is absent, abort with the
   "File missing" message.

3. **Parse the front-matter.** Find the opening `---` (the file's
   first non-blank line) and the closing `---`. Parse the lines
   between them as YAML. If the front-matter block is malformed or
   absent, treat it as schema-version `0` and abort with the
   "Schema-version absent" message.

4. **Check `schema-version`.**
   - If the `schema-version` key is absent from the parsed
     front-matter, treat its value as `0` and abort with the
     "Schema-version absent" message.
   - If the parsed value is an integer less than the reader's
     required version, abort with the "Schema-version stale"
     message, naming both the file's version and the required
     version.
   - If the parsed value equals the reader's required version,
     proceed.
   - If the parsed value is **greater than** the reader's required
     version, the reader was written against an older schema than
     the target file. Today's policy is to proceed and read only
     the fields documented here — newer schema versions are
     forward-compatible by construction (additive). A future
     breaking-change bump may revisit this; until then, do not
     abort on a higher-than-required version.

5. **Read front-matter fields.** Pull the six canonical fields
   (see "Front-matter fields" below). A `schema-version: 7` file
   is required to populate all six; if any canonical field is
   missing on an otherwise-current file (schema-version present
   and ≥ the reader's required version), abort with the
   "Front-matter incomplete" message, naming the missing field.
   This is distinct from the "Schema-version stale" abort, which
   covers files at an older version: a current-version file with
   a missing field is not stale, it is incomplete, and the user
   needs to be told *which* field is absent.

6. **(Optional) Read the tracker-metadata block.** Which block to
   read is selected by the `issues` front-matter value:
   - Under `issues: GitHub`, scan the body for a line that starts
     with `github-project:` at column 0. If present, parse the
     indented YAML beneath it per the schema documented in
     the `/issues:issue-view` skill. If absent, the reader gracefully
     degrades per the "Graceful degradation when the block is
     missing" section of the `/issues:issue-view` skill.
   - Under `issues: Jira`, scan the body for a line that starts with
     `jira:` at column 0. If present, parse the indented YAML
     beneath it per the `jira:` schema documented under "`jira:`
     block" below and in the `/issues-jira:jira-lib` skill. If absent, the reader
     gracefully degrades the same way (warn-and-skip on
     metadata-requiring operations).

   Skip-marker HTML comments (see below) count as "absent" for read
   purposes. A reader should not look for a `github-project:` block
   on a Jira repo or a `jira:` block on a GitHub repo — the `issues`
   value is authoritative for which one to expect.

7. **Return resolved values.** Hand the parsed values back to the
   caller. Do not cache across runs — readers re-read the file
   every time so that a re-run of `/repo-config` between calls is
   picked up immediately.

### Reader-side version pin

A reader pins the **minimum** schema-version it requires as a
constant in its own code. For prose-defined readers (subagent
definitions, skill SKILL.md files), the constant is a literal in
the reader's text; for any future executable reader, it would be a
code constant.

The pinned value should equal the version this library documents
at the time the reader was written. Readers accept files at the
pinned version **or newer** (per the "Why a minimum rather than an
exact match" rationale in "Current schema version" above); they
abort cleanly with the "Schema-version stale" message only when
the file is at an *older* version. When the schema bumps:

1. The writer (`/repo-config`) bumps its emitted value.
2. This library bumps `SCHEMA_VERSION` to match.
3. Existing readers continue to work against the newer files
   without modification, because bumps are additive by
   construction (they read only the fields they know about). A
   reader's pin is bumped only when the reader needs to consume a
   newly-added field — there is no lockstep requirement.

A future breaking-change bump that invalidates the additive
guarantee would change this — at that point readers would need to
abort on newer files too, and the policy in "Current schema
version" above would be revised accordingly.

## Abort messages

Use these exact wordings so every reader emits the same error.
Variable parts are wrapped in backticks.

- **File missing**

  > This repo has no `.claude/rules/repo-config.md`. Run
  > `/repo-config` to create one.

  Some existing readers prefix this with a reader-specific clause
  ("issue-developer requires it", "/issue-* commands require it",
  etc.). The clause is permitted but not required; the
  `Run /repo-config to create one` tail is the canonical fix
  hint.

- **Schema-version absent**

  > This repo's `.claude/rules/repo-config.md` predates schema
  > versioning. Run `/repo-config` to migrate.

  Triggered when the front-matter has no `schema-version:` key (or
  the front-matter itself is malformed/absent). Treated as
  schema-version `0`; the user fixes it by re-running
  `/repo-config`, which will overwrite the file with the current
  shape.

- **Schema-version stale**

  > This repo's `.claude/rules/repo-config.md` is at
  > schema-version `<N>`; this skill requires `<M>`. Run
  > `/repo-config` to migrate.

  Triggered when the parsed `schema-version` integer is less than
  the reader's required version. `<N>` is the file's current
  version, `<M>` is the reader's required version. The fix is the
  same — re-run `/repo-config` to overwrite the file.

- **Front-matter incomplete**

  > This repo's `.claude/rules/repo-config.md` is at
  > schema-version `<N>` but is missing the canonical field
  > `<field-name>`. Run `/repo-config` to regenerate it.

  Triggered when the file's `schema-version` is present and ≥ the
  reader's required version, but one of the six canonical
  front-matter fields (see "Front-matter fields" below) is absent
  from the parsed front-matter. `<N>` is the file's
  schema-version; `<field-name>` is the missing field's key.
  Distinct from "Schema-version stale" because the file is not at
  an older version — it is at a current version but malformed
  (likely hand-edited). The fix is to re-run `/repo-config`, which
  rewrites the file from scratch with all canonical fields
  present.

Readers should not invent additional abort messages for the same
failure shapes. If a new failure shape arises, document it in this
catalogue rather than ad-hoc wording in the reader.

## Front-matter fields

The six canonical front-matter fields, alongside `schema-version`,
make up the seven keys that appear in every `schema-version: 7`
file. Order is fixed; `schema-version` is always first.

- **`schema-version`** — integer. The file's schema version. As
  of this writing the only valid value is `7`. Readers consult
  this field per the canonical read sequence above. The writer
  (`/repo-config`) emits the current version as a constant; users
  do not edit it by hand. Older or absent values trigger the
  abort messages above.

- **`source-control`** — `GitHub` or `CodeCommit`. Selects between
  `gh` and `aws codecommit` for VCS operations. The
  `issue-developer`, `issue-fixer`, and `pr-reviewer` agents
  dispatch on this value when creating PRs / opening reviews.

- **`issues`** — `GitHub` or `Jira`. Selects between `gh issue`
  and the Atlassian CLI (`acli`) for issue operations. Both backends
  are implemented across `/issue-*` and `/issue-address`: the GitHub
  path uses `gh`/GraphQL, the Jira path uses `acli` (see the "Jira
  backend" section of the `/issues:issue-view` skill and the `acli` access
  library the `/issues-jira:jira-lib` skill).

- **`issue-link-prefix`** — string. The literal string
  concatenated with an issue number in commit messages and PR
  bodies. The orchestrator and agents substitute it as
  `<issue-link-prefix><N>`. For GitHub repos, `#` so references
  render as `#123`; for Jira, the project key plus dash
  (e.g. `SET-` for `SET-123`). Quote the value in YAML if it
  starts with `#` (otherwise YAML parses it as a comment) —
  `/repo-config` does this automatically.

- **`default-issue-source-branch`** — string. Branch that new
  issue work branches FROM. The orchestrator pins this when
  creating the feature branch (e.g.
  `git switch -c <name> origin/<source-branch>`) so the branch
  is rooted at the right commit, not at whatever HEAD the
  worktree happened to start on.

- **`default-pr-target-branch`** — string. Branch that issue PRs
  target. Often the same as `default-issue-source-branch`, but
  not always (e.g. release-branch workflows where work branches
  off `integ` but PRs target `main`).

- **`issue-branch-naming-prefix`** — one of `none`, `initials`,
  `name`. Selects the branch-name shape that `/issue-address`
  and the developer/fixer agents use:
  - `none`     -> `issue-<N>-<slug>`
  - `initials` -> `<initials>/issue-<N>-<slug>`
  - `name`     -> `<name>/issue-<N>-<slug>`

  When the prefix is `initials` or `name`, the agent prompts the
  human owner for the value if the spawn context doesn't supply it.

### Per-field accessor pattern

Readers that need a single field follow this shape (prose
pseudocode; the actual reader is whatever language fits):

```text
config = read_repo_config(required_version = <N>)   # the seven steps above
branch = config["default-issue-source-branch"]
```

The read step does the schema-version check once; per-field
accessors are plain dictionary lookups on the resolved value. Do
not re-parse the file per field.

## `github-project:` block

The `github-project:` block lives in the body, parsed as YAML at
column 0. Its schema (project ID, per-slot field configuration,
issue-types map) is documented in full under "Repo-config parsing"
and "Field kinds (`fields.<slot>.kind`)" in the `/issues:issue-view` skill.
This library does not duplicate that schema; readers needing the
block should follow the parse rules there.

The block is **optional**. Repos without a Project V2 board omit
it entirely. The `/issue-*` namespace degrades gracefully when the
block is absent, per the `/issues:issue-view` skill "Graceful degradation
when the block is missing". This library's canonical read
sequence (step 6) covers the absent-block case by deferring to
that section.

### Skip marker

When a repo author deliberately omits the tracker-metadata block,
`/repo-config` writes a single-line HTML comment in its place. The
comment names whichever block was omitted:

```text
<!-- github-project: intentionally omitted; <reason>. -->
<!-- jira: intentionally omitted; <reason>. -->
```

For read purposes, the skip marker is equivalent to "block
absent" — readers do not parse the reason, do not surface it in
error messages, and do not change behavior based on its presence.
The marker exists so a human reading the file can see the
omission was deliberate. The writer (`/repo-config`) does parse the
marker on a re-run: it recommends `Skip` again and pre-fills the
prior reason as the recommended free-text default (see
`skills/repo-config/SKILL.md` Step 3b.1), so an accept-everything
run reproduces the marker. This carry-over is a *writer* convenience
and does not change how readers treat the marker.

## `jira:` block

The `jira:` block is the Jira analogue of `github-project:`. It lives
in the body, parsed as YAML at column 0, and appears only under
`issues: Jira` (mutually exclusive with `github-project:`). It
mirrors the tracker-neutral metadata axes (status, priority, size,
issue-types) so the `/issue-*` namespace resolves them the same way
on Jira, but its identifiers reflect how `acli` addresses Jira (most
are human-readable names, not opaque IDs — see
the `/issues-jira:jira-lib` skill "How Jira addressing differs from GitHub").

Schema:

```yaml
jira:
  project-key: SET            # Jira project key (basis of issue-link-prefix)
  fields:
    status:
      kind: status            # Jira-specific: transition by target status name
      default: Backlog
      options:                # name -> name (identity); name is what --status consumes
        Backlog:     Backlog
        In Progress: In Progress
        Done:        Done
    priority:
      kind: custom-field       # Jira custom field, addressed by customfield_NNNNN
      field-id: customfield_10031
      default: Medium
      options:
        Low:    Low
        Medium: Medium
        High:   High
    size:
      kind: label              # label namespace (same as GitHub label kind)
      namespace: "size:"
      default: M
      options: [XS, S, M, L, XL]
  issue-types:
    default: Task
    Task:    Task              # name -> name (identity); name is what --type consumes
    Bug:     Bug
    Story:   Story
```

Keys:

- **project-key** — the Jira project key (e.g. `SET`). The stable
  project identifier `acli` uses and the basis of the
  `issue-link-prefix` front-matter value (`SET-`).
- **fields.\<slot\>.kind** — required discriminator on every populated
  slot, the Jira-side parallel of the `github-project:` kinds. The
  Jira kinds are:
  - **`kind: status`** — a workflow status slot, written via a Jira
    transition (`acli jira workitem transition --status <name>`). The
    `options:` map is **name → name** (an identity map that pins the
    canonical spelling and the closed status set); the option value is
    the status name `--status` consumes. There is no opaque transition
    ID because `acli` selects a transition by its target status name.
  - **`kind: custom-field`** — a Jira custom field (priority), the
    one opaque-id case. Carries `field-id:` (`customfield_NNNNN`) and an
    `options:` name→name map for the field's allowed values. Written via
    `acli jira workitem edit` with a JSON field payload.
  - **`kind: label`** — identical in shape and behavior to the
    `github-project:` `kind: label`: a label **namespace** (not a Jira
    field) with a flat `options:` list. Concrete labels are
    `<namespace><option>`, managed via `acli jira workitem edit
    --label`.
  - **`kind: skip`** — the slot is explicitly unused; verbs warn and
    exit zero. Equivalent to slot-absent, mirroring the GitHub side.
- **fields.\<slot\>.default** — optional per-slot default, resolved the
  same way the `github-project:` `default:` is (see "fields.\*.default"
  in `.claude/rules/repo-config.md`).
- **fields.\<slot\>.options** — name→name map (for `status` /
  `custom-field`) or flat list (for `label`). Name matching is
  case-insensitive; canonical capitalization comes from the key. A
  value that does not resolve aborts with the live valid list per the
  abort-if-missing contract (see the `/issues-jira:jira-lib` skill).
- **fields.\<custom-field-slot\>.field-id** — the Jira custom-field id
  (`customfield_NNNNN`). Present only on `kind: custom-field` slots.
- **issue-types** — name→name map (identity) plus a `default:`. The
  type name is what `acli jira workitem create --type` consumes.

The full `acli` discovery and application command templates for this
block live in the `/issues-jira:jira-lib` skill. The block is **optional** and
degrades gracefully exactly like `github-project:`: a Jira repo
without a `jira:` block (or with a skip marker) warns-and-skips on
metadata-requiring `/issue-*` operations rather than aborting the
whole run.

> Note: the `/issue-*` Jira operations that consume this block are
> implemented (issue #9, built on the #249 foundation). They live in
> the "Jira backend" section of the `/issues:issue-view` skill and call `acli`
> per the `/issues-jira:jira-lib` skill. A Jira repo without this block (or with a
> skip marker) still degrades gracefully — metadata-requiring
> operations warn-and-skip rather than aborting the run.

## Migration policy

This library introduces `schema-version: 7` (the `jira:` block) on
top of the `schema-version: 6` baseline, but does **not** migrate
every reader at once. The bump is additive: the `jira:` block lives
in the body, so an un-migrated reader ignores it and a
schema-version-6 reader still reads a schema-version-7 file. The
four agent definitions
(`issue-developer`, `issue-fixer`, `doc-updater`, `pr-reviewer`)
and `/issue-address`'s SKILL.md follow this contract: they pin
schema-version 6 and defer to the canonical read sequence and abort
messages above (migrated in #115). The user-facing `/issue-*`
namespace follows it too: its shared the `/issues:issue-view` skill
"Repo-config parsing" section and each `/issue-*` SKILL.md pin
schema-version 6 and defer here (migrated in #114). Remaining reader
migrations land in their own follow-up issues.

When migrating a reader:

1. Add the reader's required-version constant alongside its
   existing parse logic.
2. Replace ad-hoc abort wording with the canonical messages from
   "Abort messages" above.
3. Replace ad-hoc YAML parsing with a call to (or in-prose
   description of) the canonical read sequence.
4. Update the reader's frontmatter or top-of-file comment to
   reference this library, the same way the `/issues:issue-view` skill
   readers do.

Readers that are not yet migrated keep working — they parse the
front-matter ad-hoc and never look at `schema-version`. A
`schema-version: 7` file is fully readable by them because the six
canonical front-matter fields are unchanged from the pre-versioned
shape; the `jira:` block the bump adds lives in the body, which
un-migrated readers already ignore.

## Conventions for readers

When writing or updating a reader of `.claude/rules/repo-config.md`:

- Open with a one-line statement of which schema-version the
  reader requires.
- Reference this file: "See `skills/lib/repo-config.md` for the
  read contract and abort messages."
- Do **not** restate the canonical abort wording inline — quote it
  from this file by exact wording. If the reader needs a
  reader-specific prefix (e.g. "issue-developer requires it"),
  prepend it but leave the canonical tail intact.
- Do **not** invent a new schema-version mismatch wording.
- Re-read the file every run. Do not cache parsed values across
  invocations; a re-run of `/repo-config` between two reads must
  be picked up.
