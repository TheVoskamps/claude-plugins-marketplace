---
name: claude-vm-config-global
description: Interactively create the global claude-vm config PAIR at ~/.config/claude-vm/config-bake.yml + config-boot.yml from the resolved defaults (cpus 2, mem 4096, bundled-tinyproxy proxy default, egress.allow incl. api.anthropic.com, claude.version). Idempotent — detects existing files and offers to merge or leave rather than clobber.
---

# claude-vm-config-global

You are running the `/claude-vm-config-global` skill. Your job is to
create the **global** claude-vm config **pair** at
`~/.config/claude-vm/config-bake.yml` and
`~/.config/claude-vm/config-boot.yml` (expand `~` to the user's home
directory) from the resolved defaults.

Since issue #179, claude-vm's config is split into a **bake** file and a
**boot** file per tier (four files total, all optional):

- **`config-bake.yml`** — keys that change **bytes in the guest `.raw`
  image**: `packages:` (a flat list of apt packages baked into the
  image), `apt_sources:` (third-party apt repos rendered into the
  image), and `image.root_headroom_mb`. The image cache key + filename
  is a **whole-file, raw-byte hash** of the bake files, so editing a
  bake file (including only its trailing newline) rebuilds the image.
- **`config-boot.yml`** — keys applied at **run time** (launcher/VM
  wiring): `cpus`, `mem`, `proxy.*`, `egress.allow`, `mounts`,
  `repo.*`, `packages:` here means **installed at boot** (a flat list),
  `update_at_boot`, `add_apt_uris_to_allowlist`, `claude.*`, and
  `github.*`. Boot files never affect image
  identity.

This pair is the machine-wide layer of claude-vm's four-file config (the
per-repo pair at `<repo>/.claude-vm/config-{bake,boot}.yml`, written by
`/claude-vm-config-repo`, overrides it). The config surface, layering
semantics, and key meanings are documented in the sibling `claude-vm`
skill (`skills/claude-vm/SKILL.md`) and the annotated
`payload/config-bake.example.yml` / `payload/config-boot.example.yml`.
This skill writes the global layer with the resolved defaults rather
than the examples' illustrative placeholders.

**Migration:** if a legacy single-file `~/.config/claude-vm/config.yml`
exists, the launcher aborts with a migration message (it will not
silently read it). When this skill detects that legacy file, offer to
migrate: split its keys into the bake/boot pair per the placement rule
above, write the pair, and tell the user to remove or rename the legacy
`config.yml` afterward.

## Idempotent — detect and offer, never clobber

This skill is **idempotent**. Before writing anything it checks whether
`~/.config/claude-vm/config-bake.yml` and
`~/.config/claude-vm/config-boot.yml` already exist (each independently):

- **If a file does not exist**: this is the create path for that file.
  Propose the full default file, get approval, write it.
- **If a file already exists**: **do not clobber it.** Read it, show the
  user what is there, and offer two choices:
  1. **Leave** the existing file untouched (the default, safe choice).
  2. **Merge** the resolved defaults in for any keys the existing file
     is missing, preserving every key the user already set.

  Never overwrite a key the user already set on the "merge" path, and
  never delete a key. A merge only *fills gaps*. If the existing file
  already has every key the defaults provide, report that it is already
  complete and leave it untouched.

Writing either file requires explicit user approval in every case.

## Resolved defaults

These are the values this skill writes, drawn from the parent issue's
verified analysis. They deliberately **override** the illustrative
values in `payload/config-bake.example.yml` /
`payload/config-boot.example.yml`. The **file** column names which of
the two global files each key is written into (its bake/boot placement):

| key | file | default | rationale |
|-----|------|---------|-----------|
| `cpus` | boot | `2` | RAM-bound sizing; vCPUs time-slice, 2 covers git/build/test bursts |
| `mem` | boot | `4096` | the real ceiling — RAM is committed, ~8–12 VMs fit at 4 GB on a 64 GB host |
| `proxy.cmd` | boot | omitted (bundled tinyproxy launcher is the launcher-side default) | tinyproxy is the chosen forward proxy; the launcher runs the bundled `payload/proxy/tinyproxy-launch.sh` when `proxy.cmd` is unset |
| `proxy.port` | boot | `3128` | matches the launcher default |
| `proxy.host_alias` | boot | `192.168.127.254` | the gvproxy host alias the guest reaches the proxy on |
| `egress.allow` | boot | `api.anthropic.com`, `github.com`, `claude.ai`, `downloads.claude.ai` | `api.anthropic.com` is required for Remote Control; the rest cover git + claude install/fetch |
| `claude.version` | boot | `stable` | which `claude` binary the host-side verified cache fetches |
| `claude.renderer` | boot | omitted (claude's own default) | terminal renderer on the interactive console: `classic` \| `fullscreen` \| unset |
| `claude.remote_control` | boot | omitted (`false`) | opt-in Remote Control: `true` adds `--remote-control` + a date-stamped `--name` default; `false`/unset passes CLI args through |
| `packages:` (boot file) | boot | `[]` | apt packages installed AT BOOT (a flat list; through the proxy, before claude starts) |
| `update_at_boot` | boot | `true` | apt-get update && upgrade at boot |
| `add_apt_uris_to_allowlist` | boot | `auto` | add derived egress URIs to the proxy allowlist only when boot-time package work needs them (`auto`), or always (`always`) |
| `apt_sources` (boot file) | boot | `[]` | third-party apt repos a boot-time install pulls from (union+dedup with the bake file's) |
| `claude.permission_mode` | boot | `bypassPermissions` | in-guest Claude's permission mode (`bypassPermissions` \| `default` only; any other value aborts the launch) |
| `claude.plugins.install_at_boot` | boot | `[]` | `plugin@marketplace` refs the guest installs at boot, blocking, before claude starts |
| `claude.plugins.update_at_boot` | boot | `true` | refresh the marketplaces and update the installed plugins at boot — the freshness path for BAKED plugins |
| `claude.plugins.add_marketplace_uris_to_allowlist` | boot | `auto` | marketplace-URI analogue of `add_apt_uris_to_allowlist` |
| `claude.plugins.enabled` | boot | omitted | optional map (plugin ref → boolean) mirroring settings.json's `enabledPlugins`; overrides the default-enabled state per plugin (`false` = installed-but-disabled) |
| `claude.marketplaces` (boot file) | boot | `[]` | marketplaces only an `install_at_boot` ref needs (union+dedup with the bake file's, by `name`) |
| `github.auth` | boot | `none` | whether the guest is seeded with a GitHub auth token derived from the host |
| `packages:` (bake file) | bake | `[]` | apt packages BAKED into the guest image (a flat list; present with no network at boot) |
| `apt_sources` (bake file) | bake | `[]` | third-party apt repos rendered into the image at build time |
| `claude.marketplaces` (bake file) | bake | `[]` | marketplaces registered INTO the image at build time (union+dedup with the boot file's, by `name`) |
| `claude.plugins.bake` | bake | `[]` | `plugin@marketplace` refs INSTALLED into the image at build time; a BAKE key because they change the image's bytes |
| `image.root_headroom_mb` | bake | `1024` | extra MiB of FREE SPACE in the guest root filesystem above its base content, so a live session (boot-time apt working set + ordinary growth) does not hit ENOSPC |

Notes on the forward-looking keys:

- **`proxy.cmd` is omitted from the written config.** tinyproxy is the
  chosen forward proxy, and the launcher already defaults to the bundled
  `payload/proxy/tinyproxy-launch.sh` when `proxy.cmd` is unset (it reads
  the egress allowlist from `$CLAUDE_VM_EGRESS_ALLOWLIST` and binds
  `$CLAUDE_VM_PROXY_PORT`). So the resolved global config leaves
  `proxy.cmd` unset rather than pinning a brittle invocation. Write a
  `proxy.cmd` only if the user wants to override the bundled launcher;
  any override must read `$CLAUDE_VM_EGRESS_ALLOWLIST` rather than a
  hand-maintained list baked into the command.
- **`claude.version: stable`** selects which `claude` binary the
  host-side GPG-verified cache fetches. It is consumed by
  `payload/lib/claude-cache.sh`: the host resolves the channel/pin to a
  concrete version, downloads that version's GPG-signed manifest,
  verifies the signature against the operator's pinned key,
  checksum-verifies the binary, caches it keyed on the version, and
  mounts it RO into the guest. `stable` (default) tracks the conservative
  stable channel; `latest` tracks the latest channel; a dotted version
  like `2.1.172` pins one concrete release with no channel resolution.
- **`api.anthropic.com` must stay in `egress.allow`.** Remote Control is
  outbound-HTTPS-only and connects to the Anthropic API on 443; dropping
  this host breaks every in-guest Remote Control session. Treat it as
  load-bearing, not optional.
- **`claude.renderer` is omitted by default.** It selects the in-guest
  claude's terminal renderer on the interactive console (`classic` →
  `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`; `fullscreen` →
  `CLAUDE_CODE_NO_FLICKER=1`); unset passes nothing so claude uses its
  own default. Both renderers work over the byte-pipe console, so leaving
  it unset is a fine default — write a value only if the user asks for
  one. An unrecognized value aborts the launch.
- **`claude.remote_control` is omitted by default (`false`).** It is an
  opt-in boolean: when `true`, the launcher injects `--remote-control`
  into the in-guest claude invocation (unless the CLI args already carry
  it) and, when Remote Control is in effect but no `--name` was given,
  appends a date-stamped `--name` (format like `Jul10-14:30`) so the run
  is named. When `false`/unset, claude runs without Remote Control and the
  user's CLI args pass through unchanged. Accepts `true`/`false` (or leave
  unset); any other value aborts the launch. Ask the user whether they
  want Remote Control on by default; write the key only when they opt in.
- **The bake file's `packages:`/`apt_sources:` and the boot file's
  `packages:` are written empty (`[]`) by default.** Ask the user whether they want
  any apt packages baked into the image, installed at boot, or any
  third-party apt repos; write entries only if they name specific
  packages/repos. Leaving these empty is the safe default — the bake
  file's entries are baked into the image (issue #105) and the boot
  file's are installed at boot through the proxy (issue #106).
- **`claude.permissions.allow` / `.ask` / `.deny` and
  `claude.marketplaces` / `claude.plugins.bake` /
  `.plugins.install_at_boot` are written empty by default.** Same
  reasoning: ask whether the user wants specific permission rules,
  marketplaces, or plugins baked/installed; write entries only on
  request. `claude.permission_mode` and `claude.permissions.*` are
  rendered into the guest `settings.json` (issue #104). `claude.plugins.bake`
  refs are installed **into the image** by the build's plugin bake step
  and `.install_at_boot` refs by the guest boot launcher's plugin phase
  (issue #107); both are also rendered into `settings.json`'s
  `enabledPlugins`.
- **Placement is enforced for `claude.plugins`.** `bake` belongs in
  `config-bake.yml` (baked plugins change the image's bytes, so they must
  live where the whole-file image-identity hash sees them);
  `install_at_boot`, `update_at_boot`,
  `add_marketplace_uris_to_allowlist`, and `enabled` belong in
  `config-boot.yml`. A sub-key written into the wrong file **aborts the
  launch** with a message naming the right file, rather than parsing and
  being silently ignored. `claude.marketplaces` is the exception: allowed
  in both files, unioned and deduped by `name`, with the same name under
  two differing urls aborting the launch.
- **Prefer an explicit `https://` marketplace url.** The launcher derives
  the guest's marketplace egress hosts from the url; the `owner/repo`
  GitHub shorthand yields no derivable host, so it needs `github.com`
  kept in `egress.allow` by hand.
- **`claude.plugins.enabled` is omitted by default.** It is an optional
  map of plugin ref → boolean that mirrors `settings.json`'s own
  `enabledPlugins` vocabulary and is rendered straight into the guest
  `settings.json` (issue #104). Every ref in `claude.plugins.bake` /
  `.install_at_boot` is enabled by default, so write an `enabled` entry
  only when the user wants to override that — e.g. `false` to ship a
  plugin installed-but-disabled (toggling a debug plugin like
  `show-loaded-rules` around a specific issue). Keys must name an
  installed ref and values must be boolean; a typo aborts the launch.
- **`github.auth` defaults to `none`.** Ask the user whether they want
  the guest seeded with a GitHub auth token derived from the host
  (`host-token`); `none` is the safe default since the consumer that
  seeds the token lands in a sibling slice under #39.

## Steps

Follow these in order. Do not write the file until the user has
explicitly approved the proposed content.

### Step 1: Resolve the target paths

Expand `~` to the user's home directory. There are TWO target files:

```text
~/.config/claude-vm/config-bake.yml
~/.config/claude-vm/config-boot.yml
```

Respect `XDG_CONFIG_HOME` if set: the config dir is
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm`, matching the launcher's
`CLAUDE_VM_GLOBAL_CONFIG_DIR` default in `payload/lib/config.sh`. The
parent directory may not exist yet; the `Write` tool creates it.

Also check for a **legacy** `${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/config.yml`.
If it exists, tell the user the launcher no longer reads it and offer to
migrate its keys into the bake/boot pair (splitting by the placement
rule); after writing the pair, remind them to remove or rename the
legacy file.

### Step 2: Detect existing config files

Check each of the two target files independently.

- **Absent** → create path for that file. The proposed content is the
  full default file from Step 3.
- **Present** → idempotent path for that file. Read its full contents,
  parse the YAML, and show the user what is already there. Then ask (via
  `AskUserQuestion`) whether to:
  - **Leave it untouched** (recommended default), or
  - **Merge** the resolved defaults into any keys it is missing.

  On "leave", skip that file. On "merge", compute the gap-fill (Step 3,
  merge variant) and continue to Step 4 for that file.

### Step 3: Compose the proposed content

**Create variant** (no existing file). The full default **`config-bake.yml`**
(image-bytes keys) is:

```yaml
# claude-vm global BAKE config (machine-wide defaults).
#
# Keys here change BYTES in the guest .raw image, so the image cache key +
# filename is a WHOLE-FILE, RAW-BYTE hash of this file. Editing it (including
# only its trailing newline) rebuilds the image. The per-repo bake layer at
# <repo>/.claude-vm/config-bake.yml overrides scalars and unions lists. See the
# claude-vm skill (skills/claude-vm/SKILL.md) and payload/config-bake.example.yml.
#
# NO SECRETS HERE.

# apt packages baked into the guest image (flat list of names; present with no
# network at boot). Write entries only if the user names specific packages.
packages: []

# Third-party apt repos rendered into the image at build time:
# {name, repo, key_url}. Also allowed in the boot file (union, dedup by name).
# Write entries only on request.
apt_sources: []

# Extra MiB of FREE SPACE in the guest root filesystem above its base content,
# so a live session does not hit ENOSPC (default 1024). A BAKE key: it sizes
# the .raw, so changing it rebuilds the image.
image:
  root_headroom_mb: 1024

# Plugin marketplaces registered INTO the image, and the plugin@marketplace refs
# installed into it, at build time. BAKE keys: baked plugins change the image's
# bytes. `name` must match the marketplace's OWN manifest name; prefer an
# explicit https:// url so the launcher can derive its egress host. Write
# entries only on request.
claude:
  marketplaces: []
  plugins:
    bake: []
```

The full default **`config-boot.yml`** (run-time keys) is:

```yaml
# claude-vm global BOOT config (machine-wide defaults).
#
# Keys here are applied at run time (launcher/VM wiring) and NEVER affect the
# image identity -- editing this file triggers no rebuild. The per-repo boot
# layer at <repo>/.claude-vm/config-boot.yml overrides scalars and unions lists.
# See the claude-vm skill (skills/claude-vm/SKILL.md) and
# payload/config-boot.example.yml.
#
# NO SECRETS HERE. The host claude.ai OAuth credential is mounted into the guest
# at runtime by the launcher; it is never read from or written to this file.

cpus: 2
mem: 4096

proxy:
  # proxy.cmd is intentionally OMITTED: tinyproxy is the chosen forward proxy,
  # and the launcher defaults to the bundled tinyproxy launcher
  # (payload/proxy/tinyproxy-launch.sh) when proxy.cmd is unset. It reads the
  # egress allowlist from $CLAUDE_VM_EGRESS_ALLOWLIST and binds
  # $CLAUDE_VM_PROXY_PORT. Set proxy.cmd only to override that default.
  port: 3128
  host_alias: 192.168.127.254

egress:
  allow:                # outbound hosts permitted through the proxy
    - api.anthropic.com # REQUIRED for Remote Control (outbound 443)
    - github.com
    - claude.ai
    - downloads.claude.ai

# apt packages installed AT BOOT (flat list; through the proxy, before claude
# starts). Write entries only on request.
packages: []
update_at_boot: true    # apt-get update && upgrade at boot (default true)
add_apt_uris_to_allowlist: auto   # auto (default) | always
# apt_sources: third-party apt repos a boot-time install pulls from (union+dedup
# with the bake file's). Write only on request.
apt_sources: []

claude:
  version: stable       # which claude binary the host-side GPG-verified cache
                        # fetches: stable (default) | latest | <pinned>
  # renderer: classic   # classic (no alt-screen) | fullscreen | unset. Omitted.
  # remote_control: false  # opt-in Remote Control. Omitted by default.
  # permission_mode + permissions.* render into the guest settings.json's
  # permissions (issue #104); the host's own ~/.claude/settings.json is never read.
  permission_mode: bypassPermissions   # bypassPermissions (default) | default
  permissions:
    allow: []           # write entries only if the user names specific rules
    ask: []
    deny: []
  marketplaces: []      # {name, url} entries a boot-time install needs (union+
                        # dedup by name with the bake file's). Write on request.
  plugins:
    # bake: is a BAKE key -- it lives in config-bake.yml. Writing it here aborts
    # the launch.
    install_at_boot: []  # plugin@marketplace refs installed at boot, blocking,
                         # before claude starts. Write only on request.
    update_at_boot: true # refresh the marketplaces and update the installed
                         # plugins at boot; the freshness path for BAKED plugins
    add_marketplace_uris_to_allowlist: auto   # auto (default) | always
    # enabled: OPTIONAL map, plugin ref -> boolean, mirroring settings.json's
    # enabledPlugins. Every bake/install_at_boot ref defaults enabled; write an
    # entry only to override (false = installed-but-disabled). Write on request.
    # enabled:
    #   show-loaded-rules@thevoskamps: false

# Guest GitHub auth.
github:
  auth: none             # none (default) | host-token
```

> On `proxy.cmd`: the bundled tinyproxy launcher
> (`payload/proxy/tinyproxy-launch.sh`) is the launcher-side default, so
> the resolved global boot config leaves `proxy.cmd` unset. If the user
> wants their own forward proxy, capture their `proxy.cmd` verbatim into
> the boot file — the only hard requirement is that it honor the
> launcher-provided allowlist (`$CLAUDE_VM_EGRESS_ALLOWLIST`) rather than
> a baked-in one.

**Merge variant** (existing file): start from the existing parsed YAML
and add **only** the keys from that file's default that are absent. Keep
every existing key and value verbatim, including any the user
customized and any this skill does not recognize. For list keys
(bake file: `packages`, `apt_sources`, `claude.marketplaces`,
`claude.plugins.bake`; boot file: `egress.allow`,
`packages`, `apt_sources`, `claude.permissions.allow`/`.ask`/`.deny`,
`claude.marketplaces`, `claude.plugins.install_at_boot`), union
the default entries in (do not drop the user's extras, do not
duplicate). Render the merged result preserving the user's existing
comments where practical.

### Step 4: Show the proposed file(s) and get approval

Render each **full proposed file** exactly as it will land on disk. For
a merge variant, also show a short summary: which keys this run adds,
which it preserves untouched.

Then ask explicitly, per file:

> Write `~/.config/claude-vm/config-bake.yml` (and/or `config-boot.yml`)
> as shown? (y to proceed, or tell me what to change)

Wait for explicit approval. If the user asks for changes, adjust and
re-render here.

### Step 5: Write the file(s)

On approval, use the `Write` tool to write each full file in one call.
The parent directory is created if needed.

### Step 6: Verify and summarize

After each `Write`, re-read the file and confirm it parses as YAML and
contains the expected keys:

- **config-bake.yml**: `packages` (list), `apt_sources` (list),
  `image.root_headroom_mb`, `claude.marketplaces` (list),
  `claude.plugins.bake` (list).
- **config-boot.yml**: `cpus: 2`, `mem: 4096`, `proxy.port`,
  `egress.allow` including
  `api.anthropic.com`, `claude.version`, `claude.permission_mode`,
  `update_at_boot`, `github.auth`. `proxy.cmd` is intentionally absent —
  the launcher defaults to the bundled tinyproxy launcher when unset.

This is content verification — `Write` already errors if the bytes did
not land; the re-read confirms the *intended content*.

Report back:

- The absolute path(s) written (or "left untouched" / "already complete").
- For a merge, which keys were added vs. preserved.
- A reminder that the per-repo pair
  (`<repo>/.claude-vm/config-{bake,boot}.yml`, written by
  `/claude-vm-config-repo`) overrides scalars and unions lists, that
  editing a bake file rebuilds the image while editing a boot file does
  not, and that no secret is ever written here.

## Hard constraints

- **Idempotent.** Never clobber an existing config. Detect it, and offer
  leave (default) or gap-fill merge. A merge fills gaps only — it never
  overwrites or deletes a key the user set.
- **`api.anthropic.com` stays in `egress.allow`.** It is required for
  Remote Control. Never drop it from the defaults.
- **No secrets in this file.** The host OAuth credential is mounted at
  runtime, never written to config.
- **Never write without explicit approval** in Step 4.
- **Write exactly the two global files**:
  `~/.config/claude-vm/config-bake.yml` and
  `~/.config/claude-vm/config-boot.yml`. This skill touches no repo,
  edits no `.gitignore`, and runs no git commands.
- **Respect the bake/boot placement rule.** Image-bytes keys
  (`packages` baked in, `apt_sources`, `image.root_headroom_mb`,
  `claude.plugins.bake`) go in `config-bake.yml`; run-time keys go in
  `config-boot.yml`. A misplaced key loudly does nothing rather than
  silently poisoning the image cache, and a misplaced `claude.plugins`
  sub-key aborts the launch outright.
