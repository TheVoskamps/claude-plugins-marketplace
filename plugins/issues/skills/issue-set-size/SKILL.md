---
name: issue-set-size
description: Set the size slot on a single issue, dispatching on the slot's configured kind (number, single-select, issue-field, label, or skip).
---

Set the size slot on a single issue. The slot is read from
`github-project.fields.size` in `.claude/rules/repo-config.md`; the
verb dispatches on its `kind:` discriminator and writes via the
matching template/recipe.

See `skills/lib/issue.md` for the shared "Set-slot dispatcher"
routine, GraphQL templates (number, single-select, and the
`setIssueFieldValue` native-issue-field template), the
"Label-namespace update" recipe, the catalogue error wordings, and
the slot-absent / `kind: skip` equivalence. This file documents only
what is specific to `/issue-set-size`: the slot name (`size`) and the
verb-specific echo lines.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Slot

`<slot>` = `size`. The dispatcher reads `github-project.fields.size`
each run.

## Arguments

```text
/issue-set-size <N> <value>
```

- `<N>` (required): issue number in the current repo, with or without
  a leading `#`.
- `<value>` (required): one token whose parse rules depend on the
  slot's configured `kind:`. Multi-word option names must be quoted
  on the CLI.

One fenced example per kind:

- **`kind: number`** — integer in `[min, max]` (the verb does not
  default; the value must be supplied):

  ```text
  /issue-set-size 123 5
  ```

- **`kind: single-select`** — option name from
  `fields.size.options`, matched case-insensitively:

  ```text
  /issue-set-size 123 M
  ```

- **`kind: label`** — option name from `fields.size.options` (flat
  list), matched case-insensitively:

  ```text
  /issue-set-size 123 M
  ```

- **`kind: issue-field`** — option name from `fields.size.options` (a
  native GitHub Issue Field's option map), matched case-insensitively.
  GitHub's native **Effort** Issue Field (`dataType: SINGLE_SELECT`,
  options `High` / `Medium` / `Low`) is the size-slot analogue of the
  native `Priority` field, so a `size` slot backed by Effort uses this
  kind. The slot's effective options are the native field's own
  (`High` / `Medium` / `Low`) — **not** the six-bucket t-shirt set —
  so `<value>` must be one of the native field's option names:

  ```text
  /issue-set-size 123 Medium
  ```

- **`kind: skip`** or slot absent — any `<value>` is ignored:

  ```text
  /issue-set-size 123 anything
  ```

## Execution

Follow the "Set-slot dispatcher" routine in `skills/lib/issue.md`
with `<slot>` = `size`. The per-kind write paths
(number / single-select / label / issue-field) and the slot-absent /
`kind: skip` handling are documented there; do not duplicate them.

The relevant catalogue entries (referenced by name from the lib):

- **Issue not found** — node-ID lookup returned `null`.
- **No `github-project:` block in repo-config** — abort (this verb
  requires project metadata).
- **Slot value out of range** — `kind: number` parse / range failure.
- **Slot value not in options map** — `kind: single-select` or
  `kind: label` name didn't match.
- **Slot kind doesn't match the operation** — input shape doesn't
  match configured kind (e.g. integer passed when slot is
  `kind: label`).
- **Slot not configured** — slot is absent or `kind: skip`; exit
  zero with this message.
- **Project field ID no longer exists on the project** —
  `updateProjectV2ItemFieldValue` returned a field-not-found error
  (applies to `kind: number` and `kind: single-select` only).
- **Native issue field no longer exists** — `setIssueFieldValue`
  returned a field-not-found error (applies to `kind: issue-field`
  only).
- **Cannot set native issue field** — `Issue.viewerCanSetFields` is
  false (applies to `kind: issue-field` only).

## Echo

On success, print exactly one line. Format depends on the slot's
configured `kind:`:

- **`kind: number`**:

  ```text
  #<N> size set to <value>.
  ```

- **`kind: single-select`**:

  ```text
  #<N> size set to <CanonicalOption>.
  ```

- **`kind: label`** (with `<namespace>` from `fields.size.namespace`):

  ```text
  #<N> size set to <CanonicalOption> (via label `<namespace><Option>`).
  ```

- **`kind: issue-field`**:

  ```text
  #<N> size set to <CanonicalOption>.
  ```

For `kind: single-select`, `kind: issue-field`, and `kind: label`, the
no-op (idempotent) echo uses `already set to` in place of `set to`:

- ``#<N> size already set to <CanonicalOption>.``
- ``#<N> size already set to <CanonicalOption> (via label `<namespace><Option>`).``

`kind: number` has no pre-check and therefore no `already set to`
form — the mutation is always invoked.

No trailing URL line.
