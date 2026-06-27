---
name: claude-vm-config-repo
description: Interactively create the per-repo claude-vm config at <repo>/.claude-vm/config.yml, writing ONLY the keys this repo overrides on top of the global config (e.g. bump mem 4096 -> 6144 for a heavy-build repo). Reads the global config as the basis so you see what you are overriding. Idempotent — detects an existing per-repo file and offers to merge or leave rather than clobber.
---

# claude-vm-config-repo

You are running the `/claude-vm-config-repo` skill. Your job is to
create the **per-repo** claude-vm config file at
`<repo>/.claude-vm/config.yml` from the keys this repo wants to override
on top of the global config.

This file is the project-specific layer of claude-vm's two-tier config.
At runtime, `payload/lib/config.sh` layers it over the machine-wide
global config (`~/.config/claude-vm/config.yml`): **scalars** in this
file win over the global value, and **lists** (`egress.allow`, `mounts`)
are unioned with the global lists. The config surface, layering
semantics, and key meanings are documented in the sibling `claude-vm`
skill (`skills/claude-vm/SKILL.md`) and the annotated
`payload/config.example.yml`.

It is the second slice of the claude-vm config work, the per-repo
analogue of `/claude-vm-config-global` (slice 1). Because the layering
merges the two files at runtime, this file holds **only the overrides** —
not a full duplicate of the global config. The motivating case: a
heavy-build repo bumps `mem` from the global `4096` to `6144` without
touching the machine-wide default.

## Write only the overridden keys

The single most important rule of this skill: the per-repo file contains
**only the keys that differ from the global config** (plus any list
entries this repo adds). Do not copy the resolved global values into the
per-repo file. The layering library fills every un-overridden key from
the global layer at runtime; duplicating them here would mean the repo
file silently shadows future changes to the global default.

- **Scalars** (`cpus`, `mem`, `guest_image`, `repo.mount`,
  `repo.copy_back`, `proxy.*`): write a key only if the user wants this
  repo to use a different value than the global config resolves to.
- **Lists** (`egress.allow`, `mounts`): write only the **additional**
  entries this repo needs. The runtime union keeps the global entries;
  the per-repo file does not need to restate them. (The library cannot
  *remove* a global entry from a list — the union only adds — so a repo
  cannot subtract a global egress host. If the user asks to drop a
  global host, explain that lists union and the removal must happen in
  the global config.)

## Idempotent — detect and offer, never clobber

This skill is **idempotent**. Before writing anything it checks whether
`<repo>/.claude-vm/config.yml` already exists:

- **If it does not exist**: this is the create path. Propose the
  overrides-only file, get approval, write it.
- **If it already exists**: **do not clobber it.** Read it, show the
  user what is there, and offer two choices:
  1. **Leave** the existing file untouched (the default, safe choice).
  2. **Merge** the new overrides in for any keys the existing file is
     missing, preserving every key the user already set.

  Never overwrite a key the user already set on the "merge" path, and
  never delete a key. A merge only *fills gaps* (and, for lists, unions
  new entries in). If the existing file already has every override the
  user wants, report that it is already complete and leave it untouched.

Writing the file requires explicit user approval in every case.

## Steps

Follow these in order. Do not write the file until the user has
explicitly approved the proposed content.

### Step 1: Confirm you are in a repo and resolve the target path

Find the repo root with `git rev-parse --show-toplevel`. This matches
how the launcher resolves the per-repo config:
`REPO_CONFIG="${CLAUDE_VM_REPO_CONFIG:-$REPO_SRC/.claude-vm/config.yml}"`
in `payload/claude-vm.sh`, where `$REPO_SRC` is itself the
`git rev-parse --show-toplevel` of the launch target.

```bash
git rev-parse --show-toplevel
```

- If this fails (not inside a git work tree), stop and tell the user
  this skill must be run from inside a repo, since the per-repo config
  is repo-scoped. Do not write anything.
- On success, the target path is `<repo-root>/.claude-vm/config.yml`.
  The `.claude-vm/` directory may not exist yet; the `Write` tool
  creates it.

### Step 2: Read the global config as the basis for overrides

Resolve the global config path the same way the launcher does:
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/config.yml` (matching the
`CLAUDE_VM_GLOBAL_CONFIG` default in `payload/lib/config.sh`).

- **If the global config is absent**: there is nothing to override
  against. Tell the user the global layer does not exist yet and point
  them at `/claude-vm-config-global` to create it first. You may still
  proceed to write per-repo overrides if the user insists (the launcher
  also has hardcoded fallbacks: `cpus 4`, `mem 8192`, `repo.mount
  clone`, `repo.copy_back local`, `proxy.port 3128`, `proxy.host_alias
  192.168.127.254`), but make clear what the effective baseline is.
- **If the global config is present**: read it and present its resolved
  values as the **basis** — so the user sees exactly what each key is
  currently set to and therefore what they would be overriding. Show the
  scalars and the global `egress.allow` / `mounts` lists.

### Step 3: Collect the overrides

Ask the user which keys this repo should override. Frame each against the
global value from Step 2, e.g. "Global `mem` is `4096`; what should this
repo use?" The common cases:

- A scalar override (the motivating case: `mem: 6144` for a heavy-build
  repo, while global stays `4096`).
- Extra `egress.allow` hosts this repo's build/test needs (e.g. a
  package registry). These union with the global allowlist.
- Extra `mounts` this repo needs.

Record **only** the keys that differ from the global resolved value. If
the user names a value identical to the global one, note that it is
already the effective value and does not need a per-repo override —
offer to omit it (a redundant override only adds drift risk).

### Step 4: Compose the proposed content

**Create variant** (no existing per-repo file): an overrides-only file.
For the motivating `mem` bump, that is as small as:

```yaml
# claude-vm per-repo config overrides (<repo-name>).
#
# Layered OVER the global config at ~/.config/claude-vm/config.yml by
# payload/lib/config.sh: scalars here win over the global value; lists
# (egress.allow, mounts) UNION with the global lists. This file holds
# ONLY the keys this repo overrides — every other key is filled from the
# global layer at runtime. See the claude-vm skill
# (skills/claude-vm/SKILL.md) and payload/config.example.yml for the full
# schema and layering rules.
#
# NO SECRETS HERE. The host claude.ai OAuth credential is mounted into
# the guest at runtime by the launcher; it is never read from or written
# to this file.

# This repo runs heavier builds than the global default; bump mem.
mem: 6144
```

Include only the keys the user chose in Step 3. Do not pad the file with
the global values — that defeats the layering.

**Merge variant** (existing per-repo file): start from the existing
parsed YAML and add **only** the new override keys that are absent. Keep
every existing key and value verbatim, including any the user customized
and any this skill does not recognize. For list keys (`egress.allow`,
`mounts`), union the new entries in (do not drop the existing extras, do
not duplicate). Render the merged result preserving the user's existing
comments where practical.

### Step 5: Show the proposed file and get approval

Render the **full proposed file** exactly as it will land on disk. Also
show a short summary that makes the layering explicit:

- For the create variant: which keys this file overrides and what the
  global value was for each (e.g. "overrides `mem`: 4096 → 6144; all
  other keys inherited from global").
- For the merge variant: which keys this run adds, which it preserves
  untouched.

Then ask explicitly:

> Write `<repo>/.claude-vm/config.yml` as shown? (y to proceed, or tell
> me what to change)

Wait for explicit approval. If the user asks for changes, adjust and
re-render here.

### Step 6: Write, verify, and confirm the layering

On approval, use the `Write` tool to write the full content in one call.
The `.claude-vm/` parent directory is created if needed.

After the `Write`, re-read the file and confirm it parses as YAML and
contains exactly the override keys you intended (and no accidental
duplicates of global values). This is content verification — `Write`
already errors if the bytes did not land; the re-read confirms the
*intended content*.

Then demonstrate that the existing layering library resolves
repo-over-global correctly, using the project's own test as the
authority. Run the config layering test (it requires no VM and no
network):

```bash
plugins/claude-vm/payload/test/config-test.sh
```

Confirm it reports `0 failed`. This is the existing test the issue asks
you to run: it exercises `payload/lib/config.sh`'s scalar-override and
list-union semantics directly, which is the machinery that makes this
per-repo file's overrides take effect.

If you want to additionally show this specific file resolving against the
global config, you can source the library and merge the two real files
(read-only, no host mutation):

```bash
. plugins/claude-vm/payload/lib/config.sh
claude_vm_merge_config \
  "${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/config.yml" \
  "$(git rev-parse --show-toplevel)/.claude-vm/config.yml" \
  | yq eval '.mem' -    # read back the key you overrode (.mem here) to
                        # see the per-repo value winning over the global one
```

Report back:

- The absolute path written (or "left untouched" / "already complete").
- The override keys this file sets and the global value each replaces
  (or the list entries it adds).
- For a merge, which keys were added vs. preserved.
- The config-test result (`N passed, 0 failed`).
- A reminder that every un-overridden key is inherited from the global
  config at runtime, and that no secret is ever written here.

## Hard constraints

- **Overrides only.** The per-repo file contains only the keys that
  differ from the global config (and the list entries this repo adds).
  Never duplicate resolved global values into it.
- **Read the global config first** and present its values as the basis,
  so the user sees what they are overriding. If the global config is
  absent, point them at `/claude-vm-config-global` before proceeding.
- **Idempotent.** Never clobber an existing per-repo config. Detect it,
  and offer leave (default) or gap-fill merge. A merge fills gaps and
  unions list entries only — it never overwrites or deletes a key the
  user set.
- **No secrets in this file.** The host claude.ai OAuth credential is
  supplied at runtime, never written to config.
- **Never write without explicit approval** in Step 5.
- **Lists union, they do not subtract.** A per-repo file cannot remove a
  global `egress.allow` host or a global mount; the runtime merge only
  adds. If the user wants to drop a global entry, that edit belongs in
  the global config.
- **Write exactly one file**: `<repo>/.claude-vm/config.yml`. This skill
  does not edit `.gitignore`, does not touch the global config, and runs
  no git commands beyond the read-only `git rev-parse --show-toplevel`
  used to locate the repo root (and the read-only test invocation in
  Step 6).
