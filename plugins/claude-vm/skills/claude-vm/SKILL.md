---
name: claude-vm
description: Launch Claude Code inside an isolated Linux micro-VM on macOS with config-driven egress, mounts, VM resources, and repo isolation (clone or live). All non-secret knobs come from four-file YAML (a bake file + a boot file per tier, global + per-repo, all optional); the immutable base image is APFS-cloned per run so concurrent sessions never leak state. The guest authenticates with the host's claude.ai OAuth credential extracted from the macOS Keychain at launch, plus an identity seed (userID + oauthAccount from the host's ~/.claude.json, plus synthesized onboarding/auto-update-off/version keys) so the in-guest session comes up already onboarded, logged in, and with self-update disabled.
---

# claude-vm

Run Claude Code inside an isolated Linux micro-VM on macOS. Every
non-secret operational knob — VM resources, the egress allowlist, extra
mounts, the proxy, and how the repo is made available to the guest —
comes from layered **YAML config** rather than environment variables.
The guest authenticates with the **host's live claude.ai OAuth
credential**, which the launcher extracts from the macOS Keychain at
launch and shares RO into the guest, plus an **identity seed** the
launcher builds from your host `~/.claude.json` — the `userID` +
`oauthAccount` selected from the host, plus synthesized
`hasCompletedOnboarding` / `autoUpdates: false` / version keys — so the
interactive in-guest session comes up already onboarded, logged in, and
with self-update disabled (issue #88). Both are secrets, neither is
written to config, and both ride the same transient shred-on-exit
mount. No token environment variable is required — just be logged in to
Claude Code on the host.

The entry point is `bin/claude-vm` (issue #51), a preflight wrapper
that ships on PATH for the Bash tool; it forwards to the launcher and
image-build scripts, which ship as payloads under
`${CLAUDE_PLUGIN_ROOT}/payload/`. This skill explains the config
surface and drives the launcher.

## Quick start

```bash
# 1. Be logged in to Claude Code on this host. The launcher installs the
#    host's live claude.ai OAuth credential (extracted from the macOS
#    Keychain) AND seeds the guest's identity (userID + oauthAccount from
#    your ~/.claude.json, plus synthesized onboarding/auto-update-off
#    keys) so the in-guest claude comes up already onboarded and logged
#    in. Run `claude` once and complete the claude.ai login if you have
#    not; the launcher aborts at a preflight if you are not logged in.
#    No token environment variable is required.

# 2. (Optional) drop a global config PAIR at
#    ~/.config/claude-vm/config-bake.yml + config-boot.yml and/or a
#    per-repo pair at <repo>/.claude-vm/config-{bake,boot}.yml. A bake
#    file holds image-bytes keys; a boot file holds run-time keys.
#    Run /claude-vm-config-global to write the global pair from the
#    resolved defaults, and /claude-vm-config-repo (from inside a repo)
#    to write per-repo overrides (both idempotent), or see
#    payload/config-bake.example.yml + config-boot.example.yml for a
#    starting point. bin/claude-vm below also offers to create the global
#    config for you if it is missing. (A legacy single-file config.yml is
#    no longer read -- the launcher aborts with a migration message.)

# 3. Launch from inside the repo you want to run a VM for. bin/claude-vm
#    derives the repo name and root, names the run, and forwards to the
#    launcher, which makes the repo available RW to the guest.
claude-vm [claude args...]
```

On exit, the launcher copies the guest's changes back to the local
source by default (clone mode). The companion skills extract work
explicitly: `/claude-vm-diff`, `/claude-vm-apply-local`,
`/claude-vm-apply-remote`.

## Config surface

**Four files, all optional** (issue #179) — a **bake** file and a
**boot** file per tier. Placement rule: a key that changes **bytes in
the guest `.raw` image** goes in a **bake** file; a key applied at **run
time** goes in a **boot** file. Placement IS the classification, made
once by the operator — a knob in the wrong file loudly does nothing
instead of silently poisoning the image cache.

1. **Global bake**: `~/.config/claude-vm/config-bake.yml` — machine-wide
   image-bytes defaults.
2. **Global boot**: `~/.config/claude-vm/config-boot.yml` — machine-wide
   run-time defaults.
3. **Per-repo bake**: `<repo>/.claude-vm/config-bake.yml` — this repo's
   image-bytes overrides. Shipping this file gives the repo its OWN image.
4. **Per-repo boot**: `<repo>/.claude-vm/config-boot.yml` — this repo's
   run-time overrides.

Run `/claude-vm-config-global` to create the global pair from the
resolved defaults, and `/claude-vm-config-repo` (from inside a repo) to
write per-repo overrides; both are idempotent and never clobber an
existing file. A legacy single-file `config.yml` (either tier) is no
longer read — the launcher aborts with a migration message rather than
silently dropping the knobs it set.

**What goes where:**

- **bake file** — `packages:` (a flat list of apt packages baked into
  the image), `apt_sources:` (third-party apt repos rendered into the
  image), `image.root_headroom_mb`.
- **boot file** — `cpus`, `mem`, `guest_image`, `repo.*`, `proxy.*`,
  `egress.allow`, `mounts`, `provisioner`, `packages:` (here a flat
  list installed AT BOOT), `update_at_boot`, `add_apt_uris_to_allowlist`,
  `apt_sources:` (for a boot-time install; union+dedup with the bake
  file's), `claude.*`, `github.*`.

### Layering semantics

The effective config is the union of all four files (compose each tier's
bake+boot, then merge global under repo):

- **Scalars** (`cpus`, `mem`, `guest_image`, `image.root_headroom_mb`
  [bake], `repo.mount`, `repo.copy_back`, `proxy.*`, `claude.version`,
  `claude.renderer`, `update_at_boot`, `add_apt_uris_to_allowlist`,
  `claude.permission_mode`, `claude.plugins.update_at_boot`,
  `claude.plugins.add_marketplace_uris_to_allowlist`, `github.auth`):
  repo overrides global; global fills gaps; a hardcoded default applies
  only when neither layer sets the key.
- **Scalar maps** (`claude.plugins.enabled`): repo overrides global
  **per key** — each plugin-ref → boolean entry follows the scalar
  repo-wins rule independently, so a repo can flip one plugin's enabled
  state without restating the global map.
- **Lists** (bake file: `packages`, `apt_sources`, `claude.marketplaces`,
  `claude.plugins.bake`; boot file: `egress.allow`, `mounts`, `packages`,
  `apt_sources`, `claude.marketplaces`, `claude.permissions.allow`,
  `claude.permissions.ask`, `claude.permissions.deny`,
  `claude.plugins.install_at_boot`): **merged** —
  the union of global + repo entries, de-duplicated. `apt_sources` and
  `claude.marketplaces` are allowed in **both** file types; each is unioned
  and deduped by `name`, and the same name with DIFFERING content
  (`{repo, key_url}` / `url`) aborts the launch (no silent shadowing).
- **Placement guard**: `claude.plugins` is the one map that legitimately
  appears in both file types, so a sub-key in the wrong file aborts the
  launch with a message naming the right file — `bake` belongs in the bake
  file (it changes image bytes), and `install_at_boot` / `update_at_boot` /
  `add_marketplace_uris_to_allowlist` / `enabled` belong in the boot file.

### Keys

```yaml
# The keys below are grouped by which FILE they live in (bake vs boot). A key
# in the wrong file loudly does nothing rather than silently poisoning the cache.

# --- BOOT file keys (config-boot.yml -- run-time; never rebuild the image) ---
cpus: 4
mem: 8192
guest_image: /path/to/guest.raw   # repo may override; SET = used verbatim
                                  # (opts out of image-identity derivation);
                                  # UNSET = derived guest+global<hash>.raw
                                  # (no repo-bake file) or
                                  # guest+global<hash>+<reponame>-<repohash>.raw
                                  # (repo ships a config-bake.yml)

repo:
  mount: clone                    # clone (default) | live
  copy_back: local                # local (default) | none

# Boot-time apt: a flat `packages:` LIST installed AT BOOT (through the proxy,
# blocking, before claude starts -- issue #106); update_at_boot runs
# `apt-get update && upgrade`; add_apt_uris_to_allowlist derives apt egress;
# apt_sources here feed a boot-time install (union+dedup by name with the bake
# file's; a baked name is not re-rendered). Use install-at-boot packages for
# things that change often (e.g. the AWS SDK/CLI) so they stay fresh without a
# rebuild. This requires `apt` in the guest, which mkosi does not provide for
# free -- so `apt` is baked into every guest image's base Packages= list
# unconditionally. The guest's baked apt sources are binary-only (main + updates
# + security, no deb-src/debug/Translations -- issue #106 real-run fix) to keep
# the per-boot apt working set small; boot_apt_phase ends with `apt-get clean`.
# The proxy that covers boot-time apt ALSO covers a mid-session interactive
# apt-get: run.env exports lowercase http_proxy/https_proxy/no_proxy alongside
# the uppercase forms (apt honors only lowercase; curl ignores uppercase
# HTTP_PROXY for plain http://), and the boot launcher writes a persistent
# /etc/apt/apt.conf.d/99claude-vm-proxy so proxying does not depend on a shell
# re-sourcing run.env.
packages:                         # (in config-boot.yml) apt packages installed
  - awscli                        # AT BOOT, through the proxy (a flat list)
update_at_boot: true              # apt-get update && upgrade at boot (default true)
apt_sources: []                   # (boot) third-party repos a boot-time install
                                  # pulls from: {name, repo, key_url}
add_apt_uris_to_allowlist: auto   # auto (default) | always -- adds
                                  # deb.debian.org/security.debian.org +
                                  # apt_sources hosts to guest egress iff
                                  # boot-time apt work is configured (auto),
                                  # or unconditionally (always)

# --- BAKE file keys (config-bake.yml -- image bytes; editing rebuilds) ---
# In config-bake.yml, `packages:` is a flat LIST BAKED into the image (present
# with no boot-time network), `apt_sources:` are rendered into the image at
# build time, and image.root_headroom_mb sizes the root partition. The image
# cache key + filename is a WHOLE-FILE, RAW-BYTE hash of the bake files -- no
# key-picking, no canonicalization -- so editing a bake file (including only its
# trailing newline, the documented force-rebuild lever) rebuilds the image;
# editing a boot file never does. A repo that ships a config-bake.yml gets its
# OWN image (its name in the filename); a repo without one shares
# guest+global<hash>.raw.
#
# packages:                       # (in config-bake.yml) apt packages BAKED in
#   - jq
#   - ripgrep
# apt_sources: []                 # (bake) third-party repos rendered at build time
#
# image.root_headroom_mb: extra MiB of FREE SPACE the guest root filesystem is
# sized ABOVE its base content (default 1024, repo overrides global). Real-
# hardware testing hit ENOSPC twice in one short session on a tight-fit-sized
# root -- boot-time apt working set + ordinary session growth both eat into a
# root with zero margin. 1024 MB is roughly 20x the observed short-session
# growth. It is a BAKE key: changing it changes the bake-file hash and triggers
# a rebuild.
image:
  root_headroom_mb: 1024

# Marketplaces + BAKED plugins (BAKE file). The image build runs the
# host-verified guest `claude` binary inside the build container with HOME
# pointed at the image root and drives its own CLI (`claude plugin marketplace
# add` / `claude plugin install`), so the image ships a real
# /root/.claude/plugins that loads with NO marketplace egress at boot. A failed
# add/install FAILS THE BUILD rather than shipping an image without them --
# for the marketplaces declared HERE and every `bake:` ref. A marketplace
# declared only in the boot file is pre-registered as an optimization, and a
# failure there only warns (the guest adds it at boot).
# Placement here (not in the boot file) is what puts these under the whole-file
# image-identity hash; writing `claude.plugins.bake` into a boot file aborts the
# launch. Prefer an explicit https:// url over the `owner/repo` shorthand so the
# launcher can derive the marketplace's egress host. Shown commented out, like
# the bake `packages:`/`apt_sources:` above, because the boot file's own
# `claude:` map follows below and one document cannot carry both.
#
# claude:
#   marketplaces:
#     - name: thevoskamps
#       url: https://github.com/TheVoskamps/claude-plugins-marketplace.git
#   plugins:
#     bake:
#       - block-background-agents@thevoskamps
#       # COMPILED HOOKS NEED NO TOOLCHAIN: the guardrails permission-gate
#       # ships prebuilt, committed binaries (one per <goos>-<goarch>,
#       # including the guest's linux-arm64), so baking it requires nothing
#       # in this file's `packages:` -- no `golang`, nothing.
#       # - guardrails@thevoskamps

# --- BOOT file keys, continued ---
claude:
  version: stable                 # stable (default) | latest | <pinned>
                                  # host-side GPG-verified cache key
  renderer: classic               # classic | fullscreen | (unset)
                                  # terminal renderer on the interactive
                                  # console; unset uses claude's own default
  remote_control: false           # true | false (default) | (unset)
                                  # opt-in Remote Control: true adds
                                  # --remote-control + a date-stamped --name
  permission_mode: bypassPermissions   # bypassPermissions (default) | default
  permissions:
    allow: []
    ask: []
    deny: []
  marketplaces: []                # {name, url} entries. Allowed in BOTH file
                                  # types (like apt_sources); `name` must match
                                  # the marketplace's OWN manifest name. One
                                  # declared HERE only has to be reachable from
                                  # the GUEST -- a url the image build cannot
                                  # reach warns and is added at boot instead.
  plugins:
    # bake: lives in the BAKE file -- see the bake-file block above.
    install_at_boot: []           # plugin@marketplace refs installed at boot
    update_at_boot: true          # refresh marketplaces + update the installed
                                  # plugins at boot (default true). This is the
                                  # freshness path for BAKED plugins: they are
                                  # frozen at build time and the image-identity
                                  # hash excludes marketplace HEAD, so a
                                  # marketplace bump lands at the next boot with
                                  # no rebuild.
    add_marketplace_uris_to_allowlist: auto   # auto (default) | always
    enabled:                      # OPTIONAL map, plugin ref -> boolean,
                                  # mirroring settings.json's enabledPlugins.
                                  # Every bake/install_at_boot ref defaults
                                  # enabled; list an entry only to override
                                  # (false = installed-but-disabled). Keys must
                                  # name an installed ref; values must be
                                  # boolean; a typo aborts the launch.
      show-loaded-rules@thevoskamps: false

proxy:
  cmd: "<forward-proxy launch command>"   # must read
                                          # $CLAUDE_VM_EGRESS_ALLOWLIST
  port: 3128
  host_alias: 192.168.127.254

egress:
  allow:                          # outbound hosts permitted via the proxy
    - api.anthropic.com
    - github.com
    - claude.ai

mounts:                           # extra mounts beyond the repo auto-mount
  - source: ~/.claude/policy
    tag: policy
    mode: ro                      # ro (default) | rw -- ENFORCED, see below
  - source: ~/datasets/foo
    tag: data
    mode: ro
  - source: ~/.gitconfig          # a single FILE works too
    tag: gitconfig
    mode: ro
    path: /root/.gitconfig        # optional guest mountpoint override

github:
  auth: none                      # none (default) | host-token
```

- `egress.allow` is written to a newline-delimited file whose path is
  exported as `CLAUDE_VM_EGRESS_ALLOWLIST`. When `proxy.cmd` is unset,
  the launcher defaults to the bundled tinyproxy launcher
  (`payload/proxy/tinyproxy-launch.sh`), which reads that file and binds
  `CLAUDE_VM_PROXY_PORT`. A `proxy.cmd` override must likewise read that
  file instead of a hand-maintained allowlist baked into the command.
- `mounts` generates the extra `virtio-fs` device flags, and the guest
  mounts each one at `path:` (default `/mnt/<tag>`) before claude starts.
  A leading `~` in `source` expands to `$HOME`. Both `source` and `tag`
  are mandatory per entry — the guest mounts each share *by* its tag, so
  an entry with an empty or omitted `tag:` is a share nobody can mount
  and two of them would collide on one tag.

  **`mode: rw` pierces the VM isolation boundary for that one path.** It
  is an enforced guest mount option, not a hint: `ro` writes fail with
  `EROFS`, and `rw` writes land on the host directory **live** — no
  copy-back step, no review, no undo (`repo.copy_back` governs the *repo*
  mount only). Everything else about the VM still holds; that one
  directory is simply outside it, on purpose. `ro` is the default so
  that piercing the boundary is always deliberate.

  A single **file** `source` works as well as a directory: virtio-fs
  shares directories only, so the launcher wraps the file in a per-entry
  directory (hard-linking it, so `rw` still writes through to the host
  file) and the guest bind-mounts just that one file onto `path:`.
  Nothing else from the file's real parent directory reaches the guest.

  Every mistake aborts the launch at config load rather than booting a VM
  without the mount you asked for: a missing `source`/`tag`, a `source`
  that is not on the host, a `tag` that is reserved
  (`repo`/`runconfig`/`claudebin`/`claudecreds`), outside
  `[A-Za-z0-9._-]`, or repeated, a `mode` other than `ro`/`rw`, and a
  `path` that is relative, carries `..`, lands on one of claude-vm's own
  mountpoints, or duplicates another entry's. The diagnostic names the
  entry by its position in the merged boot config — `mounts` is a union
  list, so that number counts through the global entries before the
  per-repo ones and need not be the entry's position in either file on
  its own — and by its path when it has one.
- `claude.version` selects which `claude` binary the host-side verified
  cache fetches: `stable` (default), `latest`, or a pinned version
  (`2.1.172`). The host resolves a channel to a concrete version,
  downloads that version's GPG-signed manifest, verifies the signature
  against the operator's pinned key, checksum-verifies the binary, caches
  it keyed on the version, and mounts it RO into the guest. A failed
  `gpg --verify` or a checksum mismatch **aborts the launch**. On a warm
  boot (already cached), the launcher drops `claude.ai` /
  `downloads.claude.ai` from the guest egress allowlist. See the payload
  README's "Verified claude cache" section for the operator's one-time
  key-import step.
- `claude.renderer` selects the in-guest claude's terminal renderer on
  the interactive console (the vfkit `stdio` byte pipe). Both renderers
  work over the console — this is a preference, not a workaround:
  `classic` disables the alternate-screen buffer
  (`CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`), `fullscreen` forces the
  flicker-free fullscreen renderer (`CLAUDE_CODE_NO_FLICKER=1`), and
  leaving it unset passes nothing so claude uses its own default. The
  launcher writes the matching `CLAUDE_CODE_*` var into `run.env`. An
  unrecognized value aborts the launch.
- `claude.remote_control` is an opt-in boolean (default `false`/unset).
  When `true`, the launcher injects `--remote-control` into the in-guest
  claude invocation (unless the CLI args already carry it) and, when
  Remote Control is in effect but no `--name` was given, appends a
  date-stamped `--name` (format like `Jul10-14:30`). When `false`/unset,
  claude runs without Remote Control and the CLI args pass through
  unchanged. Accepts `true`/`false` (or unset); any other value aborts
  the launch. This is the config-driven equivalent of passing
  `--remote-control` on the command line — see the interactive-session
  section below.

`claude.permission_mode`, `claude.permissions.*`,
`claude.plugins.bake` / `.install_at_boot` (as `enabledPlugins`), and
`claude.plugins.enabled` are **consumed** by the guest `settings.json` render
(issue #104) — the launcher renders `/root/.claude/settings.json`
host-side and shares it into the guest (see "Guest Claude settings.json"
below). (There is no schema translation: the launcher merges the two bake
files into one bake document and the two boot files into one boot document,
and every reader consumes its tier's document at the file-schema path — a
key set per the documented schema is always read.) The bake document's
`packages:` and `apt_sources:` are **consumed** by the guest-image build
(issue #105 — see "Guest image" below). The boot document's `packages:`,
`update_at_boot`, and `add_apt_uris_to_allowlist` are **consumed** by the
guest boot launcher's boot-time apt phase (issue #106 — see "Boot-time
package install/update" in `payload/README.md`). The bake document's
`claude.marketplaces` + `claude.plugins.bake` are **consumed** by the
image build's plugin bake step, and the boot document's
`claude.plugins.install_at_boot` / `.update_at_boot` /
`.add_marketplace_uris_to_allowlist` by the guest boot launcher's plugin
phase (issue #107 — see "Marketplaces and plugins" below). The remaining key
(GitHub token seeding) is schema + merge only as of issue #103 — that consumer
lands in a sibling slice under #39. It resolves correctly through
`payload/lib/config.sh` today; nothing downstream reads it yet.

- The bake file's `packages:` (baked into the image) vs. the boot file's
  `packages:` (installed at boot, blocking, before claude starts, through
  the proxy) — the containing file's tier is what makes each a build-time
  bake or a boot-time install (this replaces the old single-file
  `packages.bake` / `packages.install_at_boot` key split; each tier's
  merged document keeps its own flat `packages:` list, read as written).
  Both union global + repo entries. The
  baked packages are present in the guest with no boot-time network, and
  the image is cached per whole-file bake hash (see "Guest image" below).
  The boot-install list runs `apt-get -y install <list>` at boot (issue
  #106): use it for packages that change often (e.g. the AWS SDK/CLI) so
  they stay fresh without an image rebuild; a failed install warns loudly
  and continues to claude rather than blocking the session.
- The boot file's `update_at_boot` (default `true`) runs `apt-get update
  && upgrade` at boot, through the proxy, before claude starts (issue
  #106); a failed update warns loudly and continues. `apt_sources`
  (allowed in BOTH files; union, deduped by `name`; conflicting content
  under one name aborts) adds third-party apt repos as
  `{name, repo, key_url}` entries. A **bake** file's apt_sources are
  rendered at **image-build** time (issue #105 — baked into the mkosi
  sandbox tree so baked packages from that repo install at build time). A
  **boot** file's apt_sources (minus any name already baked) are rendered
  at **boot** time into the guest's live `/etc/apt` whenever the boot
  `packages:` install list is nonempty (issue #106 — reusing the exact
  same keyring-fetch + sources.list.d-write shape, ported to plain bash
  since the guest has no python3/jq).
- The boot file's `add_apt_uris_to_allowlist` (`auto` default | `always`)
  controls whether `deb.debian.org` + `security.debian.org` + every
  `apt_sources` host are added to the guest's egress allowlist.
  `auto` adds them only when boot-time package work needs them (the boot
  `packages:` install list nonempty, or `update_at_boot` true); with
  neither configured, `auto` derives nothing, leaving package repos
  unreachable — by design, for a hard-secure all-baked config. `always`
  adds them
  unconditionally so in-session `apt-get install` also works. The knob
  never removes URIs that scheduled boot-time work requires, and every
  derived addition is logged.
- **Marketplaces and plugins** (issue #107). `claude.marketplaces` (union of
  `{name, url}`, allowed in both file types, deduped by `name`, conflicting
  urls under one name abort, and — since issue #226 — an entry with a url but
  no `name` aborts too, since the name is what every consumer matches on)
  declares the marketplaces the guest knows.
  `claude.plugins.bake` (BAKE file) is installed **into the image** at build
  time; `claude.plugins.install_at_boot` (BOOT file) is installed **at boot**,
  blocking, before claude starts.
  - The bake path runs the host-verified guest `claude` binary inside the
    build container with `HOME` pointed at the image root and drives its own
    CLI (`claude plugin marketplace add` / `claude plugin install`) — the
    registry format is claude's and is never hand-written. A failed
    add/install **fails the build**, so a cached image never silently lacks a
    configured plugin. That strictness covers what the image must **carry**:
    every `bake:` ref and every marketplace declared in a bake file. A
    marketplace declared only in a **boot** file is pre-registered here as an
    optimization, and its url only has to be reachable from the *guest* — a
    guest-local path (`/mnt/repo`), a private source, or an https host outside
    the build container's egress. A boot-declared entry warns and leaves the
    registration to the boot path on each of the paths that fail a
    bake-declared one: no `url` at all, a failed add, or an add that registers
    under a name other than the configured one (issue #226).
  - The boot path ensures any marketplace the image does not already carry,
    then (when `update_at_boot` is `true`, the default) refreshes the
    marketplaces and updates the installed plugins, then installs the
    `install_at_boot` refs. This is the freshness mechanism for **baked**
    plugins: they are frozen at build time and the image-identity hash
    deliberately excludes marketplace HEAD, so a marketplace bump lands at
    the next boot with no rebuild. A failure warns loudly on the captured
    console log and continues to claude. The guest image bakes `git`
    unconditionally for this phase: the claude CLI shells out to **system
    git** for every git-url marketplace operation, so without it the
    add/update fails (fail-soft) and `update_at_boot` would be inert.
  - `.add_marketplace_uris_to_allowlist` (`auto` default | `always`) mirrors
    `add_apt_uris_to_allowlist`: under `auto`, marketplace hosts are added to
    the guest egress allowlist only when boot-side work can actually run (a
    nonempty `install_at_boot`, a marketplace declared in the boot file that is
    not also bake-declared, or `update_at_boot` true with at least one
    marketplace configured). The middle test reads the *declaration*, not the
    image: the build's pre-registration of a boot-declared marketplace is
    best-effort since #226 and the host cannot know whether it succeeded, so
    the gate derives the host either way.
    Everything bake-declared + `update_at_boot: false` + `auto` derives
    **nothing** —
    and the guest still has working plugins, because the baked ones need no
    marketplace. Every derived addition is logged. A `owner/repo` shorthand
    url yields no derivable host (keep `github.com` in `egress.allow`
    yourself); the launcher says so rather than guessing.
  - **Compiled hooks need no toolchain**: the guardrails permission-gate
    ships prebuilt, committed binaries (one per `<goos>-<goarch>`, the
    guest's being `linux-arm64`), so baking `guardrails@…` requires
    **nothing** in the bake file's `packages:` — in particular no
    `golang`. A platform with no committed binary makes the hook fail
    closed (exit 2, tool call denied), never silently unadjudicated.
- `github.auth` (`none` default | `host-token`) selects whether the
  guest is seeded with a GitHub auth token derived from the host.

### Guest Claude settings.json (issue #104)

The launcher renders the guest's `/root/.claude/settings.json`
host-side from the merged config and shares it into the guest over the
existing transient `claudecreds` mount (the same one the OAuth
credential and identity seed ride). The guest boot launcher installs it
at `$HOME/.claude/settings.json`. The rendered file is derived from the
claude-vm configs **only** — the host's `~/.claude/settings.json` is
never read, so the guest deliberately runs its own (possibly riskier)
posture:

- `permissions.allow` / `.ask` / `.deny` come verbatim from
  `claude.permissions.*` (each a unioned list).
- `permissions.defaultMode` comes from `claude.permission_mode`
  (`bypassPermissions` default | `default`). Only those two values are
  accepted — any other aborts the launch (it is a security-posture value
  with no defined behavior for an unknown mode). YOLO-by-default: the VM is
  the isolation boundary, so `bypassPermissions` is the default with the
  deny list as backstop. The guest runs claude as **root**, which claude
  refuses in `bypassPermissions` unless `IS_SANDBOX=1`; the launcher sets
  `IS_SANDBOX=1` unconditionally in `run.env` (the guest *is* the
  sandbox).
- `enabledPlugins` maps every ref in
  `claude.plugins.bake ++ claude.plugins.install_at_boot` to `true`
  (de-duplicated), then the optional `claude.plugins.enabled` map
  overrides those defaults per key. `enabled` mirrors `settings.json`'s
  own `enabledPlugins` vocabulary (plugin ref → boolean): `false` marks a
  plugin **installed-but-disabled** (re-enabling needs no reinstall — handy
  for toggling debug plugins like `show-loaded-rules` / `show-loaded-skills`
  around a specific issue). The map is validated **once**: every value must
  be boolean and every key must name an installed ref — an unknown key is a
  typo and **aborts the launch**.
- `extraKnownMarketplaces` maps every configured marketplace name (the
  effective bake ++ boot set) to its source, in the shape claude itself
  writes: an `https://` url renders as `{"source":"git","url":…}`, an
  `owner/repo` shorthand as `{"source":"github","repo":…}`. This key is
  rendered because `claude plugin install` was observed writing it into
  `~/.claude/settings.json` alongside `enabledPlugins` — and the boot
  launcher copies the host-rendered file over whatever the image baked, so
  omitting it would drop the marketplace declarations the bake step's own
  CLI run wrote. Rendering it from the same effective set the bake and boot
  paths use keeps the three from drifting. It does **not** make claude
  self-install a missing plugin (tested directly: a home dir with only this
  settings.json and no `~/.claude/plugins` tree installs nothing), which is
  why the guest's explicit ensure/install/update phase is load-bearing.

claude-vm has **no** own CLI flags: every post-repo argument is forwarded
to the guest `claude` verbatim. Plugin enable/disable state is set through
`claude.plugins.enabled` in the config files, not on the command line.

## Interactive session (the launching terminal IS the in-VM claude)

`claude-vm <repo>` opens an **interactive** Claude Code session on the
launching terminal — the terminal becomes the guest's `hvc1` console and
you drive the full REPL inside the micro-VM (detached clone + egress
proxy). This is the product goal; headless one-shot is not. Pass
`--remote-control --name <n>` straight through (`claude-vm <repo>
--remote-control --name foo`) and the same session is *also*
Remote-Control-attached for AFK observation/replies — those flags reach
the in-guest claude via the existing `CLAUDE_ARGS` plumbing; no extra
transport is involved.

Ways to turn on Remote Control:

- **Per-launch, via CLI** — pass `--remote-control` (and optionally
  `--name <n>`) after the repo path, as above.
- **Opt-in by config** — set `claude.remote_control: true` in the global
  or per-repo config. The launcher then injects `--remote-control` for
  you (without duplicating it if you also pass it on the CLI). Either way,
  if Remote Control is in effect but you gave no `--name`, the launcher
  appends a date-stamped `--name` (format like `Jul10-14:30`) so the run
  is named — matching the date-stamp default this skill documents. A
  user-supplied `--name` (in either `--name <v>` or `--name=<v>` form) is
  never overridden. Arbitrary CLI args survive verbatim: the launcher
  quotes `CLAUDE_ARGS` per-argument into `run.env` and the guest boot
  launcher reconstructs the exact argv, so a value like
  `--name "foo #7 micro-vm"` (with spaces and a `#`) round-trips intact.

Topology: vfkit attaches **two** virtio-serial consoles. The first
(`logFilePath`, guest `hvc0`) captures all kernel/systemd boot output to
`$RUN/guest-console.log` (preserving the observability from the
guest-console capture); the second (`stdio`, guest `hvc1`) bridges the
launching terminal. The guest runs claude as the login program of an
autologin `serial-getty@hvc1`, so claude *is* the session with no shell
in between. Boot diagnostics stay on `hvc0` (off your terminal).

Because the `stdio` console is a byte pipe that needs a real controlling
TTY on the host, **launch `claude-vm` from a real terminal**, not from a
pipe. The console carries no live window-resize channel, so the launcher
seeds the guest tty geometry once from the host's `stty size` at launch;
there is no live resize.

## Repo mount strategy (`repo.mount`)

How the repo is made available RW to the guest:

- **`clone` (default)**: `git clone --no-hardlinks` the repo into a
  **persistent** worktree, mounted RW. The guest never touches the live
  working tree or `.git`. The worktree lives under
  `<repo>/.claude/tmp/<runid>/worktree` when launched from inside a
  repo (otherwise a `mktemp` dir under `TMPDIR`). It persists after the
  run so the companion diff/apply skills can inspect and extract
  results. `.claude/tmp/` is git-ignored.
- **`live`**: mount the live repo dir RW directly. More convenient,
  less isolated. Opt-in.

### Getting work back out (clone mode)

After the guest exits, the launcher runs **copy-back to the local
source by default** (`repo.copy_back: local`). Set
`repo.copy_back: none` to disable it and extract manually. The three
companion skills handle extraction explicitly:

- `/claude-vm-diff` — read-only: show what changed in the VM worktree
  vs. the local source.
- `/claude-vm-apply-local` — apply the VM worktree's changes to the
  local source.
- `/claude-vm-apply-remote` — push the VM worktree's changes to the
  remote.

## Guest image — built on demand, version-pinned, claude verified host-side

Claude Code updates daily, so the guest image does **not** bake in
`claude`:

- The baked image is a **stable base**: a pinned OS plus a boot launcher
  that, on boot, loads the run environment and then runs the
  **host-side GPG-verified `claude` binary** mounted RO at
  `/mnt/claudebin` against the repo at `/mnt/repo`, as an interactive
  session on the `hvc1` console (issue #88). `claude` is never
  baked in and never fetched-and-run inside the guest (no
  `curl install.sh | bash` anywhere — there is no such fallback); the
  host fetches, verifies, and caches it (see "Verified claude cache" in
  the payload README). The base only changes when the base OS pin or the
  launcher logic changes — not when claude does.
- The base is **version-pinned** in `payload/build-guest-image.sh`
  (`BASE_OS_REV` + `LAUNCHER_LOGIC_REV`; never the claude version).
- **Baked packages (issue #105, re-keyed by #179).** A **bake** file's
  `packages:` and `apt_sources:` ARE baked into the image (unlike
  `claude`): the baked packages are present in the guest with no
  boot-time network, and each `apt_sources` repo's `key_url` is fetched
  into a keyring so its packages install (`signed-by` that key) at build
  time. An `apt_sources` entry's `repo` may already carry its own apt
  one-line `[options]` block (e.g. an operator-authored `signed-by=`);
  the renderer adapts to the line's existing shape instead of
  unconditionally appending a second `[options]` block (apt allows only
  one, and two make the line unparseable) — no block gets one added, a
  block without `signed-by=` gets it merged in, and a block that already
  pins `signed-by=<path>` is left verbatim with the fetched key written
  to that path's staging equivalent. Baked `packages:` entries that are
  null/empty (e.g. a stray `-` in the YAML list) are stripped during the
  build render rather than baked in as a literal `"None"` package name.
- **Immutable base + whole-file image identity (issue #179).** The image
  cache key + filename is a **whole-file, raw-byte hash of the BAKE
  files** — no key-picking, no canonicalization. Placement of a key in a
  bake file IS the classification, made once by the operator: a knob in
  the wrong file loudly does nothing instead of silently poisoning the
  cache. Because the hash is over raw bytes, list order, key order,
  whitespace, and even a **trailing-newline toggle** all change it — the
  trailing-newline toggle is the documented force-rebuild lever. The
  shape:
  - a repo **without** a `.claude-vm/config-bake.yml` shares one image
    keyed on the GLOBAL bake file's hash: `guest+global<hash>.raw`,
    version `BASE_OS_REV+launcherN+global<hash>` (an absent global bake
    file hashes to the `00000000` sentinel);
  - a repo that **ships** a `.claude-vm/config-bake.yml` appends its own
    segment — the repo NAME plus a hash of the repo bake file —
    `guest+global<hash>+<reponame>-<repohash>.raw`, so the filename tells
    you whose override runs where. The repo segment's PRESENCE is gated
    on the bake FILE existing (not its content), so two repos with
    byte-identical repo-bake files still get two images (the name
    disambiguates): legibility over dedup, an explicit choice.

  Editing a **boot** file never changes identity and never rebuilds;
  editing a **bake** file (including only its trailing newline) does. The
  `guest_image` scalar, when set, opts out of identity derivation and is
  used verbatim.

  The cached base `.raw` is **immutable** and is NEVER attached to a VM:
  each run APFS-clones it (`cp -c`, instant zero-copy) into the run dir
  and boots the CLONE. N concurrent sessions cost one base plus each
  session's written blocks — no cross-session/cross-repo state leakage
  (OAuth credential, identity seed, transcripts, boot-installed packages)
  and no multi-writer corruption on a shared image. The clone is
  discarded on a clean exit and retained (path logged) on an abnormal one
  for forensics. There is no host-driven forced stop: the guest halts
  itself and vfkit (running foreground) exits on its own, so the
  launcher's `sync` in cleanup simply narrows the window in which writes
  in flight to the clone are still unflushed when the guest goes away.
- **Ending a session (issue #179).** The guest decides its own fate from
  claude's exit status; there is no host→guest shutdown channel.
  - **A deliberate quit powers the guest off.** `Ctrl-D Ctrl-D`, `/exit`,
    and `Ctrl-C Ctrl-C` all exit claude 0, and on 0 the guest starts
    systemd's ordered poweroff (SIGRTMIN+4 to PID 1 — the bus-less path,
    so no spurious "Failed to connect to bus" error on a guest that ships
    no dbus). vfkit then exits on its own, control returns to
    the `claude-vm` launcher on the host, your terminal is restored, the
    per-run clone is discarded, and the copy-back step runs. This is the
    normal way to end a session — nothing on the host needs to be killed.
  - **Ctrl-C belongs to the guest claude.** The launcher disables
    `isig`/`ixon` on the host tty for the session, so `Ctrl-C` (and
    `Ctrl-Z`/`Ctrl-\`/`Ctrl-S`/`Ctrl-Q`) travel to the guest as bytes
    instead of signalling host-side vfkit — the first `Ctrl-C` shows
    claude's press-again warning, the second exits 0 and powers off, same
    as `Ctrl-D Ctrl-D`. Consequence: the keyboard cannot abort a *wedged*
    guest from that terminal; the recovery path is `kill <vfkit pid>`
    from another terminal (vfkit tears the guest down within ~5s and the
    launcher cleans up normally). The saved tty state is restored on
    every exit path.
  - **An abnormal claude death drops you into a guest shell.** If claude
    exits nonzero (a crash, an OOM kill, or declining the
    bypass-permissions dialog — the easy way to try this path), the guest
    does **not** power off yet. The boot launcher hands you an
    interactive **root login shell on the same console you were already
    attached to**, so you can run a post-mortem inside the still-running
    guest: inspect `/mnt/repo`, see how the clone diverged, read `dmesg`,
    check whether the network wiring survived. claude is **not**
    relaunched — there is no respawn loop. **Exiting that shell powers
    the guest off** and returns control to the host launcher; the clone
    is retained (its path is logged) for further forensics.
- **Boot-time package install/update (issue #106).** A **boot** file's
  `packages:` (install list) and `update_at_boot` do **not** feed the
  image-identity hash — they
  run a blocking phase in the boot launcher itself, right before claude launches,
  through the same proxy the rest of the guest's egress goes through. The
  base image DOES need one thing unconditionally to support this phase: `apt`
  itself, baked into the base `Packages=` list regardless of whether
  install_at_boot/update_at_boot are configured (mkosi does not otherwise put
  apt/dpkg tooling into the guest rootfs, since it installs baked packages
  from OUTSIDE the image with its own build-container apt) — this is covered
  by `LAUNCHER_LOGIC_REV`, the base-version pin, not by the image-identity
  hash. See "Boot-time package
  install/update" and "Mid-session apt proxying, metadata diet, and root
  headroom" in `payload/README.md` for the full mechanics (the reused
  `render_apt_source` shape, the proxy `-o Acquire::*::Proxy=` flags and
  persistent `apt.conf.d` drop-in, the apt metadata diet, `apt-get clean`,
  the failure policy, and the `add_apt_uris_to_allowlist` derived-egress
  gate).
- On startup, the launcher **ensures the image exists and matches the
  pinned version**. If the resolved image is missing or version-mismatched,
  it builds the image (`payload/build-guest-image.sh --output …`, passing the
  merged bake config through `CLAUDE_VM_BAKE_CONFIG` and the pre-computed
  image-identity segments through `CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS`) rather
  than erroring.
  The image's pinned version is stamped at `<image>.version`.
- **No image artifact is committed to the repo**, and there is no
  publish-prebuilt-image path. Every machine builds its own.

The provisioning step that produces the bootable raw image defaults to
the bundled `payload/provisioners/podman-mkosi.sh`: mkosi run inside a
throwaway rootless podman container (Debian Trixie build container,
systemd ≥ 254 for the offline, loop-device-free `RepartOffline=yes`
path), emitting a raw EFI-bootable Debian guest with the boot launcher
wired as the autologin `serial-getty@hvc1` login program (so claude
becomes the interactive `hvc1` console session — issue #88), plus an
unlocked passwordless root (`RootPassword=hashed:`). vfkit boots it
`--bootloader efi`. `build-guest-image.sh` pins the version and emits the
boot launcher, then hands `<boot-launcher-path> <output-image-path>` to
the provisioner. The `CLAUDE_VM_IMAGE_PROVISIONER` env var overrides the
bundled default with your own script honoring the same two-argument
contract.

The launcher captures the booting guest's **boot** serial console
(`hvc0`) to `$RUN/guest-console.log` via the first vfkit `--device
virtio-serial,logFilePath=…`. The recipe `KernelCommandLine` sets
`console=hvc0`, so all kernel/systemd boot output — and the boot
launcher's diagnostic/seam lines, which it writes explicitly to
`/dev/console` — are observable from the host instead of being
discarded, while staying off the interactive `hvc1` terminal. The path
is reported on exit and retained in the run dir.

## Authentication (secrets)

The guest authenticates claude with the **host operator's live claude.ai
OAuth credential** — the full-scope login credential, not a scoped
inference token — installed at `$HOME/.claude/.credentials.json`. That
bearer token alone is **not** sufficient for the interactive TUI to treat
itself as onboarded and logged in: current Claude Code also reads
onboarding + identity state from `~/.claude.json`, which a fresh throwaway
guest lacks — so without it every launch hits the onboarding/login wall
despite the mounted credential. Two keys matter beyond identity:
`hasCompletedOnboarding` (absent → claude runs its onboarding flow) and
`autoUpdates` (unset → claude tries to self-update and fails against its
RO-mounted binary in the egress-confined guest).

So the launcher **also seeds the guest's identity + onboarding state**
(issue #88): it reads your host `~/.claude.json` and emits a seed carrying
`userID` and `oauthAccount` selected from the host, plus four synthesized
keys: `hasCompletedOnboarding: true` (skip the wall), `autoUpdates: false`
(no self-update), and `lastOnboardingVersion` / `lastReleaseNotesSeen`
stamped with the concrete resolved claude version. It **additively**
carries benign host UI keys when present — `installMethod`,
`hasSeenTasksHint`, `hasUsedStash`, `tipsHistory` (each silently omitted
when absent) — and seeds a **`projects` entry for the guest mount**
(`/mnt/repo`) with `hasTrustDialogAccepted` / `hasCompletedProjectOnboarding`
forced `true` so the guest skips the "Do you trust this folder? /mnt/repo"
dialog (if the host already has an entry for the launched repo, a **named
allowlist** of benign per-project keys — `allowedTools` and friends —
survives, rekeyed to `/mnt/repo` with those two flags forced true; the
operator's prompt `history`, `lastSessionId`, and `mcpServers` are
deliberately dropped, and unrecognized future keys default to excluded).
Nothing else from `~/.claude.json` (no other `projects{}` entries, no
telemetry, no `machineID`) is copied;
`machineID` is deliberately **not** seeded — the guest mints its own. That
object is shared into the guest under the same `claudecreds` mount, and
the guest boot launcher installs it at `$HOME/.claude.json` (mode `0600`)
before launching `claude`, so the in-guest session comes up already
onboarded, logged in, folder-trusted, and with self-update disabled. The
seed is built via `lib/credential.sh`'s `claude_vm_select_claude_json_seed`
(using `python3`; unit-tested in `payload/test/credential-test.sh`) and
carries account identity, so it rides the same secret posture as the
credential: written under `umask 077` into the transient, owner-only
(`0600`), shred-on-exit `claudecreds` mount, **never** into `run.env` or the
verified-binary cache. A **preflight** aborts the run with an actionable
message if the host `~/.claude.json` is missing or lacks a usable
`userID`/`oauthAccount` (i.e. you are not logged in on the host).

The launcher also quiets claude's startup **install-health check**
(issue #88): claude probes for a working `claude` at the native installer's
`~/.local/bin/claude`, but the guest runs the RO-mounted binary from
`/mnt/claudebin`, so that path is empty and the TUI prints two `claude
command at /root/.local/bin/claude missing or broken · run claude install to
repair` warnings. The guest boot launcher symlinks `$HOME/.local/bin/claude`
→ the verified RO-mounted binary right after the claude-fetch seam validates
it; the symlink target is the running binary, so the version comparison
passes by construction and `autoUpdates: false` plus the RO mount prevent
write-through (empirically confirmed to clear the warnings on real hardware).
Belt-and-braces with the seeded `autoUpdates: false`, the launcher also
writes the documented `DISABLE_AUTOUPDATER=1` env knob into `run.env`.

A second **credential-token preflight** guards against a degraded Keychain
entry: the `claudeAiOauth` object can be structurally complete yet carry
**empty** `accessToken` / `refreshToken` strings (with `expiresAt: 0`) —
which happens when your host claude sessions coast on the shared auth
daemon's in-memory tokens while the persisted Keychain entry has gone
stale. Booting the guest with it lands at "Not logged in · Run /login",
and an in-guest `/login` can trip OAuth reuse-detection and **revoke your
other live sessions**. So after selecting the credential, the launcher
validates both tokens are non-empty
(`claude_vm_validate_claude_credential_tokens`) and aborts fast if not,
telling you to re-login on the **host** (`claude` then `/login`, or restart
Claude Code — either repairs the Keychain entry) rather than inside the
guest.

At launch the launcher reads the credential from the macOS login
Keychain by service name alone
(`security find-generic-password -s "Claude Code-credentials" -w`).
That Keychain item is **not** only the claude.ai login — its JSON also
carries sibling keys such as `mcpOAuth` (per-MCP-server OAuth). To avoid
mounting unrelated MCP credentials into the guest, the launcher **selects
only the `claudeAiOauth` key** and writes a file in the shape `claude`
expects, `{"claudeAiOauth": { ... }}` (selection via `lib/credential.sh`,
using `python3`; unit-tested in `payload/test/credential-test.sh`). The
selected credential is written to a transient, owner-only (`0600`)
tmpfile and shared **read-only** into the guest under
`mountTag=claudecreds`. The guest boot launcher copies it into
`$HOME/.claude/.credentials.json` (mode `0600`) before launching
`claude`.

The credential is a secret and is handled like one: it is **never**
written to config, to `run.env`, or to the verified-binary cache; its
host-side tmpfile is created under a tightened `umask 077` and removed
by the launcher's `cleanup()`/`trap` on every exit. The full raw
Keychain blob (before selection) lives only in a transient tmpfile
outside the guest share and is removed immediately after selection.

**Requirements:** macOS only (`security find-generic-password` is a
macOS Keychain tool; `python3`, used for credential and identity-seed
selection, ships with macOS), and you must be logged in to Claude Code
on the host first. The launcher fails fast with an actionable message if
the host `~/.claude.json` is missing or lacks a usable
`userID`/`oauthAccount`, or if the Keychain lookup returns empty or
non-zero, or the blob has no usable `claudeAiOauth` key. `egress.allow`
must include
the Anthropic API host (`api.anthropic.com`) so the in-guest `claude`
can reach it. See the payload README's "Authentication" section for the
full mechanic.

## Requirements

`yq` (mikefarah v4+), `git`, `python3` (stock on macOS; used to select
the `claudeAiOauth` key from the Keychain blob — see "Authentication"
above), `gpg` (`brew install gnupg`, for the host-side verified claude
cache — see "Verified claude cache" in the payload README), a sha256
tool (`shasum` / `sha256sum`, both stock on macOS/Linux), and — for an
actual VM boot — `vfkit`, `podman` (with a
started podman machine, for the bundled podman-mkosi provisioner that
builds the guest image), and `tinyproxy` (for the bundled default
`proxy.cmd`). On a clean host:
`brew install yq git gnupg vfkit podman tinyproxy`.

`gvproxy` is **not** a separate install and need not be on PATH: it
ships inside the podman Homebrew formula at
`<brew-prefix>/libexec/podman/gvproxy` and a stock `brew install podman`
does not symlink it onto PATH. The launcher resolves it automatically
(an explicit on-PATH `gvproxy` first, then podman's libexec), so
installing podman is enough.

Before any image build, network call, or Keychain read, the launcher
runs a **trust-path preflight** that checks the local, instant
preconditions for the verified cache and credential selection up front:
`gpg` on PATH, the `claude.signing_key_fingerprint` pinned in config,
that pinned fingerprint actually present in the gpg keyring, and
`python3` on PATH. Immediately after, a separate **identity-seed
preflight** aborts if the host `~/.claude.json` is missing or lacks a
usable `userID`/`oauthAccount` (i.e. you are not logged in on the host).
Later, once the credential is selected, a **credential-token check**
aborts if the selected `claudeAiOauth` carries empty `accessToken` /
`refreshToken` (the degraded-Keychain state described under
"Authentication"), steering you to re-login on the host.
Each failed check prints the exact remediation
command(s) (e.g. `brew install gnupg`, the
`curl … | gpg --import` + `gpg --fingerprint` pin steps). Without this
gate, a cold boot would otherwise pay for a guest-image build and three
network fetches before aborting on a condition that was knowable at
startup. These are an additive early gate; the deep checks in the
verified cache (gpg-on-PATH and unset-pin hard-abort) and credential
selection (`python3`) remain as defense-in-depth.

After the trust-path preflight, and still before any build/boot work,
the launcher runs a **dependency preflight** that checks the VM
toolchain up front (gvproxy resolvable, `vfkit`/`podman` on PATH,
podman machine running, and — only when the bundled default proxy is in
use — `tinyproxy`). It fails fast with one actionable remediation line
per missing piece rather than dying deep in the boot sequence. A custom
`proxy.cmd` owns its own dependencies, so the `tinyproxy` check is
skipped then.

The config-resolution half (layering, scalar/list resolution) is
exercisable without the virtualization stack; see
`payload/test/config-test.sh`, and the verified-cache logic (resolve /
verify / checksum / abort / warm-boot) in
`payload/test/claude-cache-test.sh`.

The per-run endpoint primitives (issue #179) are also exercisable
without a VM: `payload/test/endpoint-test.sh` covers free-TCP-port
acquisition and TCP/unix-socket liveness (a live listener vs a stale
socket-file corpse, the exact distinction the concurrency fix turns on),
using real `perl` listeners; `payload/test/bin-config-check-test.sh`
regression-tests `bin/claude-vm`'s four-file bake/boot config-presence
check so it no longer prints a false "no global config" when the
migrated pair is present.

`payload/test/podman-mkosi-test.sh` regression-tests the recipe the
default provisioner generates (the literal `mkosi.conf` and
`build-in-container.sh`), stubbing only `podman` at the container
handoff — added after a real end-to-end build caught failures (a
backtick-command-substitution bug corrupting `mkosi.conf`, and a missing
`curl`/`ca-certificates` in the build container) that no pure-function
`config-test.sh` case could catch, since none of them render or execute
the actual generated recipe files.

The end-to-end acceptance test — default-provisioner build, vfkit boot
to the claude-fetch seam (running the host-verified claude off the
mount), egress confinement, and the host-side GPG-verified cache — is
`payload/test/host-acceptance.sh`; it is host-gated by cause: it skips
cleanly when a required binary is absent,
but a stopped or absent podman machine is not a skip — the test starts
the machine itself and tears down exactly what it changed on exit. A
bring-up the test attempted that then fails (`podman machine
init`/`start`) is a real failure, not a skip: the test exits non-zero
rather than green-exiting with nothing proven. Diagnostics (including
the machine init/start stderr) are retained under
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/logs/<run-id>/` so a failed
run stays diagnosable.
