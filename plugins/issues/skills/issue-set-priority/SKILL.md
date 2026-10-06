---
name: issue-set-priority
description: Set the priority slot on a single issue, dispatching on the slot's configured kind (number, single-select, issue-field, label, or skip).
---

Set the priority slot on a single issue — the slot declared as
`github-project.fields.priority` in `.issues/repo-config.md`. What
`<value>` means depends on the slot's `kind:`, and the script writes
it through that kind's own path: a project field, a native GitHub
issue field, or a label.

## Invocation

```text
/issue-set-priority <N> <value>
```

- `<N>` (required): the issue: `N` or `#N` in the current repo, or
  `repo#N`, `owner/repo#N`, `host/owner/repo#N` or
  `https://host/owner/repo/issues/N` in another, as
  `skills/lib/issue.md` → "Repositories and issue references" resolves
  them. In another repo the slot is that repo's own, as the same section
  states.
- `<value>` (required): one argument, quoted when it has spaces. By the
  slot's kind:
  - **`kind: number`** — an integer within the slot's `min`/`max`.
  - **`kind: single-select`**, **`kind: issue-field`**,
    **`kind: label`** — an option name, matched case-insensitively.
    GitHub's native `Priority` field, the usual `issue-field` backing,
    has the options `Urgent`, `High`, `Medium`, `Low`.
  - **`kind: skip`** or slot absent — ignored.

  Run `/issue-field-options priority` when you need to choose a value
  rather than set one you already hold.

## Execution

Run the `issue-set-priority` script, which this plugin puts on
`PATH`, with the Bash tool from inside the repo's working tree:

```bash
issue-set-priority <N> "<value>"
```

The script validates the value, skips the write when the slot already
holds it (every kind but `number`), and otherwise writes it and
re-reads the slot, exiting non-zero when the re-read does not show the
value it set. Print its stdout as it stands. On a non-zero exit, relay
its stderr verbatim and stop: it carries the canonical wording for a
missing `github-project:` block, an issue not found, an out-of-range
number, a name not in the options, a value of the wrong shape for the
kind, a stale field ID (re-run `/repo-config`), a viewer who may not
set native issue fields, or a write that did not land.

## Output

On success, exactly one line; no URL:

```text
#<N> priority set to <value>.
#<N> priority set to <CanonicalOption> (via label `<namespace><Option>`).
```

The second form is a `kind: label` slot's. When the slot already held
the value, `set to` reads `already set to`. The option name always
carries the config's capitalization, not the caller's.

When the slot is `kind: skip` or absent from `fields:`, the script
prints this line instead and exits **zero** — a warning, not an
error:

> `/issue-set-priority` has nothing to do: this repo has no `priority`
> slot configured. (Run `/repo-config` to add one.)

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Metadata setters" instead.
