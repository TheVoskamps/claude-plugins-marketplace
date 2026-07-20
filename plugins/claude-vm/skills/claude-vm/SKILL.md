---
name: claude-vm
description: Launch Claude Code inside an isolated Linux micro-VM on macOS with config-driven egress, mounts, VM resources, and repo isolation (clone or live). All non-secret knobs come from two-tier YAML (global + per-repo); the guest authenticates with the host's claude.ai OAuth credential extracted from the macOS Keychain at launch, plus an identity seed (userID + oauthAccount from the host's ~/.claude.json, plus synthesized onboarding/auto-update-off/version keys) so the in-guest session comes up already onboarded, logged in, and with self-update disabled.
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

# 2. (Optional) drop a global config at ~/.config/claude-vm/config.yml
#    and/or a per-repo config at <repo>/.claude-vm/config.yml.
#    Run /claude-vm-config-global to write the global config from the
#    resolved defaults, and /claude-vm-config-repo (from inside a repo)
#    to write per-repo overrides (both idempotent), or see
#    payload/config.example.yml for a starting point.
#    bin/claude-vm below also offers to create the global config for you
#    if it is missing.

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

Two layers, both optional:

1. **Global**: `~/.config/claude-vm/config.yml` — machine-wide defaults.
   Run `/claude-vm-config-global` to create this file from the resolved
   defaults; it is idempotent and never clobbers an existing config.
2. **Per-repo**: `<repo>/.claude-vm/config.yml` — project-specific.
   Run `/claude-vm-config-repo` from inside the repo to write this file
   with only the keys it overrides on top of the global config; it is
   idempotent and never clobbers an existing config.

### Layering semantics

- **Scalars** (`cpus`, `mem`, `guest_image`, `image.root_headroom_mb`,
  `repo.mount`,
  `repo.copy_back`, `proxy.*`, `claude.version`, `claude.renderer`,
  `packages.update_at_boot`, `packages.add_apt_uris_to_allowlist`,
  `claude.permission_mode`, `claude.plugins.update_at_boot`,
  `claude.plugins.add_marketplace_uris_to_allowlist`,
  `github.auth`): repo overrides global; global fills gaps; a hardcoded
  default applies only when neither layer sets the key.
- **Scalar maps** (`claude.plugins.enabled`): repo overrides global
  **per key** — each plugin-ref → boolean entry follows the scalar
  repo-wins rule independently, so a repo can flip one plugin's enabled
  state without restating the global map.
- **Lists** (`egress.allow`, `mounts`, `packages.bake`,
  `packages.install_at_boot`, `packages.apt_sources`,
  `claude.permissions.allow`, `claude.permissions.ask`,
  `claude.permissions.deny`, `claude.marketplaces`,
  `claude.plugins.bake`, `claude.plugins.install_at_boot`): **merged** —
  the union of global + repo entries, de-duplicated. This includes list
  keys nested two levels deep (e.g. `claude.permissions.allow`,
  `claude.plugins.bake`), not just top-level keys.

### Keys

```yaml
cpus: 4
mem: 8192
guest_image: /path/to/guest.raw   # repo may override; SET = used verbatim
                                  # (opts out of image-variant derivation);
                                  # UNSET = derived (shared guest.raw, or a
                                  # guest-<hash>.raw / guest-headroom<N>.raw /
                                  # guest-<hash>-headroom<N>.raw variant when
                                  # packages are baked and/or root_headroom_mb
                                  # is non-default -- see packages/image below)

# image.root_headroom_mb: extra MiB the guest root partition is sized ABOVE
# its measured/estimated base content (default 1024, repo overrides global;
# issue #106). Real-hardware testing hit ENOSPC twice in one short session on
# a tight-fit-sized root (systemd-repart's Minimize=guess with no configured
# floor) -- boot-time apt working set + ordinary session growth (journald,
# the in-guest claude's home) both eat into a root with zero margin. 1024 MB
# is roughly 20x the observed short-session growth. A non-default value forks
# its own cached image variant and triggers a rebuild, like packages.bake.
image:
  root_headroom_mb: 1024

repo:
  mount: clone                    # clone (default) | live
  copy_back: local                # local (default) | none

# Guest software: apt packages baked into the image or installed at boot.
# packages.bake + packages.apt_sources are BAKED INTO THE IMAGE (issue #105):
# baked packages are present with no boot-time network, and apt_sources repos
# install their packages at build time. The launcher derives a bake-hash over
# the (order-normalized) bake + apt_sources config and stores each distinct
# bake set as its own image variant (guest-<hash>.raw); no-bake configs share
# one guest.raw. install_at_boot / update_at_boot run INSIDE the guest at
# boot instead, through the proxy, blocking, before claude starts (issue
# #106) -- use install_at_boot for packages that change often (e.g. the AWS
# SDK/CLI) so they stay fresh without a rebuild. This requires `apt` itself
# to be present in the guest, which mkosi does not provide for free -- so
# `apt` is baked into every guest image's base Packages= list
# unconditionally, regardless of whether boot-time apt work is configured.
# The guest's baked apt sources are binary-only (main + updates + security,
# no deb-src/debug/Translations -- issue #106 real-run fix) to keep the
# per-boot apt working set small; boot_apt_phase ends with `apt-get clean`.
# The proxy that covers boot-time apt ALSO covers a mid-session interactive
# apt-get: run.env exports lowercase http_proxy/https_proxy/no_proxy
# alongside the uppercase forms (apt honors only lowercase; curl ignores
# uppercase HTTP_PROXY for plain http://), and the boot launcher writes a
# persistent /etc/apt/apt.conf.d/99claude-vm-proxy so proxying does not
# depend on a shell re-sourcing run.env.
packages:
  bake: []                        # apt packages baked into the guest image at
                                  # build time (present with no boot network)
  install_at_boot: []             # apt packages installed at boot, blocking,
                                  # before claude starts, through the proxy
  update_at_boot: true            # apt-get update && upgrade at boot,
                                  # through the proxy (default true)
  apt_sources: []                 # third-party apt repos: {name, repo,
                                  # key_url}. Rendered at build time (for
                                  # bake) AND at boot time into the guest's
                                  # live /etc/apt (for install_at_boot)
  add_apt_uris_to_allowlist: auto # auto (default) | always -- adds
                                  # deb.debian.org/security.debian.org +
                                  # apt_sources hosts to guest egress iff
                                  # boot-time apt work is configured (auto),
                                  # or unconditionally (always)

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
  marketplaces: []                # {name, url} entries
  plugins:
    bake: []                      # plugin@marketplace refs baked into the
                                  # image
    install_at_boot: []           # plugin@marketplace refs installed at boot
    update_at_boot: true          # refresh marketplaces + reinstall changed
                                  # plugins at boot (default true)
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
    mode: ro
  - source: ~/datasets/foo
    tag: data
    mode: ro

github:
  auth: none                      # none (default) | host-token
```

- `egress.allow` is written to a newline-delimited file whose path is
  exported as `CLAUDE_VM_EGRESS_ALLOWLIST`. When `proxy.cmd` is unset,
  the launcher defaults to the bundled tinyproxy launcher
  (`payload/proxy/tinyproxy-launch.sh`), which reads that file and binds
  `CLAUDE_VM_PROXY_PORT`. A `proxy.cmd` override must likewise read that
  file instead of a hand-maintained allowlist baked into the command.
- `mounts` generates the extra `virtio-fs` device flags. A leading `~`
  in `source` expands to `$HOME`.
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
below). `packages.bake` and `packages.apt_sources` are **consumed** by the
guest-image build (issue #105 — see "Guest image" below).
`packages.install_at_boot`, `packages.update_at_boot`, and
`packages.add_apt_uris_to_allowlist` are **consumed** by the guest boot
launcher's boot-time apt phase (issue #106 — see "Boot-time package
install/update" in `payload/README.md`). The remaining keys (marketplace/
plugin seeding, GitHub token seeding) are schema + merge only as of issue
#103 — those consumers land in sibling slices under #39. They resolve
correctly through `payload/lib/config.sh` today; nothing downstream reads
them yet.

- `packages.bake` / `packages.install_at_boot` list the apt packages to
  bake into the guest image vs. install at boot (blocking, before
  claude starts, through the proxy). Both union global + repo entries.
  `packages.bake` is baked at build time (issue #105): the baked packages
  are present in the guest with no boot-time network, and the image is
  cached per bake set (see "Guest image" below). `packages.install_at_boot`
  runs `apt-get -y install <list>` at boot (issue #106): use it for
  packages that change often (e.g. the AWS SDK/CLI) so they stay fresh
  without an image rebuild; a failed install warns loudly and continues to
  claude rather than blocking the session.
- `packages.update_at_boot` (default `true`) runs `apt-get update &&
  upgrade` at boot, through the proxy, before claude starts (issue #106); a
  failed update warns loudly and continues. `packages.apt_sources` (union)
  adds third-party apt repos as `{name, repo, key_url}` entries. Each entry
  is rendered TWICE, independently: at **image-build** time (issue #105 —
  baked into the mkosi sandbox tree so `packages.bake` packages from that
  repo install at build time) and, separately, at **boot** time into the
  guest's live `/etc/apt` whenever `packages.install_at_boot` is nonempty
  (issue #106 — reusing the exact same keyring-fetch + sources.list.d-write
  shape, ported to plain bash since the guest has no python3/jq).
- `packages.add_apt_uris_to_allowlist` (`auto` default | `always`)
  controls whether `deb.debian.org` + `security.debian.org` + every
  `packages.apt_sources` host are added to the guest's egress allowlist.
  `auto` adds them only when boot-time package work needs them
  (`install_at_boot` nonempty, or `update_at_boot` true); with neither
  configured, `auto` derives nothing, leaving package repos unreachable —
  by design, for a hard-secure all-baked config. `always` adds them
  unconditionally so in-session `apt-get install` also works. The knob
  never removes URIs that scheduled boot-time work requires, and every
  derived addition is logged.
- `claude.marketplaces` (union of `{name, url}` entries) and
  `claude.plugins.update_at_boot` (default `true`) / `.add_marketplace_uris_to_allowlist`
  (`auto` default | `always`) control which marketplaces the guest has
  available and how plugin refresh/allowlisting works at boot.
  (`claude.plugins.bake` / `.install_at_boot` are consumed by the
  settings.json render below as `enabledPlugins`; the actual plugin
  installation is still a #39 sibling slice.)
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

Two ways to turn on Remote Control:

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
  that, on boot, loads the run environment and then execs the
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
- **Baked packages (issue #105).** `packages.bake` and
  `packages.apt_sources` ARE baked into the image (unlike `claude`): the
  baked packages are present in the guest with no boot-time network, and
  each `apt_sources` repo's `key_url` is fetched into a keyring so its
  packages install (`signed-by` that key) at build time. An
  `apt_sources` entry's `repo` may already carry its own apt one-line
  `[options]` block (e.g. an operator-authored `signed-by=`); the
  renderer adapts to the line's existing shape instead of unconditionally
  appending a second `[options]` block (apt allows only one, and two make
  the line unparseable) — no block gets one added, a block without
  `signed-by=` gets it merged in, and a block that already pins
  `signed-by=<path>` is left verbatim with the fetched key written to that
  path's staging equivalent. `packages.bake` entries that are null/empty
  (e.g. a stray `-` in the YAML list) are stripped during canonicalization
  rather than baked in as a literal `"None"` package name. Because the image
  is a shared cache, the launcher derives a **bake-hash** — sha256 (first 8
  hex) over the order-normalized bake config (sorted `packages.bake`,
  normalized `apt_sources`) — and folds it into the pinned version
  (`BASE_OS_REV+launcherN+bake<hash>`) and the image filename. A config with
  no baked packages hashes to a constant, keeps the legacy version, and
  shares the one global `guest.raw`; a config that bakes packages gets its
  own `guest-<hash>.raw` variant, built on first use and stored alongside.
  Adding an override builds+stores a new variant; removing it reverts to the
  shared image with no rebuild. Only bake + apt_sources feed the hash —
  changing cpus/egress/permissions never rebuilds. The `guest_image` scalar,
  when set, opts out of variant derivation and is used verbatim.
- **Root headroom image variants (issue #106 real-run fix).**
  `image.root_headroom_mb` also forks the image cache key, independently of
  the bake-hash above: when the resolved headroom differs from the default
  (`CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB`, `lib/config.sh`), the launcher
  folds a `+headroomN` segment into the pinned version and the image
  filename (`guest-headroom<N>.raw`, or `guest-<hash>-headroom<N>.raw` when
  bake overrides are ALSO present). A default-headroom, no-bake config keeps
  sharing the one `guest.raw`. Kept as its own segment rather than folded
  into the bake-hash's canonical JSON, so the bake-hash's "empty bake config
  is a hash-stable constant" invariant (exercised by existing coverage)
  stays undisturbed by an unrelated key.
- **Boot-time package install/update (issue #106).** `packages.install_at_boot`
  and `packages.update_at_boot` do **not** feed the bake-hash — they run a
  blocking phase in the boot launcher itself, right before claude execs,
  through the same proxy the rest of the guest's egress goes through. The
  base image DOES need one thing unconditionally to support this phase: `apt`
  itself, baked into the base `Packages=` list regardless of whether
  install_at_boot/update_at_boot are configured (mkosi does not otherwise put
  apt/dpkg tooling into the guest rootfs, since it installs baked packages
  from OUTSIDE the image with its own build-container apt) — this is covered
  by `LAUNCHER_LOGIC_REV`, the same base-version pin as everything else in
  this bullet's parent bullet, not by the bake-hash. See "Boot-time package
  install/update" and "Mid-session apt proxying, metadata diet, and root
  headroom" in `payload/README.md` for the full mechanics (the reused
  `render_apt_source` shape, the proxy `-o Acquire::*::Proxy=` flags and
  persistent `apt.conf.d` drop-in, the apt metadata diet, `apt-get clean`,
  the failure policy, and the `add_apt_uris_to_allowlist` derived-egress
  gate).
- On startup, the launcher **ensures the image exists and matches the
  pinned version**. If the resolved image is missing or version-mismatched,
  it builds the image (`payload/build-guest-image.sh --output …`, passing the
  canonical bake config through `CLAUDE_VM_BAKE_CONFIG`) rather than erroring.
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
before exec'ing `claude`, so the in-guest session comes up already
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
`~/.local/bin/claude`, but the guest execs the RO-mounted binary from
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
`$HOME/.claude/.credentials.json` (mode `0600`) before exec'ing
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

`payload/test/podman-mkosi-test.sh` regression-tests the recipe the
default provisioner generates (the literal `mkosi.conf` and
`build-in-container.sh`), stubbing only `podman` at the container
handoff — added after a real end-to-end build caught failures (a
backtick-command-substitution bug corrupting `mkosi.conf`, and a missing
`curl`/`ca-certificates` in the build container) that no pure-function
`config-test.sh` case could catch, since none of them render or execute
the actual generated recipe files.

The end-to-end acceptance test — default-provisioner build, vfkit boot
to the claude-fetch seam (exec'ing the host-verified claude off the
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
