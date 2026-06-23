---
name: jira-lib
description: Jira backend reference (acli templates, auth, metadata resolution) for the issue skills. Invoked by the issue tracker dispatcher, not by humans.
user-invocable: false
---

# Jira access library (the `/issues-jira:jira-lib` skill)

This file is the single source of truth for how a skill or command
talks to **Jira** via the Atlassian CLI (`acli`). It is the Jira
counterpart to the `/issues:issue-view` skill's GitHub GraphQL templates: it
documents the auth expectation, the field/issue-type/transition
**discovery** primitives that `/repo-config` uses to build the
`jira:` block, and the metadata-**application** primitives that the
`/issue-*` commands will later consume.

It is **reference prose**, not an executable script: a reader follows
the patterns documented here. Individual callers reference this doc
rather than re-deriving the `acli` command shapes inline.

The analogous libraries are the `/issues:issue-view` skill (the GitHub side of
the same surface — GraphQL templates and `github-project:` field-kind
resolution), the `/issues:repo-config` skill (the repo-config reader
contract), and the `/github-setup:gh-create-app` skill (GitHub App resolver). This
file plays the same role for the Jira backend.

## Scope of this library

This library covers the Jira **foundation** delivered in issue #249:

- The chosen Jira interface (`acli` with web/SSO login) and how an
  auth failure surfaces.
- Discovery primitives for the `jira:` block's name→identifier maps
  (projects, issue types, statuses/transitions, custom fields).
- Metadata-application primitives the `/issue-*` operations consume.

The actual `/issue-*` Jira **operations** (read, create, close,
comment, set-type/status/priority/size, relationships) and
`/issue-address`'s Jira path consume these primitives but are
documented in the **"Jira backend"** section of the `/issues:issue-view` skill,
not here. That section (delivered by issue #9, built on the #249
foundation this library provides) references the templates below by
name. This library remains the single source of truth for the `acli`
command shapes and the auth/discovery contract; the per-verb wiring
lives in the `/issues:issue-view` skill and the individual `/issue-*` SKILL
files.

## Chosen interface: `acli` with web/SSO login

The Jira backend talks to Jira through the official **Atlassian CLI**
(`acli`) using the browser/SSO login flow:

```bash
acli jira auth login --web
```

This is a deliberate choice over the REST API v3 and over
`jira-cli` (ankitpokhrel):

- REST API v3 and `jira-cli` are both **token-centric** (they need an
  Atlassian API token or PAT). The target environment (TELUS) no
  longer issues those tokens, so those paths are dead ends.
- `acli`'s `--web` login rides the user's **existing Atlassian SSO
  session** in a browser, avoiding API tokens entirely. This is the
  user's actual in-use workflow.
- It mirrors the GitHub path's shape: a first-class CLI (`gh` ↔
  `acli`) with a browser-based auth flow that fits the
  credential-surfaces rule the same way `gh auth login` does.

### Auth expectation and failure surface

`acli jira auth login --web` opens a browser and rides the existing
Atlassian SSO session. It is a **credential-prompting command** in
the sense of `~/.claude/rules/credential-surfaces.md`: running it is
allowed, and the harness surfaces the browser flow for the user to
complete on their own time. Check current auth state with:

```bash
acli jira auth status
```

When an `acli` command fails because the session is missing or
expired, the canonical recovery is to run `acli jira auth login
--web` and wait for the user to complete the browser flow — exactly
the pattern `aws sso login` and `gh auth login` follow under the
credential-surfaces rule.

What is **forbidden** (per the same rule): inspecting or manipulating
the user's Atlassian credential state directly — reading the `acli`
config/token cache, scripting around the SSO session, swapping sites
or accounts to dodge an auth failure, or looping a failing command
with `sleep` in the hope the session returns. On an auth failure that
a single `acli jira auth login --web` does not resolve, **stop and
report** rather than escalating to credential-state introspection.

### `acli` availability

`acli` is host tooling the user installs, the same way `gh` and `aws`
are. A skill that needs it detects its absence and reports — it does
**not** install `acli` on its own initiative (that would be a
host modification forbidden by
`~/.claude/rules/forbid-host-modifications.md` and, for subagents,
`~/.claude/rules/dependency-discipline.md`). Detect with:

```bash
command -v acli
```

If `acli` is not on `PATH`, abort the Jira branch with a clear
message naming the missing tool and pointing the user at Atlassian's
install docs. Do not fall back to the REST API or `jira-cli`.

## How Jira addressing differs from GitHub

This shapes the `jira:` block. Where GitHub's Project V2 addresses
everything by **opaque node IDs** (`PVT_…`, `PVTSSF_…`, `IT_…`,
single-select option IDs), `acli` addresses most things by
**human-readable name**:

- **Issue types** — `acli jira workitem create --type "Bug"` takes
  the type **name**, not an ID.
- **Status / transitions** — `acli jira workitem transition --status
  "Done"` takes the **target status name**. A Jira "transition" is
  selected by the status it lands on, so the `status` slot maps human
  names to Jira **status names**, not opaque transition IDs.
- **Custom fields** (priority, size) — addressed in the create/edit
  JSON payload by the field's **id** (`customfield_NNNNN`) or, in
  some `acli` paths, by field **name**. The custom-field id is the one
  place a Jira identifier is opaque, so the `jira:` custom-field slots
  carry an explicit `field-id:` analogous to the GitHub `id:`.

Because names are the primary identifiers, the `jira:` block's
name→identifier maps are frequently **name→name** (an identity map
that still pins the canonical spelling and the closed option set for
the abort-if-missing contract), and only the custom-field slots carry
a genuinely opaque `field-id:`. See the `jira:` schema in
`.claude/rules/repo-config.md` and the `/issues:repo-config` skill for
the exact block shape.

## Discovery primitives (for `/repo-config`)

`/repo-config`'s Jira interview uses these to populate the `jira:`
block. Each is a read-only `acli` call; prefer `--json` everywhere so
the output is machine-parseable.

> **Verification status.** The command and flag **shapes** below were
> verified against the installed binary (`acli 1.3.19-stable`) via its
> `--help` output: `project list`, `project view --key`, `workitem view`
> (positional key), `workitem search --jql`, and `workitem create
> --generate-json` all exist with the flags shown. What remains
> **unverified** is the discovery *content* — i.e. whether
> `project view --json` actually enumerates the project's issue-type
> scheme, and whether `workitem create --generate-json` actually emits
> the project's custom fields keyed by `customfield_NNNNN` — because
> that depends on live Jira data this machine cannot reach. The
> fallback chain (introspect a representative work item's `--json`, then
> the `--generate-json` create template) is the design for when a
> dedicated enumeration subcommand is absent; note that `acli
> 1.3.19-stable` has **no** `field list` / `field view` and **no**
> `transition list` subcommand, so those enumerations genuinely have no
> dedicated path and must come from the work-item / create-template
> introspection above.

### Project discovery

```bash
acli jira project list --json
acli jira project view --key "<PROJECT-KEY>" --json
```

`project list` enumerates the projects visible to the authenticated
user (each with its **key** and **name**); the user picks one. The
project **key** (e.g. `SET`) is the stable identifier written to the
`jira:` block's `project-key:` and is also the basis of
`issue-link-prefix` (`SET-`). `project view` fetches the chosen
project's detail, including its issue-type scheme where `acli`
exposes it.

### Issue-type discovery

The project's issue types come from `project view --json` (the
project's issue-type scheme). Where that payload does not enumerate
them on the installed `acli` version, fall back to the create
template:

```bash
acli jira workitem create --project "<KEY>" --generate-json
```

`--generate-json` emits a JSON template for a work item in that
project, which enumerates the valid issue types (and the project's
fields — see below). Each enabled type name contributes a
`<Name>: <Name>` entry to the `jira:` `issue-types:` map (identity
map; the name is the identifier `--type` consumes).

### Status / transition discovery

Jira statuses are workflow-scoped, and `acli`'s `workitem transition`
selects by **target status name** (`--status`). There is no
documented "list transitions" subcommand, so discover the valid
status set by inspecting a representative existing work item in the
project:

```bash
acli jira workitem view "<KEY-123>" --json
acli jira workitem search --jql "project = <KEY>" --json
```

`workitem view` takes the work-item key as a **positional argument**
(`acli jira workitem view KEY-123`), not a `--key` flag — only the
`transition`, `edit`, and `comment create` write verbs take `--key`.
The work item's `--json` payload carries its current status and the
project/workflow context. The user confirms or types the project's
status names (e.g. `Backlog`, `In Progress`, `Done`) during the
interview; each contributes a `<Name>: <Name>` entry to the `jira:`
`status` slot's `options:` map (identity map; the name is what
`--status` consumes). When the installed `acli` version exposes a
richer transition/workflow query, prefer it and pin the discovered
status names the same way.

### Custom-field discovery (priority, size)

Custom fields are the one opaque-id case. Discover them via the
create template, which lists the project's fields with their ids:

```bash
acli jira workitem create --project "<KEY>" --generate-json
```

The generated JSON includes the project's fields keyed by id
(`customfield_NNNNN`) alongside their display names. For each field
the user maps to a `priority` or `size` slot, capture **both** the
`field-id:` (`customfield_NNNNN`) and the human option names. `acli`'s
`field` subcommand group (`create` / `delete` / `update` / `restore` /
the deprecated `cancel-delete`) is for **managing** custom fields, not
enumerating them — there is no `field list` / `field view` subcommand
on `acli 1.3.19-stable` — so it is not a discovery path here.

## Metadata-application primitives (for `/issue-*`, consumed by #9)

These are the write paths the `/issue-*` Jira operations will use.
They are documented here as the foundation; wiring them into the
verbs is #9's job.

> **Verification status.** Every command and flag **shape** in this
> section was verified against `acli 1.3.19-stable` via `--help`:
> `workitem create` (`--project` / `--type` / `--summary` / `--label`
> singular / `--parent` / `--json` / `--generate-json` / `--from-json`),
> `workitem transition` (`--key` / `--status` / `--yes` / `--json`),
> `workitem edit` (`--key` / `--from-json` / `--labels` /
> `--remove-labels` / `--parent` / `--json`), `workitem comment create`
> (`--key` / `--body-file`), and the `workitem link` group
> (`create --out/--in/--type`, `delete --id`, `list --key`, `type`).
> What remains **unverified** is the live runtime *behavior* — that a
> transition actually lands the work item in the target status, that a
> custom-field `--from-json` write actually sticks, that a `Blocks` link
> is created with the intended direction — because this machine has no
> Jira instance to exercise the writes against. Trust the shapes; treat
> the runtime semantics as the first thing to confirm once a live Jira
> is available.

### Create a work item

```bash
acli jira workitem create \
  --project "<KEY>" \
  --type    "<Type Name>" \
  --summary "<title>" \
  --label   "<comma,separated,labels>" \
  --parent  "<PARENT-KEY>" \
  --json
```

`--type` takes the issue-type **name** resolved from the `jira:`
`issue-types:` map. `--parent` takes a parent work-item **key**.
Custom fields (priority, size) that must be set at create time go
through the JSON payload form (`--from-json <file>` / `--generate-json`
then edit), since `create` has no per-field flag for arbitrary custom
fields.

### Set status (transition)

```bash
acli jira workitem transition \
  --key    "<KEY-123>" \
  --status "<Status Name>" \
  --yes \
  --json
```

`--status` takes the target status **name** resolved from the `jira:`
`status` slot's `options:` map. `--yes` confirms without prompting.
This is the Jira analogue of the GitHub single-select status write.

### Set a custom field (priority, size)

Custom fields are set through `workitem edit` with a JSON field
payload (Jira addresses custom fields by `customfield_NNNNN`):

```bash
acli jira workitem edit \
  --key "<KEY-123>" \
  --from-json "<payload.json>" \
  --json
```

where `<payload.json>` sets the field by its `field-id:`
(`customfield_NNNNN`) from the slot's `jira:` config. When a slot is
modeled as a Jira **label** instead of a custom field (the `size`
fallback, mirroring the GitHub `kind: label` slot), set it with the
label flags on `edit`:

```bash
acli jira workitem edit \
  --key "<KEY-123>" \
  --labels "<namespace><option>" \
  --json
```

`workitem edit` addresses labels with `--labels` (sets the full label
list, comma-separated) and `--remove-labels` (removes named labels) —
**not** a singular `--label` flag. (The singular `-l, --label` flag
exists only on `workitem create`.) Because `--labels` replaces rather
than appends, the add/remove-set delta for a label-namespace update is
expressed as `--labels "<to-add>" --remove-labels "<to-remove>"` in a
single `edit` call.

### Comment / close

Comments and close are ordinary `acli` operations the `/issue-*`
verbs will call:

```bash
acli jira workitem comment create --key "<KEY-123>" --body-file "<path>"
acli jira workitem transition --key "<KEY-123>" --status "<Done-equivalent>" --yes
```

Comments live under the `acli jira workitem comment` **command group**
(`create` / `delete` / `list` / `update` / `visibility`); the verb is
`comment create`, a space-separated subcommand — **not** a single
`comment-create` token. The file-sourced-body flag is `-F, --body-file`
(`--body-file` reads the body from a plain-text/ADF file); the inline
alternative is `-b, --body`.

The comment body is **always read from a file**, never composed
inline — `/issue-comment` takes the body via `--body-file <path>` and
the Jira path passes that same file through, matching the GitHub
side's file-sourced-body requirement (see `skills/issue-comment/SKILL.md`
and the "Comment" path in the `/issues:issue-view` skill). Keeping the body in a
file makes the exact posted text reviewable and reproducible.

Jira has no separate "close" verb — closing is a transition to the
project's done-equivalent status. The `/issue-close` Jira path
(issue #9) resolves that status from the `jira:` `status` slot.

### Relationships (parent/child, blocks/blocked-by)

The `/issue-*` relationship verbs (parent/child and blocks/blocked-by)
map onto two Jira link kinds.

**Parent / sub-task.** A work item's parent is set on `edit`:

```bash
acli jira workitem edit --key "<CHILD-KEY>" --parent "<PARENT-KEY>"
```

Clear the parent to unset it (pass an empty parent where the installed
`acli` accepts it, or remove the parent/epic link via the link path
below). `/issue-set-parent` / `/issue-set-child` write this edge from
either side (the "one edge, two sides" pattern in
the `/issues:issue-view` skill); `/issue-unset-parent` / `/issue-unset-child`
clear it.

**Issue links ("blocks").** `blocks` / `blocked-by` are Jira issue
links. They live under the `acli jira workitem link` **command group**
(`create` / `delete` / `list` / `type`) — there is **no** top-level
`workitem link` write verb and **no** `workitem unlink` command. Create
and delete are separate subcommands:

```bash
acli jira workitem link create --out "<KEY-A>" --in "<KEY-B>" --type "Blocks"
acli jira workitem link delete --id "<LINK-ID>"
```

`link create` takes `--out` (the **outward** work item), `--in` (the
**inward** work item), and `--type` (the link type, which "accepts
outward descriptions" per `acli`). For a `Blocks` link, the outward
item is the **blocking** item and the inward item is the **blocked**
item, so "A blocks B" is `--out A --in B`. Map the verb directions per
the "`addBlockedBy` / `removeBlockedBy`" call-site mapping in
the `/issues:issue-view` skill.

Removal is **id-based**, not endpoint-based: `link delete` takes the
opaque **link id** via `--id`, not the two work-item keys. To unset a
"blocks" relationship, first enumerate the work item's links to find
the matching link's id, then delete it:

```bash
acli jira workitem link list --key "<KEY-A>" --json   # find the link's id
acli jira workitem link delete --id "<LINK-ID>"
```

Enumerate the available link types (to confirm the project's spelling
of `Blocks`) with:

```bash
acli jira workitem link type --json
```

(`link create` / `link delete` also accept `--from-json` / `--from-csv`
for batch operations and `--yes` to skip confirmation; the per-edge
`/issue-*` verbs use the single-link flag forms above.)

## Abort-if-missing / no-silent-fallback contract

The Jira block enforces the **same** contract the GitHub block does
(see the `/issues:issue-view` skill "Name -> ID lookup rules" and the error
catalogue): a configured option that does not resolve **aborts** with
the actual valid list fetched from Jira — it never silently falls
back to a default.

Concretely, when a `/issue-*` Jira operation (in #9) is asked to set
a slot value that is not in the slot's `jira:` `options:` map:

1. It re-discovers the live valid set from Jira via the relevant
   discovery primitive above (issue types via the create template,
   statuses via a representative work item, custom-field options via
   the field payload).
2. It aborts with a message naming the **offending value** and the
   **actual valid list** from the live discovery — mirroring the
   GitHub "Slot value not in options map" / "Issue-type name not in
   repo's issue-types map" catalogue entries in the `/issues:issue-view` skill.
3. It does **not** write a fallback value.

Name matching is **case-insensitive**, and the **canonical
capitalization** for display comes from the `jira:` map key — the same
"Name -> ID lookup rules" the GitHub side uses. The two backends share
this contract so the `/issue-*` namespace presents one consistent
behavior regardless of tracker.

## Conventions for callers

When writing or updating a Jira-backed skill or command:

- Open with a one-line statement that it uses the Jira backend and
  reference this file: "See the `/issues-jira:jira-lib` skill for the `acli`
  command templates and the auth/discovery contract."
- Do **not** copy `acli` command shapes inline — reference them by
  name ("uses the `workitem transition` template from
  the `/issues-jira:jira-lib` skill").
- Do **not** restate the auth/credential-surface rules — reference
  them.
- Re-read the relevant `jira:` config every run (do not cache across
  invocations), the same discipline the `/issues:repo-config` skill
  requires.
- On any `acli` auth failure, follow the "Auth expectation and
  failure surface" section: one `acli jira auth login --web`, then
  stop and report — never introspect credential state.
