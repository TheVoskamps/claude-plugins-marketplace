---
name: issue-field-options
description: Report a slot's configured kind, default, and options, or range bounds for a number slot (status, priority, size, or any configured slot), or every slot's when none is named — in this repo or, with --repo, in another. Read-only.
---

Report what repo-config says a field slot accepts: its `kind:`, its
`default:`, and its option names, in configured order. This is the
verb a caller uses when it has to **choose** an option rather than set
one it already has — `/issue-set-<slot>` resolves a name the caller
brings, and says nothing about which names exist.

## Invocation

```text
/issue-field-options [<slot>] [--repo owner/repo]
```

- `<slot>` (optional): a key under the tracker block's `fields:` map —
  `status`, `priority`, `size`, or any other slot the repo declares.
  Matched case-insensitively against the configured keys. With a slot,
  report that slot only; without one, report every slot under
  `fields:`, in the order the keys appear in the file.
- `--repo` (optional): report `owner/repo`'s slots instead of the
  current repo's. The script reads that repo's `.issues/repo-config.md`
  from its default branch and reads nothing from the current repo's
  repo-config. A target with no repo-config reports every slot as
  unconfigured; a target at an unsupported schema-version aborts.

## Execution

Run the `issue-field-options` script, which this plugin puts on
`PATH`, with the Bash tool from inside the repo's working tree:

```bash
issue-field-options [<slot>] [--repo <owner/repo>]
```

Without `--repo` it reads only `.issues/repo-config.md` and makes no
`gh` call; with it, its one `gh` call reads the target's repo-config.
Either way it works without a project board and writes nothing. Print
its stdout as it stands; on a non-zero exit, relay its stderr verbatim
and stop.

## Output

One block per slot, separated by a blank line. The block's first line
is the slot and its kind, followed — when the slot declares a
`default:` — by a space and `(default: <value>)`; a slot with no
`default:` has no suffix. An
option-carrying slot then prints one option name per line, indented two
spaces, in the config's own order and with its own capitalization; an
option's ID is never printed. The default is printed in its option's
capitalization when it names one, and as the config spells it
otherwise:

```text
status: single-select (default: Backlog)
  Backlog
  Ready
  In progress
  In review
  Done
```

A `kind: number` slot prints the bounds it declares instead of
options:

```text
priority: number (default: 3)
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
`issues: Jira` — in the repo-config it reads, the target's under
`--repo` — it exits non-zero with its fixed Jira message; read the
`jira:` block of that `.issues/repo-config.md` instead — its `fields:`
map has the same shape (`skills/lib/repo-config.md` → "`jira:` block") —
and render the same output from it. Nothing here needs `acli`.
