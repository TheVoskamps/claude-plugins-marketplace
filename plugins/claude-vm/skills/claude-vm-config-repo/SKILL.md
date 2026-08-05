---
name: claude-vm-config-repo
description: Interactively create the per-repo claude-vm config PAIR at <repo>/.claude-vm/config-bake.yml + config-boot.yml, writing ONLY the keys this repo overrides on top of the global config (e.g. bump mem 4096 -> 6144 for a heavy-build repo). Reads the global config as the basis so you see what you are overriding. Idempotent — detects existing per-repo files and offers to merge or leave rather than clobber.
---

# claude-vm-config-repo

You are running the `/claude-vm-config-repo` skill. Your job is to
create the **per-repo** claude-vm config **pair** at
`<repo>/.claude-vm/config-bake.yml` and
`<repo>/.claude-vm/config-boot.yml` from the keys this repo wants to
override on top of the global config.

Since issue #179, claude-vm's config is split into a **bake** file and a
**boot** file per tier. Which of the two per-repo files a given override
lands in follows the placement rule:

- **`config-bake.yml`** — image-bytes keys: `packages:` (a flat list of
  apt packages baked into the image), `apt_sources:`,
  `image.root_headroom_mb`, `claude.marketplaces`, and
  `claude.plugins.bake` (the `plugin@marketplace` refs installed into the
  image). A repo that ships a `config-bake.yml` gets
  its **own** image (its name in the filename); its content is
  whole-file, raw-byte hashed.
- **`config-boot.yml`** — run-time keys: `cpus`, `mem`, `proxy.*`,
  `egress.allow`, `mounts`, `repo.*`, `packages:` here means **installed
  at boot** (a flat list), `update_at_boot`, `add_apt_uris_to_allowlist`,
  `claude.*`, `github.*`. Boot files never affect image identity.

This pair is the project-specific layer of claude-vm's four-file config.
At runtime, `payload/lib/config.sh` composes all four files (global
bake+boot, repo bake+boot): **scalars** in a repo file win over the
global value, and **lists** (bake file: `packages`, `apt_sources`,
`claude.marketplaces`, `claude.plugins.bake`; boot
file: `egress.allow`, `mounts`, `packages`, `apt_sources`,
`claude.permissions.allow`/`.ask`/`.deny`, `claude.marketplaces`,
`claude.plugins.install_at_boot`) are unioned with the global
lists. The config surface, layering semantics, and key meanings are
documented in the sibling `claude-vm` skill
(`skills/claude-vm/SKILL.md`) and the annotated
`payload/config-bake.example.yml` / `payload/config-boot.example.yml`.

It is the per-repo analogue of `/claude-vm-config-global`. Because the
layering merges all four files at runtime, these files hold **only the
overrides** — not a full duplicate of the global config. The motivating
case: a heavy-build repo bumps `mem` from the global `4096` to `6144`
(in `config-boot.yml`) without touching the machine-wide default. A repo
pair is OPTIONAL: a repo may ship only a boot file, only a bake file, or
neither.

**Migration:** if a legacy `<repo>/.claude-vm/config.yml` exists, the
launcher aborts with a migration message. When this skill detects it,
offer to migrate its keys into the bake/boot pair per the placement rule,
then remind the user to remove or rename the legacy file.

## Write only the overridden keys

The single most important rule of this skill: the per-repo file contains
**only the keys that differ from the global config** (plus any list
entries this repo adds). Do not copy the resolved global values into the
per-repo file. The layering library fills every un-overridden key from
the global layer at runtime; duplicating them here would mean the repo
file silently shadows future changes to the global default.

- **Scalars.** In `config-boot.yml`: `cpus`, `mem`, `guest_image`,
  `repo.mount`, `repo.copy_back`, `proxy.*`, `claude.version`,
  `claude.renderer`, `claude.remote_control`, `update_at_boot`,
  `add_apt_uris_to_allowlist`, `claude.permission_mode`,
  `claude.plugins.update_at_boot`,
  `claude.plugins.add_marketplace_uris_to_allowlist`, `github.auth`.
  In `config-bake.yml`: `image.root_headroom_mb`. Write a key only if
  the user wants this repo to use a different value than the global
  config resolves to.
  (`image.root_headroom_mb` sets the guest root filesystem's free margin
  above its base content; bump it for a repo whose sessions install many
  packages or otherwise grow the guest disk more than the 1024 MB
  default anticipates. It lives in the BAKE file — so setting it makes
  this repo get its own image
  `guest+global<hash>+<reponame>-<repohash>.raw` and triggers a rebuild
  for this repo. Merely creating a `config-bake.yml` at all gives the
  repo its own image; a repo that overrides only run-time keys puts them
  in `config-boot.yml` and keeps sharing the global image.)
  (`claude.renderer` selects the interactive-console terminal renderer:
  `classic` | `fullscreen` | unset; an unrecognized value aborts the
  launch. `claude.remote_control` is an opt-in boolean — `true` adds
  `--remote-control` plus a date-stamped `--name` default to the in-guest
  claude invocation; `false`/unset passes the CLI args through unchanged;
  any other value aborts the launch. Setting it here lets one repo opt in
  to Remote Control without turning it on globally. `claude.permission_mode`
  is rendered into the guest `settings.json` (issue #104:
  `permission_mode` → `permissions.defaultMode`; only `bypassPermissions` /
  `default` are accepted, anything else aborts the launch). The remaining
  guest-capability keys are consumed as follows: the boot file's
  `update_at_boot`/`add_apt_uris_to_allowlist` drive the guest's boot-time
  apt phase (issue #106) and
  `claude.plugins.update_at_boot`/`.add_marketplace_uris_to_allowlist` its
  boot-time plugin phase and derived marketplace egress (issue #107).
  `github.auth` is schema + merge only as of issue #103 — its consumer
  lands in a sibling slice under #39, but this repo's override still
  resolves correctly through the layering library today.)
- **Scalar maps** (`claude.plugins.enabled`): a map of plugin ref →
  boolean that merges repo-over-global **per key**, so this repo can flip
  one plugin's enabled state (e.g. `false` = installed-but-disabled)
  without restating the global map. It is rendered into the guest
  `settings.json`'s `enabledPlugins` (issue #104); keys must name a ref in
  `claude.plugins.bake`/`.install_at_boot` and values must be boolean, or
  the launch aborts.
- **Lists.** In `config-bake.yml`: `packages` (baked into the image),
  `apt_sources`, `claude.marketplaces`, `claude.plugins.bake` (installed
  into the image). In `config-boot.yml`: `egress.allow`, `mounts`,
  `packages` (installed at boot), `apt_sources`,
  `claude.permissions.allow`/`.ask`/`.deny`, `claude.marketplaces`,
  `claude.plugins.install_at_boot`. Write only the
  **additional** entries this repo needs. The runtime union keeps the
  global entries; the per-repo file does not need to restate them. (The
  library cannot *remove* a global entry from a list — the union only
  adds — so a repo cannot subtract a global egress host, apt package,
  permission rule, marketplace, or plugin. If the user asks to drop a
  global entry, explain that lists union and the removal must happen in
  the global config. `claude.permissions.*` and `claude.plugins.bake`/
  `.install_at_boot` feed the rendered guest `settings.json`
  (issue #104) after the union resolves. `apt_sources` and
  `claude.marketplaces` may each appear in BOTH the bake and boot
  files — union, deduped by `name`; the same name with DIFFERING content
  (`{repo, key_url}` / `url`) aborts the launch, so keep each name's
  content identical across files or give it a unique name. A
  `claude.marketplaces` entry with a url and no `name` aborts the launch
  as well (issue #226) — the name is what every consumer matches on.
  Which file a marketplace lands in decides its build-time failure
  policy: one in the bake file must register at build time or the build
  aborts, so its url has to be reachable from the build container, while
  one in the boot
  file only has to be reachable from the **guest** — put a guest-local
  path like `/mnt/repo`, or a private source needing host-only
  credentials, in the boot file, where a build that cannot reach it
  warns and the guest adds it at boot (issue #226). A
  `claude.plugins` sub-key written into the wrong file type aborts the
  launch too: `bake` belongs in the bake file, `install_at_boot` /
  `update_at_boot` / `add_marketplace_uris_to_allowlist` / `enabled` in
  the boot file.)

## Idempotent — detect and offer, never clobber

This skill is **idempotent**. Before writing anything it checks each of
`<repo>/.claude-vm/config-bake.yml` and
`<repo>/.claude-vm/config-boot.yml` independently:

- **If a file does not exist**: this is the create path for that file.
  Propose the overrides-only file, get approval, write it. (If a tier
  has no overrides, do not write that file at all — the pair is
  optional.)
- **If a file already exists**: **do not clobber it.** Read it, show the
  user what is there, and offer these choices:
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

### Step 1: Confirm you are in a repo and resolve the target paths

Find the repo root with `git rev-parse --show-toplevel`. This matches
how the launcher resolves the per-repo config:
`REPO_BAKE_CONFIG="${CLAUDE_VM_REPO_BAKE_CONFIG:-$REPO_SRC/.claude-vm/config-bake.yml}"`
and the boot analogue in `payload/claude-vm.sh`, where `$REPO_SRC` is
itself the `git rev-parse --show-toplevel` of the launch target.

```bash
git rev-parse --show-toplevel
```

- If this fails (not inside a git work tree), stop and tell the user
  this skill must be run from inside a repo, since the per-repo config
  is repo-scoped. Do not write anything.
- On success, the target paths are
  `<repo-root>/.claude-vm/config-bake.yml` and
  `<repo-root>/.claude-vm/config-boot.yml`. The `.claude-vm/` directory
  may not exist yet; the `Write` tool creates it. Also check for a
  legacy `<repo-root>/.claude-vm/config.yml` (offer migration if found).

### Step 2: Read the global config as the basis for overrides

Resolve the global config pair the same way the launcher does:
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/config-bake.yml` and
`config-boot.yml` (matching the `CLAUDE_VM_GLOBAL_*_CONFIG` defaults in
`payload/lib/config.sh`).

- **If the global config is absent**: there is nothing to override
  against. Tell the user the global layer does not exist yet and point
  them at `/claude-vm-config-global` to create it first. You may still
  proceed to write per-repo overrides if the user insists (the launcher
  also has hardcoded fallbacks: `cpus 4`, `mem 8192`, `repo.mount
  clone`, `repo.copy_back local`, `proxy.port 3128`, `proxy.host_alias
  192.168.127.254`), but make clear what the effective baseline is.
- **If the global config is present**: read both global files and
  present their resolved values as the **basis** — so the user sees
  exactly what each key is currently set to and therefore what they
  would be overriding. Show the scalars and the global `egress.allow` /
  `mounts` / baked-`packages` lists.

### Step 3: Collect the overrides

Ask the user which keys this repo should override. Frame each against the
global value from Step 2, e.g. "Global `mem` is `4096`; what should this
repo use?" The common cases:

- A scalar override (the motivating case: `mem: 6144` for a heavy-build
  repo, while global stays `4096`).
- Extra `egress.allow` hosts this repo's build/test needs (e.g. a
  package registry). These union with the global allowlist.
- Extra `mounts` this repo needs. Each entry takes a `source:` (a host
  directory, or a single file) and a `tag:`, plus an optional `mode:`
  (`ro` default, or `rw`) and an optional absolute `path:` (the guest
  mountpoint, default `/mnt/<tag>`). The guest mounts each share *by*
  its tag, and every mistake aborts the launch rather than booting
  without the mount: a missing `source:`/`tag:` (issue #226), a
  `source:` that is not on the host, a `tag:` that is reserved
  (`repo`/`runconfig`/`claudebin`/`claudecreds`), outside
  `[A-Za-z0-9._-]`, or repeated, a `mode:` other than `ro`/`rw`, and a
  `path:` that is relative, carries `..`, overlaps one of claude-vm's own
  guest mountpoints, or duplicates another entry's (issue #157).
  *Overlaps* is wider than equals: a `path:` above a reserved mountpoint
  (`/mnt`, `/`) or inside one (`/mnt/repo/sub`) is rejected too, so never
  offer a `path:` under `/mnt/<built-in tag>`. The tag
  and path checks run over the **merged** global+repo list, so a
  per-repo entry can collide with a global one — check Step 2's global
  `mounts` before writing a tag or path.
  **`mode: rw` pierces the VM isolation boundary for that path**: it is
  an enforced mount option, and the guest's writes land on the host
  directory live, with no copy-back step. Only write `rw` when the user
  asks for it explicitly.
  A single-file `source:` is shared by wrapping it in a per-entry
  directory and bind-mounting the one file in the guest, so it carries a
  caveat a directory mount does not: the kernel refuses a `rename(2)`
  onto a file bind mount with `EBUSY`, so an `rw` single-file mount takes
  in-place edits but not the write-a-temp-then-rename pattern
  `git config`, `sed -i` and most editors use. When the user wants the
  guest to rewrite a file wholesale — `~/.gitconfig` is the usual case —
  offer its containing **directory** as the `source:` instead.
- Extra apt packages this repo's build needs beyond the global set:
  baked into the image (bake file `packages:`) or installed at boot
  (boot file `packages:`), plus any third-party `apt_sources` (either
  file). These union with the global lists.
- Extra `claude.permissions.allow`/`.ask`/`.deny` rules (boot file),
  `claude.marketplaces` (either file), `claude.plugins.bake` entries
  (bake file — baked into this repo's own image), or
  `claude.plugins.install_at_boot` entries (boot file) this repo needs.
  These union with the global lists.
- A `claude.permission_mode`, a `claude.plugins.enabled` per-plugin
  toggle, or a `github.auth` override this repo needs that differs from
  global.

Record **only** the keys that differ from the global resolved value. If
the user names a value identical to the global one, note that it is
already the effective value and does not need a per-repo override —
offer to omit it (a redundant override only adds drift risk).

### Step 4: Compose the proposed content

**Create variant** (no existing per-repo file). Write only the file(s)
whose tier has overrides. For the motivating `mem` bump (a run-time
key), that is just `config-boot.yml`, as small as:

```yaml
# claude-vm per-repo BOOT config overrides (<repo-name>).
#
# Run-time keys layered OVER the global config by payload/lib/config.sh:
# scalars here win; lists (egress.allow, mounts, ...) UNION with the
# global lists. Holds ONLY this repo's overrides. Boot keys never affect
# the image identity. See the claude-vm skill (skills/claude-vm/SKILL.md)
# and payload/config-boot.example.yml.
#
# NO SECRETS HERE.

# This repo runs heavier builds than the global default; bump mem.
mem: 6144
```

For a repo that also bakes packages into its own image, the paired
`config-bake.yml` looks like:

```yaml
# claude-vm per-repo BAKE config overrides (<repo-name>).
#
# Image-bytes keys. Creating this file gives the repo its OWN image
# (guest+global<hash>+<reponame>-<repohash>.raw), whole-file raw-byte
# hashed. See payload/config-bake.example.yml.
#
# NO SECRETS HERE.

# Extra apt packages this repo bakes into its image (union with global).
packages:
  - protobuf-compiler
```

Include only the keys the user chose in Step 3, each in its correct
bake/boot file. Do not pad the file with the global values — that
defeats the layering.

**Merge variant** (existing per-repo file): start from the existing
parsed YAML and add **only** the new override keys that are absent. Keep
every existing key and value verbatim, including any the user customized
and any this skill does not recognize. For list keys (bake file:
`packages`, `apt_sources`, `claude.marketplaces`,
`claude.plugins.bake`; boot file: `egress.allow`, `mounts`,
`packages`, `apt_sources`, `claude.permissions.allow`/`.ask`/`.deny`,
`claude.marketplaces`, `claude.plugins.install_at_boot`), union
the new entries in (do not drop the existing extras, do not duplicate).
Render the merged result preserving the user's existing comments where
practical.

### Step 5: Show the proposed file and get approval

Render the **full proposed file** exactly as it will land on disk. Also
show a short summary that makes the layering explicit:

- For the create variant: which keys this file overrides and what the
  global value was for each (e.g. "overrides `mem`: 4096 → 6144; all
  other keys inherited from global").
- For the merge variant: which keys this run adds, which it preserves
  untouched.

Then ask explicitly, per file:

> Write `<repo>/.claude-vm/config-bake.yml` (and/or `config-boot.yml`)
> as shown? (y to proceed, or tell me what to change)

Wait for explicit approval. If the user asks for changes, adjust and
re-render here.

### Step 6: Write, verify, and confirm the layering

On approval, use the `Write` tool to write each file's full content in
one call. The `.claude-vm/` parent directory is created if needed.

After each `Write`, re-read the file and confirm it parses as YAML and
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

Confirm it reports `0 failed`. It exercises `payload/lib/config.sh`'s
per-tier merge, scalar-override, and list-union semantics directly —
the machinery that makes this per-repo pair's overrides take effect.

If you want to additionally show this specific pair resolving against the
global config, you can source the library and merge the real files per
tier (read-only, no host mutation) — the boot pair here, since boot keys
are where per-repo overrides usually live:

```bash
. plugins/claude-vm/payload/lib/config.sh
GD="${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm"
RD="$(git rev-parse --show-toplevel)/.claude-vm"
claude_vm_merge_config "$GD/config-boot.yml" "$RD/config-boot.yml" \
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
  global `egress.allow` host, a global mount, or a global entry in the
  baked/boot `packages`, `apt_sources`,
  `claude.permissions.allow`/`.ask`/`.deny`, `claude.marketplaces`, or
  `claude.plugins.bake`/`.install_at_boot`; the runtime merge only adds.
  If the user wants to drop a global entry, that edit belongs in the
  global config.
- **Respect the bake/boot placement rule.** Image-bytes overrides
  (`packages` baked in, `apt_sources`, `image.root_headroom_mb`,
  `claude.plugins.bake`) go in `config-bake.yml`; run-time overrides go
  in `config-boot.yml`. A misplaced key loudly does nothing rather than
  silently poisoning the image cache, and a misplaced `claude.plugins`
  sub-key aborts the launch outright.
- **Write at most the two per-repo files**:
  `<repo>/.claude-vm/config-bake.yml` and
  `<repo>/.claude-vm/config-boot.yml` (only the tier(s) with overrides).
  This skill does not edit `.gitignore`, does not touch the global
  config, and runs no git commands beyond the read-only
  `git rev-parse --show-toplevel` used to locate the repo root (and the
  read-only test invocation in Step 6).
