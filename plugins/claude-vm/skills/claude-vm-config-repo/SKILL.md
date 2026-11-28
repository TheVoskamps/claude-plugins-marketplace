---
name: claude-vm-config-repo
description: Interactively create the per-repo claude-vm config PAIR at <repo>/.claude-vm/config-bake.yml + config-boot.yml, writing ONLY the keys this repo overrides on top of the global config (e.g. bump mem for a heavy-build repo), each in the file the launcher's own key table (claude-vm-config-keys) names. Reads the global config as the basis so you see what you are overriding. Idempotent — detects existing per-repo files and offers to merge or leave rather than clobber.
---

# claude-vm-config-repo

You are running the `/claude-vm-config-repo` skill. Your job is to
create the **per-repo** claude-vm config **pair** at
`<repo>/.claude-vm/config-bake.yml` and
`<repo>/.claude-vm/config-boot.yml` from the keys this repo overrides on
top of the global config.

This pair is the project-specific layer of claude-vm's four-file config,
the per-repo analogue of `/claude-vm-config-global`. Either file is
optional: a repo may ship only a boot file, only a bake file, or neither.
Shipping a `config-bake.yml` at all gives the repo its own image, so a
repo that overrides only run-time keys keeps sharing the global image.

## The schema comes from the launcher

Run the key table and read the meanings before composing anything:

```bash
claude-vm-config-keys
```

It prints one key per line as the tab-separated fields key, file (`bake`,
`boot` or `both`), type, `list` or `scalar`, and default. It is the
launcher's own table, so it is the only source for which keys exist,
which file each goes in, how each merges, and what each defaults to when
neither tier sets it. Never write a key it does not print.

Read `${CLAUDE_PLUGIN_ROOT}/skills/claude-vm/config-keys.md` for what
each key means, which values the launcher rejects, how a key whose file
is `both` differs between the two files, and how the tiers layer.

## Write only the overridden keys

The per-repo files contain **only the keys that differ from the global
config**, plus any list entries this repo adds. The merge fills every
un-overridden key from the global layer at launch; copying a global value
here would make the repo file silently shadow later changes to it.

- A **scalar**: write it only when this repo needs a different value
  than the global config resolves to.
- A **map** (`map(...)` type): write only the entries this repo changes;
  the map merges per key.
- A **list**: write only the additional entries. Lists union, so a repo
  cannot remove a global entry; if the user asks to drop one, explain that
  the removal belongs in the global config.

## Idempotent — detect and offer, never clobber

Before writing anything, check each of the two files independently:

- **Absent**: this is the create path for that file. Propose the
  overrides-only file, get approval, write it. If a file's tier has no
  overrides, do not write it at all.
- **Present**: **do not clobber it.** Read it, show the user what is
  there, and offer:
  1. **Leave** the existing file untouched (the default, safe choice).
  2. **Merge** the new overrides in for any keys it is missing,
     preserving every key the user already set.

  A merge only fills gaps and unions new list entries in; it never
  overwrites or deletes a key the user set. If the file already has every
  override the user wants, report that it is complete and leave it.

Writing a file requires explicit user approval in every case.

## Steps

Do not write a file until the user has explicitly approved its content.

### Step 1: Confirm you are in a repo and resolve the target paths

```bash
git rev-parse --show-toplevel
```

The launcher resolves the per-repo pair as
`$REPO_SRC/.claude-vm/config-{bake,boot}.yml`, where `$REPO_SRC` is this
same top level of the launch target.

- If it fails (not inside a git work tree), stop and tell the user this
  skill must run from inside a repo. Write nothing.
- On success, the targets are `<repo-root>/.claude-vm/config-bake.yml`
  and `<repo-root>/.claude-vm/config-boot.yml`. The directory may not
  exist yet; the `Write` tool creates it. Also check for a legacy
  `<repo-root>/.claude-vm/config.yml`, which the launcher aborts on, and
  offer to migrate its keys into the pair, placing each by the key
  table's file column.

### Step 2: Read the global config as the basis

Read `${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/config-bake.yml` and
`config-boot.yml`, the launcher's `CLAUDE_VM_GLOBAL_*_CONFIG` defaults.

- **Absent**: tell the user the global layer does not exist yet and point
  them at `/claude-vm-config-global`. Proceed only if they insist, and
  then show the table's defaults as the effective baseline.
- **Present**: show its resolved values as the basis, so the user sees
  what each override replaces — the scalars, the list entries, and the
  `env` block. Show `env.set` names and values, which are non-secret by
  construction, but only the names under `env.copy`; never resolve one
  against the environment. The `mounts` checks run over the merged global
  and repo list, so a per-repo entry can collide with a global one, while
  a per-repo `env.set` name that repeats a global one silently replaces
  it. Showing both is what lets the user see either coming.

### Step 3: Collect the overrides

Ask which keys this repo overrides, framing each against the global value
from Step 2 — "global `mem` is 4096; what should this repo use?" — and
place each in the file its table row names. Ask by feature area (VM
resources, egress, mounts, packages, plugins, environment variables) and
fold the answers onto rows. For an `env.copy` entry, add its provider's
host to `egress.allow` in the same file, or write neither.

Record **only** the keys that differ from the global value. When the user
names a value identical to the global one, say it is already the
effective value and offer to omit it.

### Step 4: Compose the proposed content

Each file starts with a comment naming it as this repo's bake or boot
overrides and stating that it holds no secrets, then only the keys from
Step 3 as YAML, nested by their dotted path. A key the user did not
override is absent: an empty `claude.plugins` or `env` sub-key in the
wrong file aborts the launch.

### Step 5: Show the proposed files and get approval

Render each full proposed file exactly as it will land on disk, with a
summary of what it overrides and the global value each replaces (for a
merge, which keys this run adds and which it preserves). Then ask, per
file:

> Write `<repo>/.claude-vm/config-bake.yml` (and/or `config-boot.yml`)
> as shown? (y to proceed, or tell me what to change)

Wait for explicit approval, and re-render on any change.

### Step 6: Write, verify, and confirm the layering

On approval, write each full file in one `Write` call. Then re-read it
and confirm it parses as YAML and holds exactly the intended overrides,
each in the file its table row names, with no copies of global values.

Then run the config layering test, which needs no VM and no network:

```bash
plugins/claude-vm/payload/test/config-test.sh
```

Confirm it reports `0 failed`. To show this pair resolving against the
global one, check the real files as the launcher does and merge them
read-only, reading back the key you overrode:

```bash
. plugins/claude-vm/payload/lib/config.sh
GD="${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm"
RD="$(git rev-parse --show-toplevel)/.claude-vm"
claude_vm_require_yq \
  && claude_vm_check_no_aliases "$GD/config-boot.yml" "$RD/config-boot.yml" \
  && claude_vm_check_config_structure "$GD/config-boot.yml" "$RD/config-boot.yml" \
  && claude_vm_merge_config "$GD/config-boot.yml" "$RD/config-boot.yml" \
  | yq eval '.mem' -
```

A diagnostic from either config check is a fault in the file it names:
fix it there before you report.

Report back:

- The absolute path(s) written, or "left untouched" / "already complete".
- The keys each file overrides and the global value each replaces, or
  the list entries it adds; for a merge, which keys were added and which
  preserved.
- The config-test result (`N passed, 0 failed`).
- That every un-overridden key is inherited from the global config at
  launch, and that no secret is written here.

## Hard constraints

- **Overrides only.** Never copy a resolved global value into a per-repo
  file.
- **Read the global config first** and present it as the basis.
- **Idempotent.** Never clobber an existing per-repo config; offer leave
  (the default) or a gap-filling merge.
- **The key table decides placement.** Every key goes in the file its
  `claude-vm-config-keys` row names. Never write a key the table does not
  print.
- **No secrets.** A third-party API key goes in `env.copy` by name or
  `env.files` by path: never ask the user to paste a key, and never read
  one out of their environment to echo it back.
- **Never write without explicit approval** in Step 5.
- **Write at most the two per-repo files**, only the tiers with
  overrides. This skill does not edit `.gitignore`, does not touch the
  global config, and runs no git command beyond the read-only
  `git rev-parse --show-toplevel`.
