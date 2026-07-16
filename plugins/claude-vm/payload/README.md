# claude-vm payload directory

This directory ships the executable payloads for the `claude-vm`
plugin: the config-driven launcher, the guest-image build recipe, the
config loader library, an example config, and the config-layering unit
test. They travel with the plugin and live at
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
  config.example.yml    # annotated example config
  lib/
    config.sh           # two-tier YAML loader + layering (sourced by
                        # claude-vm.sh; directly testable)
    claude-cache.sh     # host-side, GPG-manifest-verified `claude` binary
                        # cache (sourced by claude-vm.sh; directly testable)
  provisioners/
    podman-mkosi.sh     # bundled DEFAULT provisioner: mkosi in a throwaway
                        # rootless podman container -> raw EFI guest image
  proxy/
    tinyproxy-launch.sh # bundled DEFAULT proxy.cmd: renders a tinyproxy
                        # conf from $CLAUDE_VM_EGRESS_ALLOWLIST, execs it
  test/
    config-test.sh      # unit tests for the config layering
    claude-cache-test.sh
                        # unit tests for the verified claude cache
                        # (resolve/verify/checksum/abort/warm-boot; stubbed
                        # network+gpg, fully offline)
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
`mounts`, `repo.mount`, and `repo.copy_back` from two-tier YAML
(`~/.config/claude-vm/config.yml` and `<repo>/.claude-vm/config.yml`),
layering repo-over-global for scalars and unioning lists. See the
`claude-vm` skill (`skills/claude-vm/SKILL.md`) for the full schema and
semantics.

## Authentication

The guest authenticates claude with the **host operator's live claude.ai
OAuth credential** — the full-scope login credential, not a scoped
inference token — installed at `$HOME/.claude/.credentials.json`. That
bearer token alone is **not** sufficient for the interactive TUI to treat
itself as onboarded and logged in: current Claude Code also decides "am I
onboarded / logged in" from state in `~/.claude.json`. A fresh throwaway
guest lacks that state, so without it every launch hits the
onboarding/login wall despite the mounted credential. Beyond identity, two
keys matter: `hasCompletedOnboarding` (absent → claude runs its onboarding
flow) and `autoUpdates` (unset → claude tries to self-update and fails
against its RO-mounted binary in the egress-confined guest).

So the launcher **also seeds the guest's identity + onboarding state**
(issue #88): it reads your host `~/.claude.json` and emits a seed carrying
`userID` and `oauthAccount` selected from the host, plus four synthesized
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
`$HOME/.claude.json` (mode `0600`) before exec'ing `claude`, so the
in-guest session comes up already onboarded, logged in, and folder-trusted
— no wall, no trust prompt, no browser paste, no failed self-update. A
**preflight** aborts with an actionable message if the host
`~/.claude.json` is missing or lacks a usable `userID`/`oauthAccount`
(i.e. you are not logged in on the host). The seed carries account
identity, so it rides the same secret posture as the credential: written
under `umask 077` into the transient, owner-only (`0600`), shred-on-exit
`claudecreds` mount, **never** into `run.env` or the verified-binary
cache.

**Install-health check + auto-updater (issue #88).** Two more guest-side
steps keep the interactive TUI quiet. First, claude runs a startup
*install-health check* that probes for a working `claude` at the native
installer's location `~/.local/bin/claude`; because the guest execs the
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
It has two keys: `permissions` (`allow`/`ask`/`deny` verbatim from
`claude.permissions.*`, plus `defaultMode` from `claude.permission_mode`,
default `bypassPermissions`; only `bypassPermissions`/`default` are accepted,
anything else aborts the launch) and `enabledPlugins` (every ref in
`claude.plugins.bake ++ claude.plugins.install_at_boot` mapped to `true`, then
the optional `claude.plugins.enabled` map — which mirrors `settings.json`'s own
`enabledPlugins` vocabulary of plugin-ref → boolean — overrides those defaults
per key, so `false` marks a plugin installed-but-disabled). The `enabled` map
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
owner-only (`0600`) tmpfile and shared **read-only** into the guest under
`mountTag=claudecreds`. The guest boot launcher copies it into
`$HOME/.claude/.credentials.json` (mode `0600`) before exec'ing `claude`,
so `claude` finds it at the path it expects.

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
issue #103 — the guest-capability lists like `packages.bake` and
`claude.permissions.allow`, including keys nested two levels deep) are
unioned and de-duplicated. See the `claude-vm` skill
(`skills/claude-vm/SKILL.md`) for the full schema and semantics.

It also carries two small pure helpers used for the guest's `claude`
argv:

- `claude_vm_quote_args` — the host half of the `CLAUDE_ARGS`
  shell-quoting round-trip (issue #88). The user's post-repo CLI args
  travel to the guest as a single `CLAUDE_ARGS=` line in `run.env`. A
  flat unquoted join breaks the boot the instant an arg carries a space
  or a shell metacharacter (`--name "foo #7 micro-vm"` sourced as a bare
  line tries to *execute* the `--name` fragment, crashing the getty into
  an agetty respawn loop). The launcher instead %q-quotes each arg
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
  `settings.json` (issue #104) from the merged-config file. Pure (file in
  → JSON on stdout), so it is unit-tested host-side. Emits `permissions`
  (`allow`/`ask`/`deny` verbatim from `claude.permissions.*`, `defaultMode`
  from `claude.permission_mode`) and `enabledPlugins` (every ref in
  bake ++ install_at_boot defaults `true`, then `claude.plugins.enabled`
  overrides per key). Validates the `enabled` map once (boolean values;
  keys must name installed refs) and returns non-zero on a typo so the
  launcher aborts. Reads the claude-vm config only — never the host
  `~/.claude/settings.json`.
- `claude_vm_bake_config_json` / `claude_vm_bake_hash` /
  `claude_vm_bake_hash_from_json` / `claude_vm_bake_config_is_empty` — the
  bake-hash image-variant helpers (issue #105). `claude_vm_bake_config_json`
  emits the **canonical** bake-relevant config (sorted `packages.bake`,
  normalized `apt_sources`) as compact JSON; `claude_vm_bake_hash` hashes it
  to 8 hex chars (via `claude_vm_bake_hash_from_json`, which
  `build-guest-image.sh` reuses to hash the same bytes the launcher passes
  it). An empty/absent bake config canonicalizes to a constant, so
  `claude_vm_bake_config_is_empty` gates the launcher between the shared
  `guest.raw` and a `guest-<hash>.raw` variant. All pure and unit-tested.

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
build-guest-image.sh --print-version          # pinned version (base [+bake<hash>])
build-guest-image.sh --output <image-path>    # build + stamp .version
```

The image is a version-pinned stable base (OS + a boot launcher).
`claude` is never baked in; the boot launcher boots to the
**claude-fetch seam** and there execs the **host-verified `claude`
binary** mounted RO at `/mnt/claudebin` (see "Verified claude cache"
below) against the repo at `/mnt/repo` — as an interactive session on
the `hvc1` console (issue #88). The launcher builds the image on demand
when the configured image is missing or version-mismatched. No image
artifact is committed.

**Baked packages + image variants (issue #105).** Unlike `claude`,
`packages.bake` (apt packages) and `packages.apt_sources` (third-party apt
repos) ARE baked into the image. `build-guest-image.sh` reads the canonical
bake config from the `CLAUDE_VM_BAKE_CONFIG` env var (the launcher sets it via
`claude_vm_bake_config_json`), folds an 8-hex **bake-hash** over it into the
pinned version (`BASE_OS_REV+launcherN+bake<hash>`; a no-bake config keeps the
legacy base version), and passes the same config to the provisioner. Two
configs that bake different things therefore stamp different versions and get
different cached images; configs with no bake overrides share one `guest.raw`.
The launcher resolves the image path to `guest-<hash>.raw` for a baked config
and `guest.raw` otherwise (an explicit `guest_image` opts out and is used
verbatim). An unset/empty `CLAUDE_VM_BAKE_CONFIG` means no baked packages — the
legacy base image.

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
`packages.bake` into a `mkosi.conf.d` `Packages=` drop-in and each
`packages.apt_sources` entry into an apt keyring + `sources.list.d` drop-in in
the mkosi **sandbox tree** (fetching each `key_url` inside the build container,
which has network), so mkosi's apt can install packages served by third-party
repos. That keyring-fetch + sources-write step is a reusable unit the
boot-time-install slice (issue #106) reuses against the guest's live
`/etc/apt`.

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
**host-side**, then mounted RO into the guest — the guest never runs
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
   `~/.config/claude-vm/cache/<version>/linux-arm64/claude` and mount it
   RO into the guest (`mountTag=claudebin`).

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

Then set the fingerprint in `~/.config/claude-vm/config.yml` (or the
per-repo override):

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
Without this gate, a cold boot would otherwise pay for a guest-image
build and three network fetches (channel pointer + manifest + signature)
before aborting on a condition knowable at startup. The deep checks in
this library (gpg-on-PATH at the verify step, the unset-pin hard-abort)
and in `lib/credential.sh` (`python3` at the selection step) remain as
defense-in-depth — the preflight is an additive early gate, not a
replacement.

## Tests

```bash
"${CLAUDE_PLUGIN_ROOT}/payload/test/config-test.sh"
"${CLAUDE_PLUGIN_ROOT}/payload/test/claude-cache-test.sh"
"${CLAUDE_PLUGIN_ROOT}/payload/test/host-acceptance.sh"
```

`config-test.sh` exercises the config layering (scalar override, list
union, single-layer and no-layer fallbacks, de-duplication) with no VM
and no network. Requires `yq` (mikefarah v4+); skips cleanly when absent.

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

`host-acceptance.sh` is the self-contained on-host acceptance test for
the bootable runtime. It runs the acceptance criteria end-to-end with no
manual choreography: (a) the default provisioner builds a raw EFI image
with no override and no loop-device step, (b) vfkit boots it and the
guest reaches the claude-fetch seam **and execs the host-verified claude
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
