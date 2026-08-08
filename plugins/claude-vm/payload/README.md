# claude-vm payload directory

This directory ships the executable payloads for the `claude-vm`
plugin: the config-driven launcher, the guest-image build recipe, the
config loader library, the annotated example config pair
(`config-bake.example.yml` / `config-boot.example.yml`), and the
config-layering unit test. They travel with the plugin and live at
`${CLAUDE_PLUGIN_ROOT}/payload/...` once installed.

The plugin's user-facing entry point, `bin/claude-vm` (issue #51), lives
one directory up at `${CLAUDE_PLUGIN_ROOT}/bin/claude-vm` — a preflight
wrapper that forwards to `payload/claude-vm.sh` (below). See "Entry
point (`bin/claude-vm`)" further down.

## Directory layout

```text
payload/
  README.md             # this file
  claude-vm.sh          # the launcher (config-driven; entry point)
  build-guest-image.sh  # version-pinned guest base build recipe
  config-bake.example.yml  # annotated example: image-bytes keys (packages
                        # baked in, apt_sources, image.root_headroom_mb,
                        # claude.marketplaces, claude.plugins.bake)
  config-boot.example.yml  # annotated example: run-time keys (egress, mounts,
                        # proxy, cpus/mem, boot packages, claude.*, github.*)
  lib/
    config.sh           # four-file (bake/boot per tier) YAML loader + layering
                        # + whole-file image-identity hashing (sourced by
                        # claude-vm.sh; directly testable)
    claude-cache.sh     # host-side, GPG-manifest-verified `claude` binary
                        # cache (sourced by claude-vm.sh; directly testable)
    endpoint.sh         # per-run endpoint acquisition (issue #179): free
                        # TCP-port acquisition, TCP/unix-socket liveness (live
                        # listener vs stale corpse), stale-corpse clearing
                        # (sourced by claude-vm.sh; directly testable). No
                        # vfkit REST shutdown helpers -- the guest powers itself
                        # off, so the host drives no shutdown.
  provisioners/
    podman-mkosi.sh     # bundled DEFAULT provisioner: mkosi in a throwaway
                        # rootless podman container -> raw EFI guest image
  proxy/
    tinyproxy-launch.sh # bundled DEFAULT proxy.cmd: renders a tinyproxy
                        # conf from $CLAUDE_VM_EGRESS_ALLOWLIST, execs it
  test/
    config-test.sh      # unit tests for the config layering
    endpoint-test.sh    # unit tests for per-run endpoint acquisition (issue
                        # #179): free-port acquisition, TCP/unix-socket
                        # liveness vs stale corpse, corpse clearing; uses real
                        # perl listeners, host-gated on /usr/bin/perl
    boot-launcher-test.sh
                        # regression test for the guest self-poweroff decision
                        # (issue #179): claude exit 0 -> SIGRTMIN+4 poweroff,
                        # nonzero -> root login shell on hvc1 as a CHILD, then
                        # poweroff when it exits (order asserted); getty respawn
                        # neutralized by Restart=no; LAUNCHER_LOGIC_REV bumped.
                        # Runs the emitted launcher's real decision fragment
                        # against stubs; needs only bash + awk
    launch-shape-test.sh
                        # regression test for the vfkit launch shape (issue
                        # #179): vfkit runs FOREGROUND -- no `&`, no
                        # VFKIT_PID/wait, no reap machinery -- and
                        # VM_EXIT_STATUS=$? follows the invocation directly.
                        # Grep-level source assertions; bash + awk only
    bin-config-check-test.sh
                        # regression test for bin/claude-vm's four-file
                        # config-presence check (issue #179 defect #3): no
                        # false "no global config" when the bake/boot pair is
                        # present; a leftover config.yml routes to migration
    claude-cache-test.sh
                        # unit tests for the verified claude cache
                        # (resolve/verify/checksum/abort/warm-boot; stubbed
                        # network+gpg, fully offline)
    podman-mkosi-test.sh
                        # regression tests for the generated mkosi recipe
                        # (issue #105 real-build follow-up); stubs podman
                        # at the container handoff, asserts on the literal
                        # generated mkosi.conf / build-in-container.sh
    host-acceptance.sh  # self-contained on-host acceptance test (build +
                        # boot + egress confinement); host-gated, skips
                        # when a required binary is absent, but starts a
                        # stopped/absent podman machine itself
    machine-name-resolution-test.sh
                        # regression test for the podman machine-name
                        # probe (issue #57); host-gated on jq
```

## Entry point (`bin/claude-vm`)

```bash
# No token env var. Be logged in to Claude Code on the host first: the
# launcher installs the host's live claude.ai OAuth credential (from the
# macOS Keychain) AND seeds the guest's identity (userID + oauthAccount from
# your ~/.claude.json, plus synthesized onboarding/auto-update-off keys) so the
# in-guest claude comes up already onboarded and logged in. See below.

# From inside the repo you want to launch a VM for:
claude-vm [claude args...]
```

`bin/claude-vm` (issue #51) is the preflight launcher and the intended
entry point — it ships in the plugin's `bin/` directory, which Claude
Code adds to PATH for the Bash tool, so it runs as the bare `claude-vm`
command with no long cache-path invocation. `cr()`-shaped: it derives
the repo name from the `origin` remote (failing clearly if you are not
in a repo, or the repo has no `origin`), moves to the repo root
(`git rev-parse --show-toplevel`), names the run from any trailing args
or a `date '+%b%d-%H:%M'` stamp so parallel VMs are individually named,
checks that the global config exists (offering to create it via
`/claude-vm-config-global` if not), fails fast if the macOS Keychain has
no claude.ai OAuth credential, and forwards the repo root plus any
trailing args to `payload/claude-vm.sh` below.

## Launcher (`claude-vm.sh`)

```bash
# Invoked by bin/claude-vm above; callable directly too.
"${CLAUDE_PLUGIN_ROOT}/payload/claude-vm.sh" /path/to/repo [claude args...]
```

Reads `cpus`, `mem`, `guest_image`, proxy config, `egress.allow`,
`mounts`, `repo.mount`, `repo.copy_back`, and the guest-software keys
from **four-file YAML** (issue #179): a **bake** file and a **boot**
file per tier —
`~/.config/claude-vm/config-bake.yml`,
`~/.config/claude-vm/config-boot.yml`,
`<repo>/.claude-vm/config-bake.yml`, and
`<repo>/.claude-vm/config-boot.yml`, all optional. A key that changes
bytes in the guest `.raw` image lives in a **bake** file; a key applied
at run time lives in a **boot** file. The effective config is the union
of all four, layering repo-over-global for scalars and unioning lists.
See the `claude-vm` skill (`skills/claude-vm/SKILL.md`) for the full
schema and semantics.

A legacy single-file `config.yml` (either tier) is **not** read anymore:
the launcher detects it and aborts with a migration message pointing at
the bake/boot split, rather than silently dropping the knobs it set.

## Authentication

The guest authenticates claude with the **host operator's live claude.ai
OAuth credential** — the full-scope login credential, not a scoped
inference token — installed at `$HOME/.claude/.credentials.json`. That
bearer token alone is **not** sufficient for the interactive TUI to treat
itself as onboarded and logged in: current Claude Code also decides "am I
onboarded / logged in" from state in `~/.claude.json`. A fresh throwaway
guest lacks that state, so without it every launch hits the
onboarding/login wall despite the mounted credential. Beyond identity, these
keys matter: `hasCompletedOnboarding` (absent → claude runs its onboarding
flow) and `autoUpdates` (unset → claude tries to self-update and fails
against its RO-mounted binary in the egress-confined guest).

So the launcher **also seeds the guest's identity + onboarding state**
(issue #88): it reads your host `~/.claude.json` and emits a seed carrying
`userID` and `oauthAccount` selected from the host, plus synthesized
keys: `hasCompletedOnboarding: true` (skip the wall), `autoUpdates: false`
(no self-update), and `lastOnboardingVersion` / `lastReleaseNotesSeen`
stamped with the resolved claude version. It **additively** carries a few
benign host UI keys when your `~/.claude.json` has them — `installMethod`,
`hasSeenTasksHint`, `hasUsedStash`, and `tipsHistory` — silently omitting
each when absent. And it seeds a **`projects` entry for the guest repo
mount** (`/mnt/repo`) with `hasTrustDialogAccepted` and
`hasCompletedProjectOnboarding` forced `true`, so the guest skips the "Do
you trust this folder? /mnt/repo" dialog on first boot (if your host
already has a project entry for the launched repo, a **named allowlist** of
benign per-project settings — `allowedTools` and friends — is carried over
and rekeyed to `/mnt/repo` with those two flags forced true; the operator's
prompt `history`, `lastSessionId`, and `mcpServers` are deliberately
**dropped**, and any unrecognized future key defaults to excluded). Nothing
else from `~/.claude.json` (no other `projects{}` entries, no telemetry, no
`machineID`) is copied — `machineID` in particular is left out so the guest
mints its own. The guest boot launcher installs the seed at
`$HOME/.claude.json` (mode `0600`) before launching `claude`, so the
in-guest session comes up already onboarded, logged in, and folder-trusted
— no wall, no trust prompt, no browser paste, no failed self-update. A
**preflight** aborts with an actionable message if the host
`~/.claude.json` is missing or lacks a usable `userID`/`oauthAccount`
(i.e. you are not logged in on the host). The seed carries account
identity, so it rides the same secret posture as the credential: written
under `umask 077` into the transient, owner-only (`0600`), shred-on-exit
`claudecreds` mount, **never** into `run.env` or the verified-binary
cache.

**Install-health check + auto-updater (issue #88).** Further guest-side
steps keep the interactive TUI quiet. First, claude runs a startup
*install-health check* that probes for a working `claude` at the native
installer's location `~/.local/bin/claude`; because the guest runs the
RO-mounted binary from `/mnt/claudebin` instead, that path is empty and the
TUI prints two `claude command at /root/.local/bin/claude missing or broken
· run claude install to repair` warnings. The boot launcher therefore
symlinks `$HOME/.local/bin/claude` → the verified RO-mounted binary right
after the claude-fetch seam validates it. The symlink target *is* the
running binary, so the health check's version comparison passes by
construction, and `autoUpdates: false` plus the RO mount prevent any
write-through. This is empirically confirmed to clear the warnings on real
hardware. Second, the launcher writes `DISABLE_AUTOUPDATER=1` into `run.env`
(the documented Claude Code env knob), belt-and-braces with the seeded
`autoUpdates: false` config key — the guest is egress-confined and runs an
RO-mounted binary, so an update attempt can only ever fail. That knob is not
a secret, so `run.env` (sourced under `set -a` in the guest launcher) is the
right vehicle.

**Rendered guest `settings.json` + `IS_SANDBOX` (issue #104).** The launcher
renders the guest's `/root/.claude/settings.json` **host-side** from the
merged claude-vm config and shares it into the guest over the same transient
`claudecreds` mount as the credential and seed; the boot launcher installs it
at `$HOME/.claude/settings.json`. The rendered file is derived from the
claude-vm configs **only** — the host's `~/.claude/settings.json` is never
read, so the guest deliberately runs its own posture (the host lists govern
Claude *outside* the VM; inside, one may run a different, riskier posture).
Its keys are: `permissions` (`allow`/`ask`/`deny` verbatim from
`claude.permissions.*`, plus `defaultMode` from `claude.permission_mode`,
default `bypassPermissions`; only `bypassPermissions`/`default` are accepted,
anything else aborts the launch), `enabledPlugins` (every ref in
`claude.plugins.bake ++ claude.plugins.install_at_boot` mapped to `true`, then
the optional `claude.plugins.enabled` map — which mirrors `settings.json`'s own
`enabledPlugins` vocabulary of plugin-ref → boolean — overrides those defaults
per key, so `false` marks a plugin installed-but-disabled), and
`extraKnownMarketplaces` (issue #107: the effective marketplace set in the
shape claude itself writes — see "Marketplaces and plugins" below). The
`enabled` map
is validated once: every value must be boolean and every key must name an
installed plugin ref, so a typo aborts the launch. claude-vm has **no** own
CLI flags — plugin enable/disable state comes from the config files, not the
command line. `bypassPermissions` is *YOLO-by-default* — the VM is the
isolation boundary, with the deny list as backstop. Because the guest runs
`claude` as **root**, and `claude` refuses `bypassPermissions` as root unless
`IS_SANDBOX=1` (or `CLAUDE_CODE_BUBBLEWRAP=1`), the launcher writes
`IS_SANDBOX=1` unconditionally into `run.env` — the guest *is* the sandbox.
`settings.json` is not a secret,
but it rides the `claudecreds` mount so every host-rendered guest `~/.claude`
file arrives over one dir rather than adding another virtio-fs device.

**Degraded-Keychain preflight (issue #88).** The Keychain item can hold a
structurally-complete `claudeAiOauth` object whose `accessToken` and
`refreshToken` are **empty strings** (with `expiresAt: 0`) — a degraded
state that happens when your host claude sessions keep working via the
shared auth daemon's in-memory tokens while the persisted Keychain entry
has gone stale. Booting the guest with that empty credential lands it at
"Not logged in · Run /login", and an in-guest `/login` can trip OAuth
reuse-detection and **revoke your other live sessions**. So after selecting
`claudeAiOauth`, the launcher **validates that both tokens are non-empty**
(`claude_vm_validate_claude_credential_tokens` in `lib/credential.sh`) and
aborts fast if they are not, steering you to re-login on the **host** (run
`claude` then `/login`, or restart Claude Code — either repairs the
Keychain entry) rather than into the guest.

At launch the launcher extracts the credential from the macOS login
Keychain by service name alone:

```bash
security find-generic-password -s "Claude Code-credentials" -w
```

That Keychain item is **not** only the claude.ai login — on a real host
its JSON carries sibling top-level keys, at minimum `claudeAiOauth` (the
intended full-scope login) and `mcpOAuth` (per-MCP-server OAuth, e.g. a
Sentry MCP token). To avoid pushing unrelated MCP credentials into the
guest, the launcher **selects only the `claudeAiOauth` key** from the raw
blob and writes a file in the shape `claude` expects,
`{"claudeAiOauth": { ... }}`, dropping `mcpOAuth` and any other siblings.
The selection runs via `lib/credential.sh` (using `python3`, stock on
macOS) and is unit-tested in `test/credential-test.sh`. The full raw blob
is held only in a transient tmpfile outside the share and removed
immediately after selection.

The selected `{"claudeAiOauth": {...}}` is written to a transient,
owner-only (`0600`) tmpfile and shared into the guest under
`mountTag=claudecreds`, which the image's own fstab mounts `ro`
(`provisioners/podman-mkosi.sh`). The `ro` is supplied by the **guest**, not
by the host: vfkit's virtio-fs device has no read-only export, so the host
shares this exactly as it shares an extra mount — read-write. It is the same
guest-side `ro` *Where the `ro` on a built-in share comes from* below
describes, with the same limit: it guards against an accidental write, not
against a determined one, since the guest session is root and can remount.
Nothing rests on it — the guest boot launcher copies the file into
`$HOME/.claude/.credentials.json` (mode `0600`) before launching `claude`,
so `claude` finds it at the path it expects and never needs to write to the
share.

The credential is a **secret** and is handled like one:

- It is **never** written to config, to `run.env`, or to the
  verified-binary cache.
- Its host-side tmpfile is created under a tightened `umask 077` and
  removed by the launcher's `cleanup()`/`trap` on every exit (including
  Ctrl-C) — it does not linger past the live VM.
- The full raw Keychain blob (before `claudeAiOauth` selection) lives
  only in a transient tmpfile **outside** the guest share and is removed
  immediately after the selection step, so the unselected form is never
  mounted into the guest.

**Requirements:** macOS only (`security find-generic-password` is a macOS
Keychain tool; `python3`, used for the credential and identity-seed
selection, ships with macOS), and you must be **logged in to Claude Code
on the host** first (run `claude` once and complete the claude.ai login).
If the host `~/.claude.json` is missing or lacks a usable
`userID`/`oauthAccount`, or the Keychain lookup returns empty or
non-zero, or the blob has no usable `claudeAiOauth` key, the launcher
fails fast with an actionable message rather than booting an
unauthenticated guest.
`egress.allow` must include the Anthropic API host (`api.anthropic.com`,
present in the example config) so the in-guest `claude` can reach it.

## Config loader (`lib/config.sh`)

Pure layering logic: two YAML inputs → one merged document. Both layers
are optional; a missing layer contributes an empty document. Scalars
are repo-over-global; list keys (`egress.allow`, `mounts`, and — as of
issue #103 — the guest-capability lists like `packages` and
`claude.permissions.allow`, including keys nested two levels deep) are
unioned and de-duplicated. See the `claude-vm` skill
(`skills/claude-vm/SKILL.md`) for the full schema and semantics.

It also carries the pure helpers the launcher builds the guest's `claude`
argv, settings, image identity, and plugin manifests from:

- `claude_vm_quote_args` — the host half of the `CLAUDE_ARGS`
  shell-quoting round-trip (issue #88). The user's post-repo CLI args
  travel to the guest as a single `CLAUDE_ARGS=` line in `run.env`. A
  flat unquoted join breaks the boot the instant an arg carries a space
  or a shell metacharacter (`--name "foo #7 micro-vm"` sourced as a bare
  line tries to *execute* the `--name` fragment, crashing the getty
  login program — which, in the pre-#179 respawning-getty world, looped
  forever; issue #179's `Restart=no` means that same crash now just ends
  the session instead of looping, but the quoting is still what keeps
  the boot correct). The launcher instead %q-quotes each arg
  (this helper) and %q-quotes the whole `CLAUDE_ARGS=` line, so sourcing
  `run.env` yields exactly the per-arg tokens; the guest boot launcher
  reverses it with `eval "set -- $CLAUDE_ARGS"`. Zero args → empty
  output (no stray `''`).
- `claude_vm_augment_rc_args` — the Remote Control / `--name` date-stamp
  augmentation (issue #88). Given the resolved `claude.remote_control`
  boolean and a date stamp, it injects `--remote-control` when the knob
  is on and it is not already present (no duplicate), and appends a
  date-stamped `--name` when Remote Control is in effect but no `--name`
  (`--name <v>` or `--name=<v>`) was given. With the knob off and no CLI
  `--remote-control`, the args pass through unchanged. The date stamp is
  computed host-side and passed in, so the helper stays pure and
  unit-tested.
- `claude_vm_render_guest_settings` — renders the guest's
  `settings.json` (issue #104) from the merged BOOT document plus the
  merged BAKE document (two arguments since issue #107 moved
  `claude.plugins.bake` into the bake file; an omitted bake doc simply
  contributes no baked refs). Pure (files in → JSON on stdout), so it is
  unit-tested host-side. Emits `permissions`
  (`allow`/`ask`/`deny` verbatim from `claude.permissions.*`, `defaultMode`
  from `claude.permission_mode`), `enabledPlugins` (every ref in
  bake ++ install_at_boot defaults `true`, then `claude.plugins.enabled`
  overrides per key), and `extraKnownMarketplaces` (the effective
  marketplace set, each entry rendered `{"source":"git","url":…}` for an
  http(s) url or `{"source":"github","repo":…}` for an `owner/repo`
  shorthand). Validates the `enabled` map once (non-empty keys; boolean
  values; keys must name installed refs) and returns non-zero on a typo so the
  launcher aborts. Reads the claude-vm config only — never the host
  `~/.claude/settings.json`.
- `claude_vm_bake_config_json` / `claude_vm_bake_hash` /
  `claude_vm_bake_hash_from_json` / `claude_vm_bake_config_is_empty` — the
  bake-config canonicalization helpers (issue #105). `claude_vm_bake_config_json`
  emits the **canonical** bake-relevant config (the bake doc's sorted
  `packages`, normalized `apt_sources`, and — as of issue #135 — its `env.set`
  map, sorted by key with every value rendered as a *string* via `tostring`,
  so a YAML `PORT: 8080` or `DEBUG: true` reaches the provisioner's Python as
  `"8080"`/`"true"` rather than as a JSON int/bool whose `str()` would be
  `True`) as compact JSON that the launcher passes to the provisioner as the
  MERGED build CONTENT; `claude_vm_bake_hash_from_json` hashes canonical JSON
  to 8 hex chars. All pure and unit-tested.
- `claude_vm_check_env` / `claude_vm_resolve_boot_env` /
  `claude_vm_env_set_names` / `claude_vm_env_set_tag` /
  `claude_vm_env_set_value` / `claude_vm_env_copy_names` /
  `claude_vm_env_files` / `claude_vm_env_bake_has_key` /
  `claude_vm_env_file_assignments` / `claude_vm_env_name_is_valid` /
  `claude_vm_env_name_is_reserved` — the **guest environment** helpers
  (issue #135). `claude_vm_check_env` is the single load-time gate over the
  whole `env:` contract in both tiers; `claude_vm_resolve_boot_env` emits the
  boot tier as ready-to-source `NAME=<shell-quoted value>` lines in
  precedence order. See *Guest environment variables* below for the design
  those two implement. The rest are the accessors they are built from:
  `claude_vm_env_set_names`/`_tag`/`_value` read one `env.set` entry at a
  time — deliberately *not* through a shared `@tsv` record, because an
  environment value may legitimately contain a tab or a newline and `@tsv`
  would escape those into a literal `\t`/`\n`, silently changing what the
  operator wrote. For the same reason `_value` returns the value already
  `%q`-quoted rather than raw: yq ends its output with one `\n` of its own and
  `$(...)` strips *all* trailing newlines, so a caller capturing raw bytes
  cannot tell `X: "a\nb"` from `X: "a\nb\n\n"`. `_value` strips exactly yq's
  one newline behind a sentinel byte and quotes what is left, and `%q` output
  never ends in a literal newline, so the caller's own capture is lossless.
  Without that the boot tier would ship a shorter value than the bake tier for
  the same literal, since the bake path carries the value inside JSON
  (`claude_vm_bake_config_json`) and `shlex.quote`s it byte-exactly;
  `claude_vm_env_bake_has_key` is the `has()` presence test
  behind the bake-tier abort, and it is asked of a **raw** bake file rather than
  of `MERGED_BAKE` — the merge prunes exactly the spelling it exists to catch
  (see *Guest environment variables* below), so `claude_vm_check_env` takes the
  two raw bake paths alongside the two merged documents;
  `claude_vm_env_file_assignments` parses one host
  `.env` file into those same assignment lines. All pure except the two that
  read the launcher's own environment (`claude_vm_check_env`'s `env.copy`
  arm and `claude_vm_resolve_boot_env`), and all unit-tested — including
  under the host's pre-4 bash, since the gate is a config-load guard.
- `claude_vm_file_identity_hash` / `claude_vm_sanitize_repo_name` /
  `claude_vm_image_identity_segments` — the **image-identity** helpers
  (issue #106 redesign, re-redesigned by issue #179 to a whole-file, raw-byte
  hash). `claude_vm_file_identity_hash` hashes a single bake config file's raw
  bytes (no canonicalization); a missing file hashes to the `00000000`
  sentinel. `claude_vm_image_identity_segments` composes the self-documenting
  identity from the two bake files: always `global<globalhash>`, plus
  `+<reponame>-<repohash>` when a repo-bake file exists (name sanitized by
  `claude_vm_sanitize_repo_name`). `build-guest-image.sh` receives the
  pre-computed segments verbatim via `CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS`, so
  the stamped version and the launcher's filename agree by construction. All
  pure and unit-tested.
- `claude_vm_effective_marketplaces` / `claude_vm_baked_marketplace_names` /
  `claude_vm_bake_plugins_json` — the **marketplace/plugin manifest** helpers
  (issue #107). `claude_vm_effective_marketplaces` emits the bake ++ boot
  union as `name<TAB>url` lines, deduped by `name`, which the launcher writes
  to `plugin-marketplaces.tsv` on the `runconfig` share;
  `claude_vm_baked_marketplace_names` names the bake-declared ones, the set
  the image is guaranteed to carry, and is read host-side only — by the
  derived-egress gate and by the `origin` stamp below, never by the guest,
  whose boot phase asks the CLI what is actually registered;
  `claude_vm_bake_plugins_json` emits the build's plugin CONTENT (the
  effective marketplaces plus the bake doc's sorted `claude.plugins.bake`) as
  compact JSON, the sibling of `claude_vm_bake_config_json`. Each marketplace
  entry in that JSON carries an `origin` of `bake` or `boot` (issue #226),
  decided by whether the name appears in the bake doc, which is what lets the
  provisioner apply a different build-time failure policy per entry — see
  *Bake path* below. All pure and unit-tested.
- `claude_vm_check_plugin_key_placement` / `claude_vm_plugin_raw_has_key` /
  `claude_vm_check_marketplace_conflicts`
  — the **abort guards** (issue #107). The first rejects a `claude.plugins`
  sub-key written into the file type that never reads it (`bake` in a boot
  file, or `install_at_boot`/`update_at_boot`/`add_marketplace_uris_to_allowlist`/
  `enabled` in a bake file), naming the file that carries it. Like the env
  bake-tier abort it is a **presence** test — `claude_vm_plugin_raw_has_key`'s
  `has()` — asked of the RAW files the operator wrote, so it takes the four raw
  config paths (global bake, repo bake, global boot, repo boot) and no merged
  document at all. Both of its directions need raw paths, which is why it takes
  four where `claude_vm_check_env` takes the bake pair only; see *Guest
  environment variables* below for the prune routes behind that. The second
  rejects one
  marketplace `name` carrying differing `url`s across the tiers, the same
  shape as `claude_vm_check_apt_sources_conflicts`. Both turn a silent no-op
  into a loud launch abort.
- `claude_vm_check_marketplace_names` / `claude_vm_check_mounts` — the
  **malformed-entry guards** (issue #226), same shape and same abort-at-load
  wiring as the pair above. The first rejects a `claude.marketplaces` entry
  with no `name` in either document, naming the tier, the entry number and
  the url: the name is the key every reader of the effective set matches on,
  so an unnamed entry is dropped by all of them and the operator silently
  gets no marketplace. The second rejects a `mounts` entry with no `source`
  or no `tag`, naming the entry number — plus the mount path, which only the
  tagless case has: the guest mounts each virtio-fs share *by* its tag, so a
  tagless entry is a share nobody can mount and two of them collide on one
  tag. Both read the same `@tsv` records their consumers
  do, split the same way — see *Splitting a TSV record back apart* below.

  Issue #157 extended `claude_vm_check_mounts` rather than adding a second
  gate the launcher would have to remember to call, so the whole `mounts`
  contract is enforced in one function and one pass. Its added rejections,
  each a config an operator can write today that would otherwise produce a
  VM that boots and looks fine while the mount is missing, shadowed, or
  somewhere else: a `tag` outside `[A-Za-z0-9._-]`, or one that charset
  admits but another of its uses does not (see *The tag is not just a tag*
  below); a `tag` colliding with one of the reserved
  built-ins in `CLAUDE_VM_RESERVED_MOUNT_TAGS` (`repo`, `runconfig`,
  `claudebin`, `claudecreds` — the launcher always attaches those and the
  image's fstab always mounts them); a `tag` repeated across the merged
  global+repo list (two devices, one guest mount, kernel-enumeration order
  deciding which wins); a `source` that does not exist on the host (otherwise
  vfkit fails minutes into the launch with a message about a device rather
  than about the config line); a **directory** `source` whose path carries a
  comma (same reason, below); a `mode` key at all (see *No read-only mounts*
  below); and a `path` that is relative, carries a `..` segment, *overlaps* a
  reserved guest mountpoint — landing on one, above one or inside one, see
  `claude_vm_guest_paths_overlap` below — shadows a guest OS path, or
  duplicates another entry's effective mountpoint. The reserved mountpoints
  are the built-in tags' own (`<CLAUDE_VM_GUEST_MOUNT_ROOT>/<tag>`, derived
  from the tag list so the sets cannot drift apart) plus
  `CLAUDE_VM_GUEST_WRAP_MOUNT`, the guest path every single-file mount is
  staged through.

  *The tag is not just a tag.* It is used in more positions than the charset
  check's own justification names, and every one of them consumes it
  **verbatim**: vfkit's `mountTag=` inside the comma-delimited `--device`
  string; a bare argv word in the guest's
  `mount -t virtiofs -o rw <tag> <path>`; a
  **path component** in the default guest mountpoint
  `<CLAUDE_VM_GUEST_MOUNT_ROOT>/<tag>`, in the launcher's host-side wrap
  directory a single-file source is staged in (`$MOUNT_WRAP_DIR/<tag>`) and
  in that wrap's own guest mountpoint (`<CLAUDE_VM_GUEST_WRAP_MOUNT>/<tag>`);
  and a field in `mounts.tsv`. The charset check names only the device string
  and the argv word, which makes it necessary but not sufficient —
  `[A-Za-z0-9._-]` admits spellings that are fine as a device tag and
  unusable as the rest:

  - `.` and `..` are not path *components*. `tag: ".."` walks one level up
    out of each of those trees the entry reaches — the default mountpoint,
    for any entry, and both wrap paths, for a single-file one (a directory
    source is shared as itself and is never wrapped) — and the `..`
    rejection on `path:` never sees it: that guard sits inside
    `if [ -n "$path" ]`, so a tag-derived mountpoint never reaches it, and
    with an explicit `path:` the mountpoint is clean while the wrap paths
    are still walked up. The launcher would then share the wrap directory's
    *parent*: `$RUN` (which holds `creds/.credentials.json`) under
    `repo.mount: clone`, or `$TMPDIR` itself under `live` (where the wrap
    dir is a `mktemp -d` under `$TMPDIR`, since `$RUN` sits inside the
    shared repo), mounted read-write in the guest one level above
    `CLAUDE_VM_GUEST_WRAP_MOUNT`. A run of three or more dots (`...`) and a
    `..` inside a longer name (`a..b`) are ordinary component names and still
    pass.
  - A leading `-` is not an argv *word*. The guest's `mount` reads it as an
    option rather than as the device, and one such tag fails **open**:
    measured on util-linux 2.38.1, `mount -t virtiofs -o rw -a <path>` exits
    `0` having mounted nothing, so `boot_mount_phase`'s success arm would log
    a mount that never happened. `--bind`, `-o` and `-r` fail loudly instead,
    and an interior or trailing dash (`a-b`) is ordinary and still passes.

  The `source` half of that device string has the same shape and one live
  case: a **directory** source is what vfkit shares, so the operator's path
  sits inside `--device virtio-fs,sharedDir=<source>,mountTag=<tag>` as the
  field the tag's own charset check does not reach. Measured on vfkit v0.6.4,
  a bare comma (`sharedDir=/tmp/a,b`) aborts with
  `unknown option for virtio-fs devices: b` — the device-shaped, launch-late
  failure the host-existence check exists to forestall — and a source
  spelling a second `sharedDir=` replaces the first, since the last key of a
  repeated pair wins. A **single-file** source is exempt and is deliberately
  not checked: what gets shared then is the wrap directory, whose `<tag>`
  *component* the check above already settled, so the operator's filename
  reaches only a hard link and a `mounts.tsv` field.

  The component is not the directory, though. `$MOUNT_WRAP_DIR` is
  `$RUN/mount-wrap`, or a `mktemp -d` under `$TMPDIR` when `$RUN` sits inside
  the repo share, and neither is a config value `claude_vm_check_mounts` can
  see — so the exemption settles the `<tag>` and nothing else, and a comma in
  `$TMPDIR` alone yields the malformed device string the arm above exists to
  prevent, on an entry the validator accepted. The launcher therefore checks
  the wrap directory itself, in the single-file branch of its extra-mount
  loop: that is where `$RUN` and the `$TMPDIR` fallback are both in scope
  (which is why the check is not in the validator) and where the entry being
  wrapped is in hand, so the message can name it and blame `$TMPDIR` or the
  run dir rather than the `mounts` value, which is not what is wrong.

  That comma exposure is **not** confined to `mounts`, and the check above
  does not cover the rest of it. **Every** vfkit argument that embeds a host
  path embeds it in a comma-delimited option string, with no comma check at
  all. The built-in shares: `sharedDir=$MOUNT_SHARED_DIR` (`$REPO_SRC` under
  `repo.mount: live`, else `$RUN/worktree`), `sharedDir=$CONFIG_DIR` and
  `sharedDir=$CREDS_DIR` (both under `$RUN`, which is
  `<repo>/.claude/tmp/<run-id>` whenever the argument is a git repo, in
  either mount mode), and `sharedDir=$CLAUDE_BIN_DIR` (under
  `CLAUDE_VM_CACHE_DIR`, i.e. `$XDG_CONFIG_HOME`/`$HOME` by default). And,
  outside the shares: `--bootloader efi,variable-store=$EFISTORE,create`,
  `virtio-blk,path=$GUEST_IMAGE_CLONE` and
  `virtio-serial,logFilePath=$GUEST_CONSOLE_LOG`, all under `$RUN`; and
  `virtio-net,unixSocketPath=$GVPROXY_SOCK`, whose directory is a
  `mktemp -d` under `$TMPDIR` on **every** launch — in either mount mode,
  git repo or not. So a repo — or a `$HOME`, or a `$TMPDIR` — whose path
  carries a comma breaks the launch the same way, before any extra mount is
  involved: measured on vfkit v0.6.4, each of those spellings dies on the
  text after the comma — `unknown option for virtio-net devices: …` for the
  socket, `unknown option for EFI bootloaders: …` for the variable store, and
  so on per argument. It is left unchecked deliberately: unlike a `mounts`
  entry, none of these paths is a config value an operator can fix by editing
  YAML, and an ordinary comma is launch-time-loud (vfkit refuses the unknown
  option and the launch stops) rather than a VM that boots with a share
  pointing somewhere else — only a path that itself spelled a second copy of
  that argument's own key (`sharedDir=`, `path=`, `logFilePath=`,
  `unixSocketPath=`, `variable-store=`) would fail quietly, since vfkit v0.6.4
  parses a repeated key without complaint rather than refusing it, and that is
  not a path anyone has. A guard for it would belong at argument-validation
  time, next to the repo-path resolution, not in `claude_vm_check_mounts`.

  The one line in that class that *is* guarded is the single-file wrap share,
  `sharedDir=$MOUNT_WRAP_DIR/<tag>` — not a built-in, and the only member
  this feature adds. The guard does not make a comma-carrying `$RUN` or
  `$TMPDIR` survivable; the lines above already break the launch in both of
  those shapes, mounts or no mounts. What it buys is what the host-existence
  check buys: an abort at mount-setup time, naming `$TMPDIR` or the run dir,
  instead of a device-shaped complaint from vfkit minutes later — and it
  keeps this feature from adding a share to an argument string it can already
  see is malformed. A guard that actually covers the class belongs where
  every one of those paths is resolved, per the paragraph above; this one is
  deliberately narrower than that.

  It sits at the point of **use**, in the single-file branch, rather than
  beside the `$MOUNT_WRAP_DIR` assignment a few lines above the loop, because
  at the assignment there is no entry in hand and naming one is the whole
  value of the message — the operator has to be told that the comma is not in
  anything they wrote under `mounts:`. That placement also fixes its scope: it
  fires only for a config that actually wraps a file, so a directory-only
  `mounts` list under the same comma-carrying `$TMPDIR` is not aborted (that
  launch still dies later, on the gvproxy socket's own `$TMPDIR` path).

  *Guest OS paths, by shape.* `CLAUDE_VM_GUEST_SYSTEM_PATHS` is the guest's
  own directory set. Linux **stacks** a mount, so an entry landing on one
  hides the image's files there for the life of the VM — and
  `boot_mount_phase` runs first, so the damage always precedes the step that
  would have noticed (`path: /root` hides `$HOME` before the credential seed
  writes `/root/.claude` into it, and the boot then fails somewhere else
  entirely). The rule splits by shape, because a directory mount hides a whole
  subtree while a single-file bind replaces exactly one file: a **directory**
  source may not land on, above, or inside a system path, while a **single
  file** may not land on or above one and may sit inside only
  `CLAUDE_VM_GUEST_USER_FILE_PATHS` (`/root`, `/home`, `/tmp`), whose contents
  are user data rather than package files. That split is what keeps #157's own
  `path: /root/.gitconfig` case working while `path: /root` and
  `path: /etc/ld.so.preload` do not. `/mnt` is deliberately **not** in the
  system set — it is claude-vm's own mount root, and `/mnt/<tag>` is the
  default mountpoint — and neither are `/media`, `/opt` and `/srv`, the FHS
  mount-something-here directories that ship empty. Membership was measured
  rather than recalled: a stock `debian:12` rootfs was enumerated directory by
  directory, and `/bin /dev /etc /lib /proc /root /run /sbin /sys /usr /var`
  all carry content while `/boot /home /media /mnt /opt /srv /tmp` ship empty
  (`/boot`, `/home` and `/tmp` are in the set anyway — `/boot` is populated in
  a bootable image rather than a container rootfs, and the other two are
  OS-owned working areas). The host list is necessarily a **denylist**, since
  the launcher cannot read the image's filesystem; the guest's own occupancy
  check (below) is the observation that can.

- `claude_vm_expand_mount_source` / `claude_vm_mount_guest_path` /
  `claude_vm_guest_path_covers` / `claude_vm_guest_paths_overlap` /
  `claude_vm_guest_system_path_containing` — the pure helpers the mount
  contract is defined by, so the validator and the launcher can never
  disagree about what a config line means. The first expands a leading `~`
  to `$HOME` (the config is YAML, not shell, so nothing else does). The
  second returns an entry's guest mountpoint — its `path:` when set, else
  `<CLAUDE_VM_GUEST_MOUNT_ROOT>/<tag>` — with repeated slashes collapsed,
  `.` segments collapsed, and trailing slashes dropped.

  That normalization is a **security boundary**, not cosmetics. Every guard
  in `claude_vm_check_mounts` is a string relation over this function's
  output, and the launcher writes the same output into `mounts.tsv`, so any
  spelling that reaches the guards un-normalized walks past all of them at
  once *and* lands the mount at the path they would have rejected. The class
  is "two strings naming one guest path", and each member is graded by
  whether the *host* can settle it. Collapsed here, because it can:
  `//mnt/repo`, `/mnt/repo/`, and a `.` segment in any position — `/./etc`,
  `/mnt/./repo`, `/etc/.`, and `/.` for the guest root itself. Rejected by
  the validator, because it cannot: `/mnt/x/../repo` and any relative path.
  Invisible to both: a guest symlink, where `/bin` and `/usr/bin` name one
  directory.

  A `.` segment is resolvable because it names the directory it sits in
  whatever the guest's filesystem holds — unlike `..`, no symlink can change
  where it lands — so the host collapses it rather than guessing. `..` needs
  the guest's filesystem and a symlink mid-path changes the answer, so the
  validator rejects a path carrying one; a relative path depends on the boot
  launcher's cwd, which is likewise not a host-side fact. A run of three or
  more dots (`/.../weird`) is an ordinary directory name and is left alone.
  Guest symlinks are invisible to any normalizer — the image is usr-merged,
  so `/bin`, `/sbin` and `/lib` are symlinks into `/usr` (measured on
  `debian:bookworm`/arm64; the `/lib{32,64,x32}` spellings are absent on that
  arch) — but both names of every such pair are *covered* by
  `CLAUDE_VM_GUEST_SYSTEM_PATHS`, so either spelling hits the denylist:
  `/bin`, `/sbin` and `/lib` are in the list themselves, and their `/usr/…`
  targets sit under `/usr`, which is. The guest's own occupancy check is the
  backstop beyond it. Case folding is not in the class at all: the guest root
  filesystem is ext4, so `/Etc` and `/etc` are genuinely different
  directories. The slashes the function substitutes with are held in variables
  rather than written inline, for a bash-version reason that would otherwise
  defeat the whole normalization — see *A guard must survive the oldest bash
  that can reach it* below.

  `claude_vm_guest_path_covers` is the directed relation: is path A equal to
  B, or a proper ancestor of it? It appends a `/` to each side so a prefix
  match can only land on a component boundary, which is what keeps an
  ordinary `/mnt/repofoo` from reading as a collision with `/mnt/repo`.
  `claude_vm_guest_paths_overlap` is covers-either-way, so the
  component-boundary logic lives in one place. Mount interference is not a
  string-equality relation, which is what the reserved-mountpoint guard
  originally tested and why `path: /mnt` and `path: /` both used to pass
  validation and then break the boot far downstream. A path *above* a
  reserved mountpoint swallows it (`/mnt` covers every built-in share at
  once, `/` covers the guest root); a path *below* one lands inside
  somebody else's share (`/mnt/repo/sub` makes the guest create a
  directory in the host's shared repo tree, then hides whatever the repo
  really has there). `claude_vm_guest_system_path_containing` names *which*
  system path a mountpoint sits strictly inside, which is what the
  single-file rule needs — it must tell `/root/.gitconfig` (fine) from
  `/etc/ld.so.preload` (a mount over a system file), and only the containing
  directory distinguishes them.
- `claude_vm_marketplace_hosts` / `claude_vm_marketplaces_without_host` /
  `claude_vm_boot_marketplace_egress_needed` — the **derived marketplace
  egress** helpers (issue #107), the plugin-side siblings of the apt egress
  derivation. Hosts are parsed permissively out of http(s) urls;
  a non-http(s) url (the `owner/repo` shorthand, a local path) derives no
  host and is instead named by `claude_vm_marketplaces_without_host` so the
  launcher can warn per entry. `claude_vm_boot_marketplace_egress_needed`
  decides whether `auto` derives anything at all: `always`, a nonempty
  `install_at_boot`, a marketplace declared in the boot doc whose name is not
  bake-declared, or `update_at_boot` true with at least one marketplace
  configured. That third test is deliberately conservative rather than exact:
  since #226 the build only *tries* to pre-register a boot-declared
  marketplace, and the host cannot know whether it succeeded, so the gate
  derives egress for one even when the image turns out to carry it.

*Splitting a TSV record back apart (issue #226).* The helpers above emit
multi-field records through yq's `@tsv` over a fixed-length array, so every
line always carries every separator — but a consumer must **not** take one
apart with `IFS=$'\t' read -r a b c`. A tab is IFS *whitespace*, so `read`
collapses a run of tabs into a single separator *and* strips a leading one:
a record whose **middle** field is empty loses that field silently and shifts
every later field left, and one whose **leading** field is empty loses that.
Under #226 the middle-field case turned a marketplace entry with no url
(`name<TAB><TAB>origin`) into one whose origin was read as its url, making
the no-url boot branch unreachable and aborting the very build the issue
exists to keep alive. The same read shape sat on the other three-field
records too: an `apt_sources` entry with a `key_url` but no `repo` handed the key
url to `render_apt_source` as the repo *line* (writing a `sources.list.d`
entry that points at the key, with no key fetched), and a `mounts` entry with
an empty `tag` handed vfkit the `ro`/`rw` mode as the mount *tag* (that record
carried a `mode` field at the time; today the same empty tag would swallow the
guest `path` instead, which is what the test drives). The
two-field records carry the leading-field case: a `claude.marketplaces` entry
with a `url` but no `name` (`<TAB>url`) read its **url as its name**, so the
effective set and the bake manifest each carried a marketplace called
`https://…` with an empty url, and the guest's boot phase then rejected that
url-as-a-name for containing characters outside `[A-Za-z0-9._-]` — a
diagnostic about a marketplace nobody configured, while the entry the operator
did configure went unmentioned. A `claude.plugins.enabled` map with an empty
key (`<TAB>true`) likewise aborted the render blaming a plugin named `true`.

The `mounts` record is `source`, `tag`, `path` — three fields, with `tag` the
optional **middle** one, so an entry with no tag still emits
`source<TAB><TAB>path` and the collapsing read would hand the *path* to the tag
slot. (Issue #157 briefly carried a fourth `mode` field; removing read-only
support removed it again, and the guest's own manifest lost the same field.)
The guest side was written with a hand split from the start rather than gaining
one later.

**Every** reader — the marketplace and `apt_sources` loops in
`provisioners/podman-mkosi.sh`, `boot_apt_phase`'s `apt_sources` loop,
`boot_plugin_phase`'s marketplace loop and `boot_mount_phase`'s mount loop in
`build-guest-image.sh`, the
extra-mount loop in `claude-vm.sh`, and every two-field reader in
`lib/config.sh` (`claude_vm_effective_marketplaces`,
`claude_vm_marketplaces_without_host`,
`claude_vm_boot_marketplace_egress_needed`, `claude_vm_bake_plugins_json`,
both loops in `claude_vm_render_guest_settings`, and the two load-time gates
described below) — therefore reads the whole line with `IFS= read -r` and
splits it with `${rec%%$TAB*}` / `${rec#*$TAB}` parameter expansions, which
are total exactly because `@tsv` always writes every separator. No
`IFS=$'\t' read` survives in the payload's shipped code; the only ones left
are the negative controls in `test/config-test.sh`, which exist precisely to
be contrasted with. Write any new record reader the same way.

Note that an *empty result set* from one of these emitters is one **empty
line**, not zero bytes (yq prints a newline for `.mounts // [] | .[]` when
there are no mounts). Every reader skips a wholly empty record before judging
its fields — a validator that forgot to would reject every ordinary config.

*Splitting is half of it.* A correct split makes an empty key field visible;
it does not make such an entry usable, so the launcher rejects one at config
load rather than silently configuring nothing:
`claude_vm_check_marketplace_names` aborts on a `claude.marketplaces` entry
with no `name` (naming the tier, the entry number and the url),
`claude_vm_check_mounts` aborts on a `mounts` entry with no `source` or no
`tag` (naming the entry number, and the mount path in the tagless case —
a sourceless entry has no path to name), and
`claude_vm_render_guest_settings` aborts on an empty
`claude.plugins.enabled` key alongside its existing value/unknown-key
validation. `claude_vm_mount_specs` guards `.source`/`.tag`
with `// ""` so an *omitted* key and an explicit `""` reach that check as the
same empty field — unguarded, an omitted `tag:` rendered the literal string
`null`. The readers with no load-time gate of their own are the ones that run
in the **guest** — `boot_plugin_phase` and (issue #157) `boot_mount_phase`.
Neither needs one: the host has already aborted the launch before
`plugin-marketplaces.tsv` or `mounts.tsv` is written, so there the hand split,
a key-field guard and a logged warning are the floor.

Each split and each gate is pinned by a test that *runs* the real code against
records from the real emitter, asserting on the values the split produced
rather than grepping the source; the load-time gates are driven through the
launcher's own load block, sliced out of `claude-vm.sh`. The `apt_sources`,
mount, two-field and `boot_plugin_phase` cases add a negative control — the
pre-fix collapsing `read` rebuilt from the same captured lines, so the control
cannot drift away from the code it is contrasted with; the build-time
marketplace loop instead asserts on the observable outcome (a no-url boot
entry logs its skip and never tries to add `boot` as a url).

### Guest environment variables

`env:` (issue #135) is how a variable reaches the in-guest `claude` session —
a plain non-secret setting (`FOO_ENDPOINT`) or a third-party API key
(`OPENROUTER_API_KEY`, `TAVILY_API_KEY`) for a tool, MCP server or model
provider other than Anthropic or GitHub. **The tier each sub-key may be
declared in follows from how its value is obtained**, not from operator
preference:

| Sub-key | Bake tier | Boot tier | Value source |
| --------- | ----------- | ----------- | -------------- |
| `env.set` | yes | yes | explicit literal in the config |
| `env.copy` | no — hard abort | yes | host environment at launch |
| `env.files` | no — hard abort | yes | host `.env` file at launch |

A bake file is consumed at image-build time and its result is image **bytes**
that persist across every run of that image, which is then APFS-cloned per run
and outlives the session. A boot file is consumed per launch and its result is
shredded on exit. `env.copy`/`env.files` resolve against a host environment
that does not exist at image-build time, and a value read from it is exactly
the kind of secret that must never become image bytes — so only explicitly
written literals are bakeable, and the two host-sourced sub-keys abort in a
bake file. That abort is a **presence** test (`has()`), for the same reason
the `mode:` abort is: an empty or valueless `env.copy:` renders identically to
an omitted one, and ignoring it silently would leave an operator believing a
host variable is forwarded into a persistent image.

*A presence test asks the raw files, not the merged document.* `.env.copy` and
`.env.files` are `CLAUDE_VM_LIST_KEYS`, so the tier merge unions them and
`claude_vm_prune_empty_skeleton` then deletes the key when it resolves to
nothing — and the `env:` map left holding nothing with it. That prune exists
precisely so a consumer cannot read presence off a merged document (see its
header in `lib/config.sh`), so `has("copy")` on `MERGED_BAKE` answers *false*
for the valueless `copy:` this gate is meant to catch. The first round of this
feature asked the merged document and let exactly that config build an image, on
a real launch. `claude_vm_check_env` therefore takes the **raw** global and repo
bake paths as its third and fourth arguments and asks each of them, which is
also what lets the diagnostic name *which* bake file the key is in. Carving the
two keys out of the prune would have been the wrong repair twice over: it leaves
the "configured empty looks configured" trap in place for the next reader, and
it changes merge behavior for keys that have nothing to do with `env:`. The
partial counter-case is `claude_vm_mount_mode_entries`, which still asks a
merged document: `mode:` sits inside a list *element*, which pass 1 never
examines, and the entry map is never empty (`{mode: null}` has length 1) — but
pass 2 is spelled `del(.. | select(tag == "!!map" and length == 0))`, and that
`..` descends into list elements, so a `mode: {}` *inside* an entry is deleted.
Measured through the real merge against yq v4.53.3, in both layers: `mode: ro`,
`mode: ""`, `mode: []` and a valueless `mode:` all reach the gate and abort the
launch; `mode: {}` arrives as an absent key and the launch proceeds. That is a
gap in the `mode:` abort, not a documented exemption — `config-test.sh` pins
the four surviving spellings through the real merge and has no `{}` case, which
is why it stayed invisible. `config-test.sh` runs the whole `env:` gate battery
through the real merge too — the shape that was missing when the launcher was
wrong and the suite was green — and pins both halves of the prune fact.

The rule generalises past `env:`, and `claude_vm_check_plugin_key_placement`
was the second gate to need it: it asked `(.claude.plugins.<key> != null)` of
the merged documents, and a misplaced key written in an empty spelling was
accepted in **both** directions. Measured through the real merge against yq
v4.53.3, the escapes were not uniform across the sub-keys — which is why every
one of them has to be graded rather than reasoned about from `bake`:

| Spelling | `bake`, `install_at_boot` (list keys) | `update_at_boot`, `add_marketplace_uris_to_allowlist`, `enabled` |
| ---------- | -------------------------------------- | ------------------------------------------------------------------ |
| valueless `key:` | accepted | accepted |
| `key: []` | accepted | aborted |
| `key: ""` | accepted | aborted |
| `key: {}` | accepted | accepted |

Three prune routes are at work. Pass 1 deletes the two list keys in the first
three spellings; pass 2 deletes an empty *map* wherever it sits, so `key: {}`
escapes for every sub-key, list key or not; and a valueless key reaches the
merged document as a genuine null, which `!= null` reads as absent. That last
one also made the old gate's verdict depend on which *layer* the file sat in —
the global-file-with-no-repo-file case deep-merges the null against the empty
document and coerces it to `''`, which `!= null` called present. The repair is
the same one `env:` got: `claude_vm_plugin_raw_has_key` asks `has()` of a raw
file. Because a BOOT-only key is hunted in the two BAKE files and a BAKE-only
key in the two BOOT files, the gate needs raw paths for **both** tiers, so it
takes the four raw config paths and no merged document — after the conversion
there is nothing left for a merged document to answer, since a key present in a
merged tier is present in one of that tier's two raw files by construction.
`config-test.sh` drives every case through `claude_vm_merge_config` in the
launcher's own argument shape and pins both halves of each prune route.

*Two carriers, one per tier.* `run.env` is neither, and stays entirely
launcher-owned — it is deliberately a non-secret channel, as the boot launcher
itself asserts, and it rides the `runconfig` share, which is not shredded.

- **Bake `env.set`** → `/etc/claude-vm/bake-env`, written into the image by
  `provisioners/podman-mkosi.sh` from the canonical bake-config JSON's `env`
  map (rendered by Python with `shlex.quote`, sorted by key, with a malformed
  name **failing the build** rather than being skipped — the file is sourced
  by the guest's shell, so an unchecked name is a way to smuggle a second
  statement into it).
- **The whole boot tier**, including the non-secret `env.set` literals →
  a 0600 `env` file in `$CREDS_DIR`, the same transient share
  (`mountTag=claudecreds`, mounted `ro` guest-side by the image's fstab) that
  already carries the OAuth credential and the identity seed, and which
  `cleanup()` shreds on exit. One carrier for the whole boot tier means the
  secret and non-secret boot paths cannot diverge. The guest **sources** it
  straight off the read-only mount and never copies it, so no forwarded value
  lands on the guest filesystem either.

*Precedence is emission order, not a merge pass.* Lowest to highest:

```text
bake env.set  <  boot env.files  <  boot env.copy  <  boot env.set
```

`claude_vm_resolve_boot_env` emits the boot tier's three sections in that
order as plain `NAME=<%q-quoted value>` lines, and the boot launcher sources
the baked file *then* the boot file, each under `set -a`. A later assignment
simply overwrites an earlier one, so the whole chain falls out of ordering
with no dedup logic, no associative array — and therefore nothing that needs
bash 4, which matters because the gate beside it is a config-load guard (see
*A guard must survive the oldest bash that can reach it* below). Within a
tier, merging is repo-over-global per key for `set` and a union for
`copy`/`files`; within `env.files`, a later file wins over an earlier one, by
the same emission order.

*Both tiers ship the value the operator wrote, to the byte.* The bake side gets
that for free — the value travels inside `claude_vm_bake_config_json`'s JSON
and Python `shlex.quote`s it. The boot side does not: yq ends its output with
one `\n` of its own and `$(...)` strips **all** trailing newlines, so a raw
capture cannot tell `X: "a\nb"` from `X: "a\nb\n\n"` and silently hands the
guest a shorter value than the config holds — with nothing downstream to notice.
`claude_vm_env_set_value` therefore captures behind a sentinel byte, strips
exactly yq's one newline, and returns the value already `%q`-quoted; `%q` output
carries no literal newline, so the caller's own capture cannot eat anything.
`config-test.sh` pins this by sourcing both tiers' rendered assignments for the
same trailing-newline literal and comparing the resulting bytes, with a negative
control on the raw-capture shape and a run under the host's pre-4 bash.

*Every mistake aborts at launch*, because the alternative is a guest that
boots and looks fine while lacking a key it was configured to have — which
surfaces much later, deep inside a tool call, as an opaque auth error naming
neither claude-vm nor the variable. `claude_vm_check_env` is one gate over all
of it: `env.copy`/`env.files` in a bake file; an `env.set` that is not a map;
a name outside `[A-Za-z_][A-Za-z0-9_]*` from any of the three sources; a name
the launcher itself composes (`CLAUDE_VM_RESERVED_ENV_NAMES` — the run.env set
plus `CLAUDE_VM_LAST_CLAUDE_STATUS`; the guest sources `run.env` *before* both
env files, so such an entry would silently overwrite the launcher's own
value — a different proxy, a renamed mount tag, a replaced `claude` argv — and
break the boot rather than configure anything, while the one name the launcher
exports *after* them, `CLAUDE_VM_LAST_CLAUDE_STATUS`, would be overwritten
instead); a non-scalar `env.set` value, or
a valueless key (`NAME: ""` is the way to ask for the empty string, and the
two spellings deliberately do not collapse); an `env.files` path that is not
on the host or does not parse; and an `env.copy` name that is unset **or
empty** in the environment claude-vm was launched from. **No diagnostic ever
prints a value** — each names the variable, the entry number or the file.

*The `.env` grammar* is the small portable one every `.env` convention agrees
on, because the file is the operator's and claude-vm only reads it: blank
lines and `#` comments are skipped, a leading `export` is dropped, everything
else must be `NAME=VALUE`, and a value wrapped in matching single or double
quotes is unwrapped. There is no variable expansion and no escape processing —
a `$` or a backslash means itself, and the `%q` on the way out makes what the
guest gets byte-identical to what the file held.

*Egress is a separate half.* Forwarding a key does not make the service
reachable: the guest is egress-confined, so the provider's host must also be
in `egress.allow` or the proxy blocks the call and the failure is baffling. A
variable **name** does not imply a hostname the way an apt source's URI does,
so there is nothing to derive and no `add_apt_uris_to_allowlist` analogue —
`env.copy` and `egress.allow` are documented as a pair in
`config-boot.example.yml` and in the skill docs instead.

*No new rebuild trigger.* The image identity is already a whole-file, raw-byte
hash of the two bake files, so changing a baked `env.set` value invalidates
the cached image and the next launch rebuilds. The boot launcher's new
source-and-export step is launcher logic, which the identity hash does **not**
cover, so `LAUNCHER_LOGIC_REV` carries it (24 → 25).

### A guard must survive the oldest bash that can reach it

Every script here is `#!/usr/bin/env bash`, so the interpreter is whatever
`bash` PATH resolves to — on a stock macOS with no Homebrew bash, `/bin/bash`,
still **3.2**. Parts of `lib/config.sh` need bash 4 (`local -A` in
`claude_vm_render_guest_settings`), but those run *late*, and they fail
**loudly**. The config-load guards run *early* and decide whether a mount is
safe, so a construct that behaves differently on 3.2 does not stop the
launch — it silently changes the answer a guard gives. A guard must not fail
open on the way to someone else's error, which makes "the whole file needs
bash 4 anyway" an unsafe justification for anything the guards depend on.

`test/config-test.sh` carries the same shebang and its header says to run it
directly, so the suite that checks the guards is under the same rule — at a
different cost, and say which of the two a given failure carries. A 3.2-only
construct in an assertion produces a false FAIL on code that is fine, which
costs a reader's trust; the same construct in a guard ships a hole.

The shapes this has actually bitten, with where each one bit:

- **A backslash-escaped delimiter in the replacement half of
  `${var//pattern/replacement}`.** Bash ≥ 4.3 unescapes `\/` to `/`; 3.2
  leaves the backslash in. Measured on both, `claude_vm_mount_guest_path`
  written inline as `${path//\/\//\/}` returns `/mnt/repo\` on 3.2 where 5.3
  returns `/mnt/repo` — the normalization is defeated, and with it every guard
  built on its output. The fix is to hold the literals in variables
  (`local sl=/ dbl=// dotseg=/./`), which expand with no escape to interpret,
  so both shells agree.
- **`"${arr[@]}"` on an empty array under `set -u`.** Bash 3.2 treats it as an
  unbound variable and kills the launcher, which is what the first iteration of
  any accumulate-and-compare loop hits. Write `${arr[@]+"${arr[@]}"}`.
- **A `case` inside `$( )`.** Bash 3.2 finds the end of a command substitution
  by counting parens, so a case pattern's `)` ends it early and the rest of the
  construct is left as literal text — the substitution returns a fragment of
  its own source instead of the branch's output. This one bit the **suite**
  rather than a guard: two `config-test.sh` assertions written as
  `"$(case "$p/" in "$share"/*) echo inside ;; *) echo outside ;; esac)"`
  classified correctly on 5.3 and returned that fragment on 3.2, so a harness
  artifact read as a broken wrap-dir siting. Lift the `case` into a function
  defined outside, so the substitution holds only the call.

`test/config-test.sh` pins the escaped-delimiter shape by *running* the real
normalizer under whatever pre-4 bash the host has, alongside a negative control
that runs the inline escaped spelling the function avoids — so if the hazard
ever disappears, the control stops differing and says so. On a host with no old
bash there is nothing to measure, and the block is skipped rather than faked
with a fixture. The `case`-in-`$( )` shape needs no assertion of its own — it
is a parse-time property of the file, so *running* the suite under `/bin/bash`
is the check: everything but the cases that need bash 4's `local -A` has to
pass there, and that failing set has to stay the one `main`'s own suite already
fails.

### Remote Control opt-in (`claude.remote_control`)

`claude.remote_control` is a layered boolean (default `false`/unset,
repo-over-global like the other scalars). When `true`, the launcher runs
the incoming CLI args through `claude_vm_augment_rc_args` to add
`--remote-control` and a date-stamped `--name` default (format like
`Jul10-14:30`). Passing `--remote-control` on the command line works
identically and is never duplicated. Any value other than `true`/`false`
(or unset) aborts the launch, matching `claude.renderer`'s strictness.

## Guest image (`build-guest-image.sh`)

```bash
build-guest-image.sh --print-version          # pinned version
build-guest-image.sh --output <image-path>    # build + stamp .version
```

The image is a version-pinned stable base (OS + a boot launcher, plus
whatever the bake files declare — apt packages/sources, and since
issue #107 the marketplaces and `claude.plugins.bake` refs).
The `claude` **binary** is never baked in; the boot launcher boots to the
**claude-fetch seam** and there runs the **host-verified `claude`
binary** mounted RO at `/mnt/claudebin` (see "Verified claude cache"
below) against the repo at `/mnt/repo` — as an interactive session on
the `hvc1` console (issue #88). The launcher builds the image on demand
when the configured image is missing or version-mismatched. No image
artifact is committed.

**Baked packages + whole-file image identity (issue #105, redesigned by #106,
re-redesigned by #179).** Unlike `claude`, a **bake** file's `packages:` (apt
packages) and `apt_sources:` (third-party apt repos) ARE baked into the image,
and so is the root partition's size (`image.root_headroom_mb`; see the
"Mid-session apt proxying, metadata diet, and root headroom" section below) and
its `env.set` map (issue #135 — rendered to `/etc/claude-vm/bake-env`, which the
boot launcher sources; see *Guest environment variables* above).
These keys live in the **bake** file precisely because they change image bytes;
everything in the **boot** file is applied at boot/run.

The image CONTENT is built from the merged config: the launcher passes the
merged canonical bake config via `CLAUDE_VM_BAKE_CONFIG`, the merged,
default-filled headroom via `CLAUDE_VM_ROOT_HEADROOM_MB`, the marketplace +
baked-plugin manifest via `CLAUDE_VM_BAKE_PLUGINS`, and the path to the
host-verified guest-platform `claude` binary the plugin bake step drives via
`CLAUDE_VM_GUEST_CLAUDE_BIN` (see "Marketplaces and plugins" below). The image IDENTITY
(cache key + filename) is a **whole-file, raw-byte hash of the BAKE files** —
no key-picking, no canonicalization. Placement of a key in the bake file IS the
classification, made once by the operator: a knob in the wrong file loudly does
nothing instead of silently poisoning the cache. Because the hash is over raw
bytes, list order, key order, whitespace, and even a **trailing-newline toggle**
all change it — the trailing-newline toggle is the documented force-rebuild
lever. The launcher passes the pre-computed identity to `build-guest-image.sh`
via `CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS`, appended verbatim to the base version:

- a repo **without** a `.claude-vm/config-bake.yml`
  → `BASE_OS_REV+launcherN+global<hash>`, image `guest+global<hash>.raw`,
  shared across every such repo (`<hash>` is the raw-byte hash of the global
  bake file; an absent global bake file hashes to the `00000000` sentinel);
- a repo **with** a `.claude-vm/config-bake.yml` →
  `BASE_OS_REV+launcherN+global<hash>+<reponame>-<repohash>`, image
  `guest+global<hash>+<reponame>-<repohash>.raw`, so the filename says whose
  override runs where.

The repo segment's PRESENCE is gated on the bake FILE existing (not its
content), so two repos with byte-identical repo-bake files still get two images
(the name disambiguates) — legibility over dedup, an explicit choice. Editing a
**boot** file never changes identity and never rebuilds; editing a **bake**
file (including only its trailing newline) does. An explicit `guest_image` opts
out of identity derivation and is used verbatim. An unset
`CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS` (a bare no-launcher `--print-version` smoke
test) leaves the bare base version.

**Immutable base image + per-run clone (issue #179).** The cached base `.raw`
is **immutable** and is NEVER attached to a VM. Each run APFS-clones it
(`cp -c`, an instant zero-copy copy-on-write clone) into the run dir and boots
the CLONE. N concurrent sessions cost one base image plus each session's own
written blocks — no cross-session/cross-repo state leakage (OAuth credential,
identity seed, transcripts, shell history, boot-installed packages), and no
multi-writer corruption from several guests reading-writing one shared ext4
image. The clone is discarded on a clean exit and RETAINED (path logged) on an
abnormal exit (nonzero vfkit status or a signal) for forensics. There is no
host-driven forced stop any more — the guest halts itself and vfkit exits on its
own — so `cleanup()`'s `sync` purely narrows the window in which writes in
flight to the clone are still unflushed when the guest goes away; with per-run
clones the blast radius of any torn write is one throwaway session's clone.

**Foreground vfkit, then an intact terminal (issue #179).** vfkit runs in the
**foreground** — no `&`, no PID capture, no reap machinery. Backgrounding it
breaks the boot outright (a backgrounded vfkit cannot attach its
`virtio-serial,stdio` console: `Error: operation not supported by device`), so
foreground is load-bearing, not stylistic. Its exit status lands in the
launcher's own `$?`, and because bash defers traps while a foreground child
runs, `cleanup()` can only ever run after vfkit has already exited — there is
never a live vfkit to stop or reap. For the session's duration the launcher
also disables `isig`/`ixon` on the host tty, so Ctrl-C (and Ctrl-Z/Ctrl-\\)
travel to the GUEST as bytes -- claude's own two-press Ctrl-C exit works --
instead of signalling host-side vfkit; a wedged guest is recovered with
`kill <vfkit pid>` from another terminal. `cleanup()` restores the host tty
first (the stdio bridge leaves it in raw mode, and that state survives
vfkit's death), then decides the clone's fate from `VM_EXIT_STATUS`. A
SIGKILL of the launcher runs no traps at all; the stranded vfkit/clone is
separate host-debris work, tracked on its own and out of scope here.

Provisioning the bootable raw image defaults to the bundled
`provisioners/podman-mkosi.sh` — mkosi run inside a throwaway rootless
podman container (Debian Trixie build container, systemd ≥ 254 for the
offline, loop-device-free `RepartOffline=yes` path), emitting a raw
EFI-bootable Debian guest with the boot launcher wired as the autologin
`serial-getty@hvc1` login program (so claude becomes the interactive
`hvc1` console session — issue #88) and an unlocked passwordless root
(`RootPassword=hashed:`). vfkit boots it with `--bootloader efi`.
Requires `podman` with a started podman machine. Override with
`CLAUDE_VM_IMAGE_PROVISIONER` set to a script taking
`<boot-launcher-path> <output-image-path>`. The provisioner renders
the bake `packages:` into a `mkosi.conf.d` `Packages=` drop-in and each
bake `apt_sources:` entry into an apt keyring + `sources.list.d` drop-in in
the mkosi **sandbox tree** (fetching each `key_url` inside the build container,
which has network), so mkosi's apt can install packages served by third-party
repos. That keyring-fetch + sources-write step is a reusable unit the
boot-time-install slice (issue #106) reuses against the guest's live
`/etc/apt`.

An `apt_sources` entry's `repo` is a raw apt one-line source string
and may already carry its own `[options]` block (e.g. an operator-authored
`deb [arch=arm64 signed-by=/etc/apt/keyrings/x.asc] ...`). The renderer
adapts to whatever shape the line already has rather than unconditionally
splicing in a second `[signed-by=...]` block (apt's one-line format allows
exactly one such block, and two make the line unparseable): no block at all
gets one added; a block with no `signed-by=` gets it merged in, other
options untouched; a block that already pins `signed-by=<path>` is left
byte-for-byte verbatim — that path wins, and the fetched key is written to
its staging equivalent instead of the default `<name>.asc`, so the declared
path and the actual key location never drift apart. This was a real-build
finding (issue #105 follow-up): unconditionally appending a second block
produced an apt "Malformed entry (URI parse)" failure. Bake `packages:`
entries that are null or empty (e.g. a stray `-` in the YAML list) are
stripped during canonicalization rather than passed through as a literal
`"None"` package name, which would otherwise fail the image build.

**Extra mounts, guest side (issue #157).** vfkit only *shares* a directory
under a virtio-fs tag; something inside the guest must still mount that tag
somewhere. The image's baked `/etc/fstab` knows only the built-in tags
(`repo`, `runconfig`, `claudebin`, `claudecreds`) and cannot know the
operator's, because `mounts` is a **boot** key: it must not change the image's
bytes, so it stays out of the image-identity hash and two configs differing
only in `mounts` share one cached image. So the mounting happens at boot, in
the boot launcher's `boot_mount_phase`, driven by a manifest the launcher
writes onto the `runconfig` share alongside `run.env` and the apt/plugin
manifests:

```text
mounts.tsv -- <tag><TAB><guest-path><TAB><file>
```

It rides a manifest file rather than `run.env` for the same reason
`apt-install.list` and `plugin-marketplaces.tsv` do — `run.env` is sourced
under `set -a` and carries scalars, while this is a variable-length list of
records whose fields are arbitrary operator-supplied strings. It is not a
secret and needs no umask tightening beyond `CONFIG_DIR`'s own.

The phase runs **first**, immediately after `run.env` is sourced and before
the credential/seed/settings install and the apt and plugin phases: an extra
mount depends on none of them, and going first means every later phase — and
claude itself — sees a fully-assembled filesystem. Its failure policy matches
`boot_apt_phase` and `boot_plugin_phase`: a failed mount logs a loud warning
naming the tag to the `hvc0` diagnostic log and continues to claude, because a
missing optional mount must never brick an interactive session. Every
*config-level* mistake was already rejected host-side by
`claude_vm_check_mounts` before the VM started, so what is left here is runtime
failure plus the one thing only this side can see. `mount`'s own stderr is
captured and re-logged rather than left to land on `hvc1`, the interactive
console.

*The occupancy check.* Linux **stacks** a mount: mounting over an occupied
path does not merge or fail, it hides what was there for the whole session —
and because this phase runs first, the damage always lands before the step that
would have noticed. The host rejects every guest OS path it knows of, but that
list is a denylist: the launcher cannot read the image's filesystem. The guest
can, so it looks before it mounts. A **directory** mountpoint that already
exists and is non-empty, one that exists and is not a directory, or a
**single-file** target that already exists at all, is warned about on `hvc0`
and **skipped**. Skipping loses a mount the operator asked for and says so
loudly; shadowing loses part of the OS and says nothing. `/root/.bashrc` is the
concrete single-file case — it ships in the image, and the launcher's own
post-mortem shell sources it — while `/root/.gitconfig`, the shape these docs
advertise, does not exist in the image and mounts normally. Emptiness is tested
with a pure-shell glob rather than `ls`, so the check cannot itself fail on a
missing binary at the one point in the boot where it must not.

*No read-only mounts.* Every extra mount is **read-write**, and neither the
config nor the manifest carries a mode. Writes go straight through to the host
path, live: no copy-back step, no review, no undo (`repo.copy_back` governs the
*repo* mount only and has nothing to do with these). That deliberately pierces
the VM isolation boundary for that one path, which is why
`config-boot.example.yml` says so at length. Read-only is not merely unset — it
is unenforceable here, and shipping it under the name `ro` would be a false
claim. Verified against **vfkit v0.6.4**: its virtio-fs device has no
read-only option and validates option keys strictly, so
`--device virtio-fs,…,readOnly=true` fails with
`Error: unknown option for virtio-fs devices: readOnly` (and `readonly`, and a
bare `ro`, fail the same way). The block-backed devices *do* carry the key —
`virtio-blk,…,readonly=true` fails on the **value**
(`unexpected value for virtio-blk 'readonly' option`), while an actually
unknown key on the same device gives the `unknown option` wording — so the gap
is specific to virtio-fs rather than a quirk of the parser. vfkit drives
Virtualization.framework directly, so there is no virtiofsd in between to hand
a read-only export to either. The host therefore exports every share
read-write, and the guest session runs as **root** (autologin getty,
`HOME=/root`), so a `-o ro` inside the guest is guest-side only and undoable
from inside the very session it would restrain. A config that still sets
`mode:` **aborts the launch** rather than having the key ignored: silently
accepting `mode: ro` would leave an operator believing a share is read-only
when it is not, which is the exact failure this removal exists to eliminate.
That abort is a **presence** test rather than a value one: `mode: ""` and a
valueless `mode:` render as the same empty field an *omitted* key does, so
`claude_vm_mount_mode_entries` asks yq `has("mode")` and emits only the entries
that carry the key. It is asked of the **merged** boot document, which costs it
one spelling: `mode: {}` is deleted by the prune's empty-map pass before the
gate sees it, and that config launches. See *Guest environment variables* above
for the measurement and for why every other presence gate asks the raw files.
It stays a separate emitter with its own loop in
`claude_vm_check_mounts` rather than another field on
`claude_vm_mount_specs`, so the whole deprecation gate is one function and one
loop to delete when the replacement lands — not a field every `mounts` reader
has to carry meanwhile.
Enforced read-only, at the hypervisor boundary (a read-only block device, so
guest root is irrelevant), is tracked as **issue #233**. Its config surface
need not be spelled `mode:`, and whatever it is spelled, every surface listed
in the root `CLAUDE.md`'s *no read-only mounts* sweep says today that no such
key exists.

*Where the `ro` on a built-in share comes from.* claude-vm's own shares —
`runconfig`, `claudebin`, `claudecreds` — are described throughout this
document and the scripts as read-only, and that is true of the **mount**, never
of the **share**. The paragraph above applies to them exactly as it does to an
extra mount: each is attached as a plain
`--device virtio-fs,sharedDir=…,mountTag=…`, the only shape vfkit accepts, so
the host exports all three read-write. The `ro` is supplied guest-side, by the
image's own `/etc/fstab` (`provisioners/podman-mkosi.sh`):

```text
claudecreds   /mnt/claudecreds   virtiofs   ro,nofail     0 0
```

It therefore carries the same limit as any guest-side `ro`: it stops an
accidental write, not a determined one, because the guest session is root and
can remount. Nothing in the boot rests on it, because nothing in the boot writes
to any of the three: the launcher **copies** each file it needs out of
`claudecreds` before use (`.credentials.json` and `settings.json` into
`$HOME/.claude/`, the identity seed to `$HOME/.claude.json`, each `chmod 600`
after the copy), **sources** the boot-tier `env` file in place (see *Guest
environment variables* above — it is deliberately never copied, so a forwarded
API key does not outlive the shredded mount), reads the `runconfig` manifests
in place, and execs the `claudebin` binary off the share. Say "shared into
the guest, where the image's fstab mounts it `ro`" rather than "shared
read-only into the guest"; the latter
puts the guarantee on the side of the seam that cannot make it.

*Single-file sources.* virtio-fs shares directories only, so a file source is
**wrapped**: the launcher makes a per-entry directory, puts the file in it,
shares *that*, and the guest mounts the wrap at a hidden
`/run/claude-vm/mount-wrap/<tag>` and then bind-mounts the one named file onto
the target path — so nothing else from the file's real parent directory is
exposed. The wrap entry is a **hard link, not a copy**: a copy would make the
write-through a lie, since guest writes would land in the throwaway wrap dir
and never reach the host file, whereas a hard link is the same inode and a
single-file mount writes through to the host file live. `ln` fails across
filesystems, and that is a hard abort naming the fix (move the file onto the
wrap directory's filesystem, or mount its containing directory) rather than a
silent downgrade to copy semantics.

*Where the wrap directory lives.* Because the wrap entry is the same inode as
the operator's file, anything that can reach **inside** the wrap directory can
read and write that file — so the wrap directory has to sit outside the
directories claude-vm itself hands the guest, and `$RUN`
only sometimes does. Under `repo.mount: clone` the repo share is
`$RUN/worktree` and the wrap
dir is its sibling, invisible to the guest. Under `repo.mount: live` the share
is the repo itself, `$RUN` is `<repo>/.claude/tmp/<run-id>` *inside* it, and
the guest's fstab mounts tag `repo` **rw** — so a wrap dir under `$RUN` would
be reachable and writable from the guest at
`/mnt/repo/.claude/tmp/<run-id>/mount-wrap/<tag>/`: the operator's file exposed
at a second guest path they never configured, and one that survives the entry's
own mountpoint being skipped by the occupancy check above. The launcher
therefore tests `$RUN` against the *actual* repo share —
not against `repo.mount`, so the test survives a change of mount strategy —
and falls back to a per-run directory under `$TMPDIR`, which none of the
shares claude-vm builds for itself (the repo share, `$RUN/config`,
`$RUN/creds`, the verified-binary cache under `~/.config/claude-vm`)
contains. That fallback is not covered by the run-dir retention, so
`cleanup()` removes it, dropping hard links and never the operator's file. In
the `$RUN` case the wrap dir is retained along with the rest of the run dir,
which means a link to a host file living *outside* the repo persists under
`<repo>/.claude/tmp/<run-id>/` until that run dir is removed: no bytes are
duplicated (a hard link is a name, not a copy), but the file's data does
survive deletion of the original.

*What a single-file mount cannot do.* A file bind mount cannot be
replaced by `rename(2)` — the kernel returns `EBUSY` — so the
write-a-temp-file-then-rename pattern fails on a single-file mount while
working fine on a directory mount, which is where the single-file and
directory shapes genuinely differ. In-place writes reach the host file as
documented.

Probed in a privileged Linux container against this exact shape — one file
bound out of a wrap mount — with the real tools rather than by reasoning about
`rename(2)`. Real `git config` fails with
`error: could not write config file …: Resource busy`, leaving the source
unchanged; GNU `sed -i` fails with `sed: cannot rename …: Device or resource
busy`; and both succeed, reaching the host file, when the same edit goes
through a directory mount. Most editors write the same way. The failure is
loud rather than silently corrupting, but `~/.gitconfig` — the single-file
example these docs advertise — is exactly the file a rename-over writer
targets, so mount the containing **directory** when the guest needs to
*replace* the file rather than edit it in place.

**Boot-time package install/update (issue #106).** Unlike the bake file's
`packages:`, the boot file's `packages:` and `update_at_boot` run **inside the
guest at boot**, blocking, right before claude launches — not baked into the
image. This requires `apt` itself to be present in the guest, which mkosi
does NOT provide for free: mkosi installs packages from OUTSIDE the image
with its own (build-container) apt, so nothing else ever pulls apt/dpkg
tooling into the guest rootfs. `apt` is therefore baked into the base
`Packages=` list (`provisioners/podman-mkosi.sh`) **unconditionally** — not
gated on whether boot-time apt work is configured — because
`update_at_boot` defaults to true (so nearly every config needs it) and the
`always` mid-session-install mode below is only honest if apt exists to use.
The security boundary for a hard-secure all-baked config is the egress
allowlist (package mirrors left unreachable), not the absence of the apt
binary. The boot launcher (`build-guest-image.sh`'s `boot_apt_phase`) runs, in
order: (1) when `update_at_boot` is true (the default),
`apt-get update` + `apt-get -y upgrade`; (2) when the boot `packages:` list
is nonempty, render any boot-tier `apt_sources:` entries into the guest's
**live** `/etc/apt` — reusing the exact same keyring-fetch + sources.list.d-
write shape as the build-time `render_apt_source` (case-matrix, name/path
validation, and all), ported to plain bash since the guest image carries no
python3/jq to parse a manifest — then `apt-get -y install <list>`. Both
`apt-get` calls proxy through `Acquire::http::Proxy` / `Acquire::https::Proxy`
pointed at the same `HTTP_PROXY`/`HTTPS_PROXY` `run.env` already carries. A
failed update/install prints a loud warning to the `hvc0` diagnostic log and
**continues** to claude — a failed optional install must never brick an
interactive session (per the issue's agreed failure policy). The host
delivers the manifest (the boot `packages:` names, and the boot-tier
`apt_sources` TSV) as plain newline/TSV files on the same
`runconfig` virtio-fs share `run.env` already rides, for the same "no
python3/jq in the guest" reason.

`add_apt_uris_to_allowlist` (`auto`, the default, or `always`)
controls whether the launcher adds `deb.debian.org` + `security.debian.org` +
every apt_sources host (bake and boot tiers) to the guest's egress allowlist. `auto`
adds them **iff** boot-time apt work is actually configured
(boot `packages:` nonempty, or `update_at_boot` true); with no boot-time
work configured, `auto` derives nothing — a hard-secure all-baked config
leaves package repos genuinely unreachable from the guest. `always` keeps
the URIs allowlisted regardless, so an in-guest `apt-get install` still
works mid-session even with boot-time apt work turned off. The launcher
never removes a URI that scheduled boot-time work requires (so `auto` and
`always` never conflict), and logs every derived addition — no silent
allowlist growth. This derivation runs in `claude-vm.sh`, after the
warm-boot `claude.ai`/`downloads.claude.ai` tightening (issue #49) so a
dropped entry from that step is never re-added here.

**Marketplaces and plugins (issue #107).** Plugins follow the same bake /
install-at-boot split as packages, with explicit boot-time updating instead of
relying on marketplace autoUpdate. The guest's plugin set comes from the
claude-vm configs **only** — never the host's `settings.json` or the host's own
installed plugins — because inside the VM one may deliberately run a plugin or
hook that is not enabled on the host.

*Placement.* `claude.plugins.bake` lives in the **bake** file and
`claude.plugins.install_at_boot` / `.update_at_boot` /
`.add_marketplace_uris_to_allowlist` / `.enabled` in the **boot** file;
`claude.marketplaces` is allowed in both and unions, deduped by `name` (a name
with two different urls aborts the launch, like `apt_sources`). Baked plugins
change the image's bytes, so putting them in a bake file is what places them
under the whole-file image-identity hash — issue #107's "extend the bake-hash
with marketplace/plugin refs" achieved by placement rather than by a new
key-picked hash. Because `claude.plugins` is the one map that legitimately
appears in both file types, `claude_vm_check_plugin_key_placement` turns a
misplaced sub-key into a loud abort instead of a silent no-op. It is a
**presence** test asked of the four raw config files, not a value test asked of
the merged documents, so a misplaced key written in any empty spelling aborts
too — see *Guest environment variables* → the presence-gate paragraphs for the
prune routes that made the value test wrong.

*Bake path.* The provisioner runs the host-verified **guest-platform**
(`linux-arm64`) `claude` binary inside the Trixie build container with
`HOME=/root` and drives its own CLI: `claude plugin marketplace add <url>` for
every configured marketplace, then `claude plugin install <ref>` for every
`claude.plugins.bake` ref. The registry format is claude's and is never
hand-written. `HOME=/root` is what makes the recorded absolute paths correct —
the container runs as root, so its `/root` **is** the guest's future `/root`,
and `known_marketplaces.json` / `installed_plugins.json` record
`/root/.claude/plugins/...` verbatim with no rewriting. Only
`/root/.claude/plugins` is copied into the image (via `mkosi.extra`, moved with
a `tar` pipe rather than `cp -a`, since the macOS bind mount cannot hold
`security.*` xattrs); the `settings.json` and `.claude.json` the CLI also
writes are deliberately left behind, because both are host-rendered per run.
Unlike the guest's boot phase, a failed add/install **fails the build** — a
silently plugin-less image would be cached under a version stamp claiming it
has them. The launcher therefore resolves the verified binary **before** the
image build (an ordering change from #49's original sequence), which also means
a signature/checksum failure now aborts before a multi-minute build.

*Bake-declared vs. boot-declared marketplaces (issue #226).* That
fail-the-build policy is scoped to what the image must **carry**: every
`claude.plugins.bake` ref, and every marketplace declared in a bake file. A
marketplace declared only in a **boot** file is pre-registered here purely as
an optimization — it saves the guest one network add — and its url only has to
be reachable from the **guest**. A guest-local path (`/mnt/repo`), a private
source needing host-only credentials, or an https host outside the build
container's egress is legal and simply cannot be added at build time, so the
build logs its reason and continues. A boot-declared entry is skipped rather
than fatal on each of the paths that abort a bake-declared one: it carries no
`url` at all, the `claude plugin marketplace add` fails, or the add succeeds
but registers under a name that does not match the configured one. Each path
logs its own message against the entry it happened to, and
`boot_plugin_phase` adds the marketplace at boot, which it already does for
any marketplace the image does not carry. The provisioner tells the two apart
by the `origin` field `claude_vm_bake_plugins_json` stamps on each manifest
entry, defaulting to the strict `bake` reading when the field is absent. When
*nothing* lands — no `bake:` refs and every boot-declared add skipped — the
build ships no baked plugin tree instead of failing the "expected
/root/.claude/plugins" check, and its summary line points back at the
per-entry messages rather than naming one cause.

*Boot path.* `build-guest-image.sh`'s `boot_plugin_phase` runs after the
claude-fetch seam (it needs the verified binary) and before claude launches,
blocking, in this order: (1) add any configured marketplace the image does not
already carry; (2) when `update_at_boot` is true (the default),
`claude plugin marketplace update`; (3) `claude plugin install` each
`install_at_boot` ref; (4) when `update_at_boot` is true,
`claude plugin update` each ref reported by `claude plugin list`. Step (4) is
the **freshness mechanism for baked plugins**: they are frozen at image-build
time and the image-identity hash deliberately excludes marketplace HEAD, so
without it a marketplace bump would need a rebuild. Failure policy matches
`boot_apt_phase` — a loud warning on the `hvc0` diagnostic log, then continue to
claude. The host delivers `plugin-marketplaces.tsv` + `plugin-install.list` on
the same `runconfig` share as the apt manifest, for the same "no python3/jq in
the guest" reason.

The guest bakes **`git`** unconditionally for this phase, alongside `apt`
(`Packages=` in `provisioners/podman-mkosi.sh`). The claude CLI does not bundle
a git implementation — it *shells out to system git* for every git-url
marketplace operation — so without it every `claude plugin marketplace
add|update` fails with `Failed to clone marketplace repository: Command failed
with ERR_STREAM_PREMATURE_CLOSE: git … clone --depth 1 …`, which (fail-soft)
would leave `update_at_boot` permanently inert and any boot-added marketplace
unreachable. Nothing else pulls git into the guest rootfs: mkosi installs
packages from *outside* the image with the build container's own tooling.

*Derived egress.* `add_marketplace_uris_to_allowlist` (`auto` default |
`always`) mirrors `add_apt_uris_to_allowlist`. Under `auto` the marketplace
hosts are added **iff** boot-side work will actually run: a nonempty
`install_at_boot`, a marketplace declared in a boot file whose name is not
also bake-declared, or `update_at_boot` true with at least one marketplace
configured. That middle test reads the *declaration*, not the image: since
issue #226 the build only *tries* to pre-register a boot-declared
marketplace and the host cannot know whether it succeeded, so the gate
derives the host either way.
Everything bake-declared + `update_at_boot: false` + `auto` therefore derives
**nothing** — and the guest still has working plugins, because the baked ones
need no marketplace at all. Every derived addition is logged. A marketplace
whose `url` is an `owner/repo` GitHub shorthand yields no derivable host; the
launcher says so rather than guessing `github.com`.

*Why the boot path does not collapse into the settings render.* Issue #107 left
open whether rendering `extraKnownMarketplaces` + `enabledPlugins` (issue #104)
would make claude self-install missing plugins at first launch. Tested
directly: a home dir carrying only that `settings.json`, with no
`~/.claude/plugins` tree, left `claude plugin marketplace list` reporting "No
marketplaces configured" and installed nothing. So the explicit
ensure/install/update phase is load-bearing. The render **does** now emit
`extraKnownMarketplaces` — `claude plugin install` was observed writing that
key into `~/.claude/settings.json` itself, and the boot launcher copies the
host-rendered file over whatever the image baked, so omitting it would drop the
declarations the bake step's own CLI run wrote.

*Compiled hooks need no toolchain.* The guardrails permission-gate ships
**prebuilt, committed** binaries, one per `<goos>-<goarch>`, and its
`hooks.json` picks the matching one by `uname`. Listing `guardrails@…` in a
plugin list therefore requires **nothing** in the bake file's `packages:` — in
particular no `golang`. (Earlier revisions of this file and of
`config-bake.example.yml` claimed a load-time `go build` and a
guardrails↔`golang` pairing; that was never true, and issue #216 corrected
it.) The guest is `linux-arm64` and the plugin commits a `linux-arm64`
binary. Should a platform ever lack a committed binary, the hook now fails
**closed** — a one-line stderr message naming the missing path and exit 2,
hard-denying the tool call — instead of the pre-#216 behavior, where the
missing binary produced a non-blocking `PreToolUse hook error` and every gated
tool ran completely unadjudicated.

**Mid-session apt proxying, metadata diet, and root headroom (issue #106
real-run fixes).** Real-hardware testing of the boot-time apt work above
found further problems. First, an **interactive** `apt-get install` (run
by the in-guest claude mid-session, not by `boot_apt_phase`) got no proxy at
all: apt honors only lowercase `http_proxy`/`https_proxy` (never the
uppercase forms `run.env` used to carry alone), and curl deliberately
ignores uppercase `HTTP_PROXY` for plain `http://` URLs (the well-known
"httpoxy" CGI-variable carve-out). `run.env` now also exports lowercase
`http_proxy`/`https_proxy`/`no_proxy` mirrors, and the boot launcher writes
a persistent `/etc/apt/apt.conf.d/99claude-vm-proxy` from those values (in
addition to the `-o Acquire::...::Proxy=` flags `boot_apt_phase` already
passed explicitly) so every apt-get for the rest of the boot — boot-time or
later interactive — is proxied regardless of environment. Direct egress
stays blocked by gvproxy and the proxy still enforces the allowlist, so this
widens nothing; reachability is still governed solely by the allowlist.

Second, `boot_apt_phase`'s `apt-get update` was re-materializing ~250 MB of
apt working set on **every** boot (`update_at_boot` defaults to true):
mkosi's own Debian installer defaults to `deb`+`deb-src` sources for FOUR
repo stanzas (main, `debian-debug`, updates, security) plus a persistent
`pkgcache.bin`/`srcpkgcache.bin` regenerated by every apt-get call — none of
which this recipe needs (pre-built binary packages only, no debug symbols).
The provisioner now pre-empts mkosi's own sources write with a binary-only,
no-debug `mkosi.skeleton/etc/apt/sources.list.d/<suite>.sources` (main +
updates + security only) and an `Acquire::Languages "none"` /
`Dir::Cache::pkgcache ""` / `Dir::Cache::srcpkgcache ""` apt.conf.d drop-in,
baked into the image from before mkosi's own package install step runs.
`boot_apt_phase` also now ends with a defensive `apt-get clean` (verified:
removes `/var/cache/apt/archives/*.deb` and both `.bin` cache files; leaves
`/var/lib/apt/lists` untouched). Net effect: the per-boot apt working set
drops from ~250 MB to ~50 MB.

Third, even after that diet, the root filesystem was **tight-fit sized** with
near-zero margin for anything the guest writes after boot. mkosi's own default
repart definitions size the root via `Minimize=guess` (systemd-repart's
tight-fit-to-content sizing). A new `image.root_headroom_mb` config scalar
(default `1024`, repo overrides global) sizes the root filesystem to
`ROOT_BASE_FLOOR_MB + headroom` (900 MiB fixed floor + the headroom) via a
custom `mkosi.repart/10-root.conf`.

The first round of this feature kept `Minimize=guess` **alongside**
`SizeMinBytes=`, on the theory `repart.d(5)` composes them as "the larger
wins". A real build proved that **backwards**, because the two knobs act on
different objects: `Minimize=guess` sizes the **ext4 filesystem** to a tight
fit (~1041 MiB), while `SizeMinBytes=` only enlarges the **GPT partition
slot** (to 1924 MiB) around it — so ~883 MiB was unformatted dead space past
the end of the filesystem, which the guest's `df` never saw (the root stayed
~991 MB, headroom inert). The fix **drops `Minimize=guess`**: with only
`SizeMinBytes=` and `Format=ext4`+`CopyFiles=/`, systemd-repart sizes the ext4
filesystem to FILL `SizeMinBytes`, so the free space above the content is real,
guest-usable headroom (a fresh real build confirmed fs == partition == 1924
MiB, ~1270 MiB free). `ROOT_BASE_FLOOR_MB` is an honest fixed floor (not a
per-build measurement — mkosi's measured minimal is only printed mid-build,
after the static `mkosi.repart/` files are already written), chosen at/above
the ~723 MiB of real baked content so `floor + headroom` guarantees at least
`headroom` of free space.

Providing a custom `mkosi.repart/` also requires a verbatim copy of mkosi's
own default ESP definition (`00-esp.conf`) alongside it: once `mkosi.repart/`
exists at all, mkosi does not layer its defaults on top — the directory must
be a complete partition table, not an addendum. The resolved headroom is a
BUILD input (`CLAUDE_VM_ROOT_HEADROOM_MB`, forwarded to the provisioner as the
partition size); it also participates in the image cache key via the
per-layer image-identity hash (`image.root_headroom_mb` is build-relevant), so
a headroom change forces a rebuild and two configs with different headroom
never share a cached image.

The launcher attaches **two** virtio-serial consoles (issue #88). The
first (`logFilePath`, guest `hvc0`) captures the booting guest's
kernel/systemd output to `$RUN/guest-console.log`, making an otherwise
black-box boot observable from the host: the recipe's `KernelCommandLine`
sets `console=hvc0`, and the boot launcher writes its `claude-vm:`
diagnostic/seam lines explicitly to `/dev/console`, so they land in this
log. The second (`stdio`, guest `hvc1`) bridges the launching terminal —
the interactive claude session. Boot diagnostics stay on `hvc0`, off the
interactive terminal. The capture path is reported on exit and retained
in the run dir alongside `egress.pcap`.

Because the `hvc1` console is a byte pipe that needs a real controlling
TTY on the host, launch `claude-vm` from a real terminal (not a pipe).
The console carries no live window-resize channel, so the launcher seeds
the guest tty geometry once from the host's `stty size` at launch.

## Forward proxy (`proxy/tinyproxy-launch.sh`)

The default `proxy.cmd`. When `proxy.cmd` is unset in both config layers,
the launcher runs this script. It reads the egress allowlist from
`$CLAUDE_VM_EGRESS_ALLOWLIST`, renders a `tinyproxy.conf` whose
`FilterDefaultDeny`/`Filter` directives confine outbound connections to
exactly the allowlisted hosts (fail-closed: an empty allowlist permits
nothing), binds `$CLAUDE_VM_PROXY_PORT`, and execs `tinyproxy`. Requires
`tinyproxy`. Override by setting `proxy.cmd` to your own forward-proxy
command (which must still read `$CLAUDE_VM_EGRESS_ALLOWLIST`).

## Verified claude cache (`lib/claude-cache.sh`)

The `claude` binary the guest runs is fetched, verified, and cached
**host-side**, then shared into the guest and mounted `ro` there by the
image's fstab (see *Where the `ro` on a built-in share comes from* above) —
the guest never runs
`curl https://claude.ai/install.sh | bash` on the trusted path. Driven
by the `claude.version` scalar (`stable` | `latest` | a pinned version
like `2.1.172`):

1. resolve the channel/pin to a concrete version host-side (cache key =
   resolved version);
2. download that version's `manifest.json` + `manifest.json.sig`;
3. **`gpg --verify`** the signature **and bind it to the pinned
   claude-code key fingerprint** (`claude.signing_key_fingerprint`) — **the
   root of trust**. A bare `gpg --verify` exits 0 for a valid signature
   under *any* key in the operator's keyring, so the verify step reads
   gpg's `--status-fd` stream and requires a `VALIDSIG` whose fingerprint
   matches the configured pin; a valid signature by an unexpected key is
   rejected;
4. read the `linux-arm64` SHA256 from the signature-verified manifest;
5. download the binary; verify its SHA256 against the manifest;
6. cache the verified binary under
   `~/.config/claude-vm/cache/<version>/linux-arm64/claude` and share it
   into the guest (`mountTag=claudebin`), where the image's fstab mounts it
   `ro`.

Since issue #107 this whole block runs **before** the on-demand image build,
not after it: the build's plugin bake step drives this same guest-platform
binary inside the build container (`CLAUDE_VM_GUEST_CLAUDE_BIN`), so it must
already exist when the build starts. A signature or checksum failure therefore
aborts before a multi-minute build, and bake-time and boot-time plugin work can
never be done by two different `claude` versions.

**Security invariant:** a failed `gpg --verify`, a checksum mismatch, **or
an unpinned signing key** (`claude.signing_key_fingerprint` unset) each
**aborts the launch** before any unverified binary is cached or run — there
is no "verify failed, proceed anyway" branch and no "no pin, trust any key"
branch, and **no `install.sh | bash` fallback anywhere**. Trusting
`install.sh`'s own checksum would be circular (the script is itself
unsigned and re-fetched each boot), so the signed manifest is the root of
trust — and it is the *only* trust path. There is no lower-trust escape
hatch: an unpinned/unimported signing key or any verification failure
aborts the launch, it does not downgrade to an unverified install.

**Operator one-time setup** (trust-on-first-use, **required**): import the
signing key, read its fingerprint, **verify that fingerprint out of band**,
then **pin it** in your config so the verify step is bound to *that* key
(not merely to "some key in your keyring"). This is a **mandatory** step —
the verified cache hard-aborts when no fingerprint is pinned (see below) —

```bash
curl -fsSL https://downloads.claude.ai/keys/claude-code.asc | gpg --import
gpg --fingerprint claude-code   # confirm this matches the published value
```

Then set the fingerprint in `~/.config/claude-vm/config-boot.yml` (or
the per-repo boot override) — `claude.*` are run-time keys, so they
live in the **boot** file:

```yaml
claude:
  version: stable
  signing_key_fingerprint: "AAAA BBBB CCCC DDDD EEEE  FFFF 0000 1111 2222 3333"
```

The value is compared case-insensitively with spaces stripped, so the
`gpg --fingerprint` form can be pasted verbatim. If
`signing_key_fingerprint` is **unset**, the verified cache **hard-aborts**
the launch before fetching, caching, or running anything — a valid
signature by an unpinned key is *not* accepted, because the whole point of
a GPG-verified root of trust is that "some key signed it" is not good
enough. Pinning the fingerprint is therefore a **required** one-time step
for the verified cache to function — there is no lower-trust fallback to
fall back to; an unpinned key aborts the launch.

**Warm boot:** when the resolved version is already cached, the binary is
not re-downloaded and `gpg` is not re-run, and the launcher drops
`claude.ai` / `downloads.claude.ai` from the guest's egress allowlist
(the guest never needs them — the binary came from the host-side cache).
Requires `gpg` (`brew install gnupg`) and a sha256 tool (`shasum` /
`sha256sum`, both stock on macOS/Linux).

**Trust-path preflight (fail fast):** before any image build, network
call, or Keychain read, the launcher checks the local, instant
preconditions for the verified cache and credential selection up front:

- `gpg` is on PATH;
- a `claude.signing_key_fingerprint` is pinned in config;
- that pinned fingerprint is actually present in the gpg keyring;
- `python3` is on PATH (used to select the `claudeAiOauth` credential —
  see "Authentication" above).

Each failed check prints the exact remediation command(s) (`brew install
gnupg`, the `curl … | gpg --import` + `gpg --fingerprint` pin steps,
`xcode-select --install` for `python3`) rather than a bare error.
Without this gate, a cold boot would otherwise pay for the network
fetches (channel pointer + manifest + signature) and a guest-image build
before aborting on a condition knowable at startup. The deep checks in
this library (gpg-on-PATH at the verify step, the unset-pin hard-abort)
and in `lib/credential.sh` (`python3` at the selection step) remain as
defense-in-depth — the preflight is an additive early gate, not a
replacement.

## Tests

```bash
"${CLAUDE_PLUGIN_ROOT}/payload/test/config-test.sh"
"${CLAUDE_PLUGIN_ROOT}/payload/test/endpoint-test.sh"
"${CLAUDE_PLUGIN_ROOT}/payload/test/boot-launcher-test.sh"
"${CLAUDE_PLUGIN_ROOT}/payload/test/bin-config-check-test.sh"
"${CLAUDE_PLUGIN_ROOT}/payload/test/claude-cache-test.sh"
"${CLAUDE_PLUGIN_ROOT}/payload/test/podman-mkosi-test.sh"
"${CLAUDE_PLUGIN_ROOT}/payload/test/host-acceptance.sh"
```

`config-test.sh` exercises the config layering (scalar override, list
union, single-layer and no-layer fallbacks, de-duplication) with no VM
and no network, plus the pure helpers built on it — the settings render,
the bake/identity hashing, and (issue #107) the marketplace/plugin
helpers: effective-set dedup, the placement and name-conflict aborts,
derived-egress `auto` semantics, and the bake-plugin manifest. Issue #226
added cases that leave pure-helper territory, each *run* against records from
the real emitter rather than grepped for out of the source: `boot_apt_phase`
and `boot_plugin_phase` (sliced out of `build-guest-image.sh`, the former with
`render_apt_source_boot` swapped for a recorder), the launcher's extra-mount
loop, and the launcher's whole config-load gate block (both sliced out of
`claude-vm.sh` by line range, since they are bare top-level code rather than
functions). Together they assert that a record's empty middle field survives
the split, that an empty *leading* field does too, and that a mounts or
`claude.marketplaces` entry missing its key field aborts the launch with a
message naming it — see *Splitting a TSV record back apart* above. The split
cases each carry a negative control that rebuilds the pre-fix collapsing
`read` from the same captured lines, so the control cannot drift away from
the code it contrasts with.

Issue #157 extended the surfaces the `mounts` feature already had — the
launcher's extra-mount loop and its config-load gate block — and added a
slice of its own, the guest's `boot_mount_phase`. The extra-mount loop is now
also run for the manifest it writes (a directory entry defaulting to
`/mnt/<tag>`, a `path:` override, a
single-file entry naming its basename) and for the wrap directory it builds —
including that the wrap entry is a **hard link** to the source, asserted by
comparing inode numbers rather than content, since a copy would match on
content and silently break write-through, and that a comma in the wrap
directory's own parent aborts the launch, blaming `$TMPDIR` in the `live`
shape and the run dir in the other while a directory-only config under that
same `$TMPDIR` is left alone (the guard's scope, since it sits at the point of
use), against a negative
control that drops the guard's lines from the same captured loop and shows the
malformed `sharedDir=` it would otherwise emit. The config-load gate block is
run once per rejected config, each asserting both the non-zero exit and a
diagnostic naming the actual problem: a reserved tag, a duplicate tag, a
`mode:` key (spelled `ro`, `rw`, a typo, an explicit `""`, and a valueless
`mode:`, since only a *presence* test tells the last two from an omitted key —
`mode: {}` has no case, and is the one spelling the merged-document read drops,
per *Guest environment variables*), a missing host source, a relative `path`,
a `path` with a `..` segment, a `path` over a reserved mountpoint (spelled
with a trailing slash, so the normalization is what catches it), a duplicate
guest path, and a tag carrying a comma. The guest-OS-path rule is driven from
both sides at once: a **directory** on `/root`, on `/etc`, and inside `/usr`,
`/root` and `/var` all abort, while a **single file** inside `/root` and `/tmp`
passes and the same in-`/root` path with a *directory* source aborts — one pair
of assertions differing only in what the source is, which is the whole
directory-versus-file distinction. The passing side is pinned too: the default
`/mnt/<tag>`, `/srv/custom`, `/opt/tools` and the component-boundary near-miss
`/etcetera`.

And `boot_mount_phase` is sliced out of `build-guest-image.sh` — from
`boot_dir_is_nonempty` through the end of the phase, since a slice that took
only the phase would leave the occupancy helper undefined and every occupancy
assertion would pass while testing nothing — and run with `mount` replaced by a
shell function recording its argv. So the assertions are about *which* mount
calls the phase makes, with which options, in what order: `-o rw` reaching
`mount(8)`, a `path:` override used verbatim, a single-file entry mounting its
wrap share first and then binding exactly the one named file, a failing mount
still returning 0, and the same empty-middle-field split with its own negative
control. The occupancy decisions are real filesystem observations and are
settled here rather than deferred: an occupied directory mountpoint, a
mountpoint holding only a dotfile, and an existing single-file target each
produce **no** mount call and a warning, while an *empty* existing mountpoint
still mounts — without that last one the check could have been "skip whenever
the path exists", which would break the default `/mnt/<tag>` on any image that
ships those directories. What these cases deliberately cannot assert is that a
guest write reaches the host — that needs a real guest.

Requires `yq` (mikefarah v4+); skips cleanly when absent.

`endpoint-test.sh` exercises the per-run endpoint primitives in
`lib/endpoint.sh` (issue #179): kernel-assigned free-TCP-port acquisition,
TCP-port liveness, and — the core of the concurrency defect — unix-socket
liveness that distinguishes a LIVE listener from a stale socket-file corpse
(the old readiness check tested mere file existence, so a corpse passed it),
plus the stale-corpse clearing that refuses to stomp a live sibling's socket.
Stands up genuine `perl` TCP and unix listeners so the checks run against real
live/dead endpoints; host-gated on `/usr/bin/perl`. (There are no vfkit
REST-shutdown helpers or tests: the guest powers itself off — see
`boot-launcher-test.sh` — so the host drives no shutdown.)

`boot-launcher-test.sh` is the regression test for issue #179's guest-side
self-poweroff model, which replaced the earlier host-driven vfkit-REST
shutdown. It extracts the boot launcher `build-guest-image.sh` emits, slices
out the real exit-status decision fragment (`"$CLAUDE_BIN" "$@"` →
capture-status → branch), and runs THAT fragment against a stubbed
claude/kill/bash: a claude exit 0 (a deliberate quit) powers the guest off by
sending SIGRTMIN+4 to PID 1 — systemd's documented bus-less route to the same
ordered `poweroff.target` shutdown as `systemctl poweroff`, chosen because the
guest ships no dbus and systemctl's logind attempt printed
`Failed to connect to bus` on the operator's console on every clean exit —
while a nonzero exit (137/SIGKILL, or any nonzero) runs an interactive root
**login shell** on hvc1 as a CHILD so the failed session is inspectable, and
powers the guest off only when that shell exits (an exec'd shell left the
guest alive with a dead console once the operator logged out -- the sequence
shell-then-poweroff is asserted in order). The loop-sensitive assertions live
here too: the
abnormal handoff must be a plain login shell and must never re-enter the boot
launcher (which would rerun claude and rebuild the respawn loop this redesign
removed). It also asserts the getty drop-in the provisioner writes neutralizes
the respawn via `Restart=no` — the other half of the clean-poweroff contract,
since an unconditional respawn would race the guest's own poweroff. Note the
mechanism: the respawn comes from `Restart=` in the stock
`serial-getty@.service` template (`Restart=always`), which the drop-in overrides
to `no`; the leading `-` on `ExecStart` is dropped as well, but that prefix only
makes a nonzero exit be *reported* as success and never governed the respawn (it
is asserted separately, and a `failed` getty unit is inert here because nothing
sets `OnFailure=`/`FailureAction=`). Finally it pins `LAUNCHER_LOGIC_REV` past
16, since the image-identity hash covers only the bake config files plus the
repo name — never the launcher source — so that constant is the only thing that
invalidates a cached image when launcher logic changes. No VM, no network, no
root; needs only `bash` + `awk`.

`launch-shape-test.sh` is the regression test for issue #179's vfkit launch
shape. A backgrounded vfkit (`vfkit … &` + `wait $!`) cannot attach its
`virtio-serial,stdio` console to the terminal — a real boot fails with
`Error: operation not supported by device` at "Adding stdio console" — and
that shape shipped once and never booted. The test asserts, at the source
level (like the getty drop-in assertions): the vfkit invocation carries no
trailing `&`; `VM_EXIT_STATUS=$?` immediately follows it; no `VFKIT_PID`,
`reap_vfkit`, or `REAP_` machinery exists anywhere in the launcher; and
`VM_EXIT_STATUS` is initialized to `1` so an interrupted path fails safe to
*retain*. No VM, no network, no root; `bash` + `awk`.

`bin-config-check-test.sh` is the regression test for issue #179 real-boot
defect #3: `bin/claude-vm`'s global-config presence check must know the
four-file bake/boot schema, so it no longer prints a false "no global config
found" when the migrated `config-bake.yml`/`config-boot.yml` pair is present,
and routes a genuine leftover single-file `config.yml` (global OR repo tier)
into a migration pointer instead. Drives the real `bin/claude-vm` up to — but
not through — the launcher exec (a stubbed `security` makes the Keychain check
exit first), asserting on the step-4 stderr for each config state. Host-gated
on `git`.

`claude-cache-test.sh` exercises the verified claude cache
(`lib/claude-cache.sh`): channel/pin validation, version-keyed cache-path
derivation, manifest-checksum extraction and comparison, the cold-fetch
happy path, the warm-boot no-network path, and — the security-critical
assertions — that a failed `gpg --verify`, a checksum mismatch, **and an
unset signing-key pin** each abort and cache nothing. The unset-pin abort
is asserted both at the function level (the real `claude_cache_gpg_verify`
against a fake `gpg` that emits `VALIDSIG`: an unset pin hard-aborts, a
matching pin is accepted, a non-matching pin is rejected) and end-to-end
(the full `ensure` flow hard-aborts and caches nothing under an unpinned
key). The network primitive and (for the pipeline tests) gpg are stubbed
with local fixtures, so it is fully offline and deterministic; requires
only `bash` + a sha256 tool.

`podman-mkosi-test.sh` exercises the recipe `provisioners/podman-mkosi.sh`
generates on the real host code path, stubbing only `podman` at the point
it would hand off to the build container, then asserting on the literal
generated `mkosi.conf` and `build-in-container.sh`. It was added after a
real end-to-end build (issue #105 review follow-up, PR #161) hit
failures — a paired-backtick command-substitution bug in the `mkosi.conf`
heredoc's comment prose that corrupted `RootPassword=`, and a missing
`curl`/`ca-certificates` in the build container's toolchain that broke
`render_apt_source`'s key fetch — none of which `config-test.sh`'s
pure-function cases could catch, since none of them render or execute the
actual generated recipe files. Since issue #107 it also covers the plugin
bake step: that the generated in-container script stages
`bake-plugins.json` and the verified `guest-claude` binary, drives
`claude plugin marketplace add` / `claude plugin install` under `HOME=/root`,
copies only `/root/.claude/plugins` into the image, and that a build with a
nonempty manifest but no `CLAUDE_VM_GUEST_CLAUDE_BIN` aborts instead of
shipping a plugin-less image. Issue #226 added the per-entry failure policy,
asserted by *running* the generated marketplace loop rather than grepping it:
the loop is sliced out of the captured `build-in-container.sh` and driven
against a stub `claude` whose exit status the test controls, so a failed add
(or a name mismatch) on a bake-declared entry still aborts, the same entry
declared `origin: boot` warns and continues, and an entry with no `origin`
falls back to the strict reading. The generated `apt_sources` loop is driven
the same way, against a real `bake-config.json` with `render_apt_source`
stubbed to record its argv, pinning that an entry with a `key_url` but no
`repo` keeps the key url in the third field — with a negative control
rebuilt from the same captured lines. It does not run a real `mkosi build` (no
container, no network); that gap is covered by `host-acceptance.sh`.

`host-acceptance.sh` is the self-contained on-host acceptance test for
the bootable runtime. It runs the acceptance criteria end-to-end with no
manual choreography: (a) the default provisioner builds a raw EFI image
with no override and no loop-device step, (b) vfkit boots it and the
guest reaches the claude-fetch seam **and runs the host-verified claude
off the `/mnt/claudebin` mount**, (c) the bundled proxy confines egress
to the allowlist (allowlisted host permitted, non-allowlisted refused,
empty allowlist denies all), and (d) the host-side verified cache —
exercised against **two locally-generated GPG keys over local fixtures**
(it does not reach `claude.ai`) — resolves+fetches+verifies+caches a
binary against the **pinned** key fingerprint, aborts on a tampered
manifest, aborts on a checksum mismatch, **rejects a valid signature made
by an unexpected (unpinned) key**, and serves a warm boot with no network.
Criterion (d) skips cleanly when `gpg` is absent. It is host-gated,
split by cause: it skips cleanly (exit 0) when a required *binary* is
absent (`gvproxy`, `vfkit`, `podman`, `tinyproxy`, `curl`, `jq`) — the test
cannot install software for you — mirroring how `config-test.sh` skips
when `yq` is absent. A podman binary present with only its *machine*
stopped or absent is **not** a skip: the test brings the machine up
itself (`init`+`start` when no machine exists, `start`-only when one is
stopped) and tears down exactly what it changed on exit. If a bring-up
the test attempted (`podman machine init`/`start`) **fails**, that is a
real failure, not a skip — the runtime it chose to provision did not
come up, so the test exits **non-zero** rather than green-exiting with
nothing proven. Requires `gvproxy` (resolved from podman's libexec),
`vfkit`, `podman`, `tinyproxy`, `curl`, and `jq` to actually run; `jq`
parses `podman machine list --format json` to resolve the target
machine's name structurally (the `{{.Name}}` Go template appends a `*`
default-marker that would corrupt the name — issue #57). A podman
machine is started by the test when needed rather than required up
front.

Diagnostics (build, boot, proxy logs and the `podman machine`
init/start stderr, plus a pass/fail summary) are written to a stable,
retained per-run directory under
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/logs/<run-id>/` and are
**not** deleted on exit, so a failed run stays diagnosable after the
fact. The resolved log directory is printed at the start and end of the
run. Teardown is best-effort but not silent: if a `podman machine
stop`/`rm` the test attempted does not succeed, it prints a
`WARNING (teardown)` to stderr and the log rather than swallowing the
failure, so a machine left dirty on the host is signalled instead of
hidden.
