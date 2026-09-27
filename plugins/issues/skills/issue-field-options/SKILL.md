---
name: issue-field-options
description: Report a slot's configured kind and options, or range bounds for a number slot (status, priority, size, or any configured slot), or every slot's when none is named. Read-only.
---

Report what repo-config says a field slot accepts: its `kind:` and its
option names, in configured order. This is the verb a caller uses when
it has to **choose** an option rather than set one it already has —
`/issue-set-<slot>` resolves a name the caller brings, and says nothing
about which names exist.

See `skills/lib/issue.md` for tracker dispatch and the per-kind slot
schema ("Field kinds (`fields.<slot>.kind`)"). This file documents
only what is specific to `/issue-field-options`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.issues/repo-config.md`.

## Invocation

```text
/issue-field-options [<slot>]
```

- `<slot>` (optional): a key under the tracker block's `fields:` map —
  `status`, `priority`, `size`, or any other slot the repo declares.
  Matched case-insensitively against the configured keys. With a slot,
  report that slot only; without one, report every slot under
  `fields:`, in the order the keys appear in the file.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`. The
switch selects which block step 6 of the canonical read sequence
parses: `github-project:` under `issues: GitHub`, `jira:` under
`issues: Jira`. Both blocks carry the same `fields:` map shape and
feed the same output form below.

The Jira branch makes no `acli` call: everything this verb reports is
in repo-config, and it addresses no work item, so the Jira backend's
per-operation preconditions (`acli` present, authenticated, key
normalization) have nothing to guard here.

## Execution

1. **Read repo-config** per the canonical read sequence, including
   step 6 for the block the tracker selects.

2. **Collect the slots.** No tracker block (absent, or a skip
   marker) means no slot is configured. With a `<slot>` argument, the
   set is that one slot, configured or not; without one, it is every
   key under `fields:` — and with no block, the output is the single
   line `No fields configured.` instead of per-slot blocks.

3. **Render each slot** by its `kind:`, reading the slot's shape from
   the kind's own schema — `skills/lib/issue.md` "Field kinds" for the
   `github-project:` block, `skills/lib/repo-config.md` for the
   `jira:` block:

   - A kind whose schema carries `options:` reports its option names.
   - `kind: number` reports the range bounds its schema declares.
   - `kind: skip` reports unconfigured.

   A slot absent from `fields:` reports unconfigured, exactly as
   `kind: skip` does — the namespace treats the two as equivalent.
   Option names keep the key's capitalization and the order the
   config lists them in; never sort them. An option's ID is never
   printed.

4. **Write nothing.** No issue, config, or tracker state changes.

## Output

One block per slot, separated by a blank line. An option-carrying
slot prints its kind, then one option name per line:

```text
status: single-select
  Backlog
  Ready
  In progress
  In review
  Done
```

A `kind: number` slot prints its bounds instead of options:

```text
priority: number
  min: 1
  max: 9
```

An unconfigured slot — `kind: skip`, or absent from `fields:`, or no
tracker block at all — prints one line and exits zero, with no
warning:

```text
effort: unconfigured
```
