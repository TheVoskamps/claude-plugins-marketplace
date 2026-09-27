---
name: issue-field-options
description: Report a slot's configured kind and options, or range bounds for a number slot (status, priority, size, or any configured slot), or every slot's when none is named. Read-only.
---

Report what repo-config says a field slot accepts: its `kind:` and its
option names, in configured order. This is the verb a caller uses when
it has to **choose** an option rather than set one it already has —
`/issue-set-<slot>` resolves a name the caller brings, and says nothing
about which names exist.

## Invocation

```text
/issue-field-options [<slot>]
```

- `<slot>` (optional): a key under the tracker block's `fields:` map —
  `status`, `priority`, `size`, or any other slot the repo declares.
  Matched case-insensitively against the configured keys. With a slot,
  report that slot only; without one, report every slot under
  `fields:`, in the order the keys appear in the file.

## Execution

Run the `issue-field-options` script, which this plugin puts on
`PATH`, with the Bash tool from inside the repo's working tree:

```bash
issue-field-options [<slot>]
```

It reads only `.issues/repo-config.md` and makes no `gh` call, so it
works without a project board. It writes nothing. Print its stdout as
it stands; on a non-zero exit, relay its stderr verbatim and stop.

## Output

One block per slot, separated by a blank line. An option-carrying
slot prints its kind, then one option name per line, in the config's
own order and with its own capitalization; an option's ID is never
printed:

```text
status: single-select
  Backlog
  Ready
  In progress
  In review
  Done
```

A `kind: number` slot prints the bounds it declares instead of
options:

```text
priority: number
  min: 1
  max: 9
```

An unconfigured slot — `kind: skip`, absent from `fields:`, or named
when there is no tracker block — prints one line and exits zero:

```text
effort: unconfigured
```

With no slot named and no tracker block, the whole output is
`No fields configured.`

## Jira backend

The script reads the `github-project:` block only. Under
`issues: Jira` it exits non-zero with its fixed Jira message; read the
`jira:` block of `.issues/repo-config.md` instead — its `fields:` map
has the same shape (`skills/lib/repo-config.md` → "`jira:` block") —
and render the same output from it. Nothing here needs `acli`.
