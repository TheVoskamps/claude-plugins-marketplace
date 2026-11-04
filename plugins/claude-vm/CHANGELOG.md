# claude-vm changelog

## 0.22.0 — 2026-09-24

Runs now live in one host-wide place, and a launcher killed outright
(`kill -9`, a crash, a closed terminal) no longer strands anything
running or holds disk until you hunt it down.

- Run directories moved from `<repo>/.claude/tmp/` to `runs/` under the
  state root, overridable with `CLAUDE_VM_RUNS_DIR`. Logs and the
  console and egress captures moved to `logs/<run-id>/` beside it. Old
  run directories are not migrated.
- A watcher stops the VM, gvproxy and the proxy once the launcher is
  gone.
- The new `claude-vm-cleanup` command reaps every dead run across all
  your repos. It tells live from dead by a lock the kernel releases
  when the launcher dies, so it never touches a running VM. It removes
  the guest-image clone and credential files and keeps the worktree,
  `run.meta` and logs, so `/claude-vm-diff` and the apply skills still
  find the run.
- A recorded process is signalled only while its start time still
  matches, so a reused pid is safe.
- `/claude-vm-diff` and the apply skills now pick the most recent run
  for the current repo from the host-wide root.
- A single-file mount on another volume now aborts and tells you to
  mount the file's directory instead.

## 0.21.3 — 2026-09-20

The plugin now has a user-facing README covering why to use it,
prerequisites, configuration, its skills, a typical run and its limits.
No behavior changed.

## 0.21.2 — 2026-09-15

Built guest images, the verified `claude` cache and test logs moved from
`~/.config/claude-vm/` to `${XDG_STATE_HOME:-$HOME/.local/state}/claude-vm/`,
overridable with `CLAUDE_VM_STATE_DIR`. Only your config files stay under
`~/.config/claude-vm/`.

Nothing is migrated. Images rebuild and `claude` is re-fetched on the
next launch, and the old `images/`, `cache/` and `logs/` directories can
be deleted. A guardrails carve-out listing `claude-vm/**` under the
config home alone needs a state-home entry too.

## 0.21.1 — 2026-09-11

Internal only: wording in the docs and the apply skills no longer leans
on rules outside the plugin. Behavior is unchanged.

## 0.21.0 — 2026-08-26

The launcher now brings the podman machine up itself, so a fresh host no
longer aborts with instructions to run `podman machine init` and
`start` by hand.

- This happens only on a launch that builds the guest image. A launch
  with a current image never invokes podman, and needs neither a machine
  nor the podman binary.
- With no machine it runs init then start, with a stopped machine it
  starts it, and with a running machine it leaves it as found.
- A machine this run started is stopped at the end of the run, including
  on Ctrl-C during a build. It is not removed, so the next build reuses
  it.
- Every init, start and stop is logged to stderr. There is nothing to
  configure.

Real-host verification of the full launch was left as a manual test
plan; automated coverage used a stubbed podman plus read-only probes.

## 0.20.1 — 2026-08-27

Internal only: contributor notes in the payload documentation. Behavior
is unchanged.

## 0.20.0 — 2026-08-17

Your working rules now follow you into the guest. Copies of
`~/.claude/CLAUDE.md`, `rules/`, `agents/`, `skills/` and
`keybindings.json` are merged into the guest's `~/.claude` at boot, so a
session there works the way it does on the host.

- This is an include list. Host settings, plugin state and session data
  such as `projects/` and `history.jsonl` stay out; `settings.json` and
  plugins remain driven by the claude-vm config.
- Symlinks are followed on the host, so a `rules/` that links outside
  `~/.claude` arrives with its content.
- Each entry is optional and a failure only warns: it never stops a
  boot. A failed copy is removed rather than left half-done, unless it
  merged into a directory the image already had, which is kept with a
  warning.
- Fixes a launcher abort on stock macOS bash 3.2 (`unbound variable`)
  for any config with a `claude.plugins.enabled` override.

Cached images rebuild once to pick this up.

## 0.19.0 — 2026-08-07

A new `env:` config block gets variables to the in-guest session,
including third-party API keys for tools, MCP servers and model
providers other than Anthropic or GitHub.

- `env.set` takes literal values, in bake or boot files. Baked values
  become image bytes and persist across runs.
- `env.copy` forwards named variables from the host environment and
  `env.files` reads host `.env` files. Both are boot-only and a hard
  abort in a bake file, so a secret can never become image bytes, and
  the config stays committable because keys travel by reference.
- Precedence, lowest first: bake `env.set`, boot `env.files`, boot
  `env.copy`, boot `env.set`.
- Boot values ride the transient credentials mount and are sourced in
  place, so they do not reach the guest filesystem.
- Mistakes abort at launch rather than failing later inside a tool call:
  an invalid or reserved name, a missing or unparseable `.env` file, or
  an `env.copy` name unset or empty on the host. Diagnostics never print
  a value.

A `claude.plugins` sub-key in the wrong file now aborts in every
spelling, including an empty value that previously slipped through and
launched, so an existing config carrying one needs fixing.

## 0.18.0 — 2026-08-06

Extra `mounts:` now actually appear in the guest; before this they were
attached to the VM and never mounted.

- Mounts are read-write, and an optional `path:` overrides the default
  `/mnt/<tag>`.
- A `source` can be a single file, which writes through to the host
  file. Such a mount refuses the write-temp-then-rename pattern used by
  `git config`, `sed -i` and most editors, with a `Resource busy` error;
  a directory mount handles it fine.
- The `mode:` key is gone and setting it aborts the launch. Read-only
  cannot be enforced on this stack, so offering it would be a false
  claim.
- A mount can no longer shadow the guest OS. The launcher rejects a
  `path:` on, above or inside a system path (a single file may sit
  inside `/root`, `/home` or `/tmp`), and the guest warns and skips a
  mountpoint that is already occupied.
- Config mistakes abort before boot: a reserved, duplicate or unusable
  tag (including `.`, `..` or a leading `-`), a missing source, a
  directory source with a comma in its path, or a `path` that is
  relative, carries `..`, overlaps a reserved mountpoint or repeats
  another entry.
- A failed mount inside the guest warns and the session continues.

Cached images rebuild once to pick this up.

## 0.17.3 — 2026-08-03

A marketplace declared only in a boot file no longer fails the image
build when the build cannot reach its url, such as `/mnt/repo`. The
build warns and continues, and the marketplace is registered at boot. A
bake-declared marketplace still aborts the build.

Malformed entries now abort at launch and name the entry, where they
used to produce a wrong mount tag or vanish silently, so a config
carrying one must be fixed before it launches again:

- a `mounts` entry with no `tag` or no `source`
- a `claude.marketplaces` entry with no `name`
- an empty ref in `claude.plugins.enabled`

An `apt_sources` entry with no `repo` no longer has its key url written
out as a source.

## 0.17.2 — 2026-08-02

The example config, skill and docs no longer tell you to add `golang`
to `packages.bake` for guardrails: it ships prebuilt binaries and needs
nothing there.

## 0.17.1 — 2026-08-01

Internal only: table formatting in the global config skill. Behavior is
unchanged.

## 0.17.0 — 2026-08-01

Marketplaces and plugins can now be driven from config.

- `claude.plugins.bake` installs plugins into the guest image.
  `claude.marketplaces` is legal in both bake and boot files.
- `claude.plugins.install_at_boot` installs at boot, and
  `claude.plugins.update_at_boot` (on by default) refreshes marketplaces
  and reinstalls plugins whose version changed, without a rebuild. Both
  block until done, before `claude` starts.
- A failure at bake time fails the build, so a cached image never
  silently lacks a plugin. A failure at boot warns and the session goes
  on.
- A `claude.plugins` sub-key in the wrong file aborts rather than doing
  nothing.
- Marketplace hosts join the egress allowlist only when boot-time work
  needs them, or always under
  `add_marketplace_uris_to_allowlist: always`. Each addition is logged.

## 0.16.7 — 2026-07-25

Config splits into a bake file and a boot file per tier, and every run
now boots its own copy of the guest image, so concurrent sessions share
no state.

- Use `config-bake.yml` and `config-boot.yml`, globally and per repo,
  all optional. Keys that change the guest image's bytes go in a bake
  file and run-time keys in a boot file. `packages:` means baked in a
  bake file and installed at boot in a boot file.
- **Migration:** a single-file `config.yml` is no longer read, and the
  launcher aborts with a migration message.
- The image is keyed on the raw bytes of the bake files. Any edit there
  rebuilds, even a trailing newline, which doubles as a force-rebuild
  lever. Boot files never trigger a rebuild. A repo with its own bake
  file gets its own image; others share the global one.
- The base image is never attached to a VM. Each run boots an APFS
  clone, discarded on a clean exit and retained on an abnormal one.
- `apt_sources` is allowed in both files. Conflicting content under one
  name aborts.

## 0.10.11 — 2026-07-21

The guest can now run apt at boot, before `claude` starts, and apt works
for the rest of the session.

- `packages.update_at_boot` (on by default) updates and upgrades, and
  `packages.install_at_boot` installs a list, using any configured
  `apt_sources`. A failure warns and the session still starts.
- Debian and `apt_sources` hosts join the egress allowlist only when
  boot-time apt work is configured, or always under
  `packages.add_apt_uris_to_allowlist: always`. Each addition is logged.
- `apt` is now in the base image and proxied for any later `apt-get`.
  Lowercase proxy variables are also exported, since apt honors only
  those.
- Apt's per-boot working set drops from about 250 MB to about 50 MB.
- `image.root_headroom_mb` (default 1024) sizes free space on the guest
  root. Changing it rebuilds the image.
- Image filenames now show whose config they were built from, global
  and per repo.
- Binary OpenPGP keys from an `apt_source` now work. They were saved as
  `.asc`, which apt silently loaded as an empty keyring, giving
  `NO_PUBKEY` on every boot.

## 0.10.4 — 2026-07-17

`packages.bake` and `packages.apt_sources` now bake apt packages and
third-party repos into the guest image, so large, stable tools install
once and are reused across runs.

- Configs with nothing baked share one image. Each distinct baked
  config gets its own cached variant, and an explicit `guest_image` is
  used as given.
- An `apt_sources` repo line may carry its own `[options]` block, which
  is merged rather than duplicated. A `signed-by=` path must sit under
  `/etc/apt/keyrings` or `/usr/share/keyrings`, because a per-repo
  config could otherwise write a fetched key anywhere in the image.

## 0.9.0 — 2026-07-15

The guest now boots with a `settings.json` rendered from your claude-vm
config, and never from the host's.

- `claude.permissions.allow`, `ask` and `deny` carry through verbatim.
- `claude.permission_mode` defaults to `bypassPermissions`, with the VM
  as the isolation boundary and the deny list as a backstop. `default`
  is the only other accepted value.
- Plugins are enabled from the plugin lists, and the new
  `claude.plugins.enabled` map overrides them. `false` leaves a plugin
  installed but disabled. An unknown ref or non-boolean value aborts.
- **Schema change:** `claude.hooks.parser` and
  `claude.hooks.no_background_agents` are removed in favor of that map.
- `IS_SANDBOX=1` is always set so `claude` accepts running as root in
  `bypassPermissions`.

Cached images rebuild once to pick this up.

## 0.8.1 — 2026-07-14

The config now accepts and merges keys for packages, permissions,
marketplaces, plugins, hooks and GitHub auth. This adds schema only:
nothing acts on these keys yet.

## 0.7.0 — 2026-07-12

A one-command entry point: run `claude-vm` from anywhere inside a repo,
replacing the long path into the plugin's payload.

- It moves to the repo root, takes the repo name from `origin`, which
  is required, and names the run from your arguments or a date stamp.
- With no global config it points you at `/claude-vm-config-global` and
  proceeds on defaults.
- It fails fast before any clone or boot when the Keychain holds no
  credential.

## 0.6.9 — 2026-07-11

`claude-vm` is now an interactive session: your terminal becomes the
guest's console, running `claude` inside the VM with no shell in
between. Headless one-shot runs are gone, and `--remote-control --name
<n>` passes through for watching from elsewhere.

- The guest comes up onboarded, logged in, with the repo trusted and
  self-update off.
- A Keychain credential with empty tokens aborts at launch with a
  host-side relogin message, instead of booting a logged-out guest.
- The new `claude.renderer` key picks `classic` or `fullscreen`. Terminal
  size is seeded once at launch, so there is no live resize.
- Boot output stays off your terminal and goes to the console log.
- A normally nested repo path no longer overflows the socket path limit
  and prevents booting.

Cached images rebuild once to pick this up.

## 0.5.16 — 2026-06-29

Guest boots are now observable: the guest console is captured to
`guest-console.log` in the run directory, and the exit message gives
its path. In-guest failures used to leave no trace on the host.

## 0.5.15 — 2026-06-28

The guest now authenticates with your live claude.ai login, which Remote
Control requires. `ANTHROPIC_VM_TOKEN` is gone.

The launcher reads the credential from the macOS Keychain at launch,
shares it into the guest on a dedicated mount, and removes it on every
exit. It is never written to config or the run environment. A launch
with no Keychain credential aborts with a message saying what to do.

## 0.5.10 — 2026-06-26

The guest now runs a real `claude`, fetched and verified on the host and
shared into the guest read-only.

- `claude.version` takes `stable` (default), `latest` or a pinned
  version.
- The launcher checks a GPG-signed manifest against a key you import
  once, then checks the binary's checksum against that manifest. A
  failure at either step aborts the launch, and nothing unverified is
  cached or run. `install.sh | bash` remains only as an explicit
  lower-trust fallback when no cache is configured.
- Verified binaries are cached by version. A cached version skips the
  download and drops `claude.ai` and `downloads.claude.ai` from the
  guest's egress allowlist.

## 0.5.7 — 2026-06-25

The bundled provisioner now builds a guest image that boots, with egress
confined to the allowlist, on a real host. This fixes a chain of failures
in the image build and in guest boot: console, first-boot wizard,
networking and mounts. The boot still stops short of running `claude`.

## 0.5.5 — 2026-06-25

The host acceptance test now finds a stopped default podman machine,
rather than failing on the `*` marker podman adds to its name. It also
skips when `jq` is missing. Launches are unaffected.

## 0.5.4 — 2026-06-22

Starting point. The plugin launches Claude Code in an isolated VM, with
every non-secret setting coming from YAML config, global and per repo,
rather than environment variables.

- Config covers VM resources, the egress allowlist, extra mounts, the
  forward proxy (bundled tinyproxy by default) and the repo strategy:
  `clone` (default) or `live`.
- Clone-mode work copies back to the local source on exit by default.
  `/claude-vm-diff`, `/claude-vm-apply-local` and
  `/claude-vm-apply-remote` extract it explicitly.
- `/claude-vm-config-global` and `/claude-vm-config-repo` write the
  config.
- The guest image is built on demand and version-pinned. Its boot stops
  at a seam where `claude` will be fetched; `claude` is not yet
  installed in the guest.
- The only secret, `ANTHROPIC_VM_TOKEN`, is an environment variable.
