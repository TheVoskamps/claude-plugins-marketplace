# claude-vm payload directory

This directory ships the executable payloads for the `claude-vm`
plugin: the config-driven launcher, the guest-image build recipe, the
config loader library, an example config, and the config-layering unit
test. They travel with the plugin and live at
`${CLAUDE_PLUGIN_ROOT}/payload/...` once installed.

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

## Launcher (`claude-vm.sh`)

```bash
export ANTHROPIC_VM_TOKEN=<scoped-key>        # the only secret; env-only
"${CLAUDE_PLUGIN_ROOT}/payload/claude-vm.sh" /path/to/repo [claude args...]
```

Reads `cpus`, `mem`, `guest_image`, proxy config, `egress.allow`,
`mounts`, `repo.mount`, and `repo.copy_back` from two-tier YAML
(`~/.config/claude-vm/config.yml` and `<repo>/.claude-vm/config.yml`),
layering repo-over-global for scalars and unioning lists. See the
`claude-vm` skill (`skills/claude-vm/SKILL.md`) for the full schema and
semantics.

## Config loader (`lib/config.sh`)

Pure layering logic: two YAML inputs → one merged document. Both layers
are optional; a missing layer contributes an empty document. Scalars
are repo-over-global; `egress.allow` and `mounts` are unioned and
de-duplicated.

## Guest image (`build-guest-image.sh`)

```bash
build-guest-image.sh --print-version          # pinned base version
build-guest-image.sh --output <image-path>    # build + stamp .version
```

The image is a version-pinned stable base (OS + a one-shot boot
launcher). `claude` is never baked in; the boot launcher boots to the
**claude-fetch seam** and there execs the **host-verified `claude`
binary** mounted RO at `/mnt/claudebin` (see "Verified claude cache"
below) against the repo at `/mnt/repo`. The launcher builds the image on
demand when the configured image is missing or version-mismatched. No
image artifact is committed.

Provisioning the bootable raw image defaults to the bundled
`provisioners/podman-mkosi.sh` — mkosi run inside a throwaway rootless
podman container (Debian Trixie build container, systemd ≥ 254 for the
offline, loop-device-free `RepartOffline=yes` path), emitting a raw
EFI-bootable Debian guest with the boot launcher installed as a
`Type=oneshot` unit. vfkit boots it with `--bootloader efi`. Requires
`podman` with a started podman machine. Override with
`CLAUDE_VM_IMAGE_PROVISIONER` set to a script taking
`<boot-launcher-path> <output-image-path>`.

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
branch. Trusting
`install.sh`'s own checksum would be circular (the script is itself
unsigned and re-fetched each boot), so the signed manifest is the root of
trust. `install.sh | bash` is retained only as an explicit **lower-trust
fallback** when no cache is configured (behind the egress allowlist,
suicide-on-fail).

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
for the verified cache to function. Operators who have not pinned it use
the `install.sh | bash` **lower-trust fallback** path instead (see below).

**Warm boot:** when the resolved version is already cached, the binary is
not re-downloaded and `gpg` is not re-run, and the launcher drops
`claude.ai` / `downloads.claude.ai` from the guest's egress allowlist
(the guest never needs them — the binary came from the host-side cache).
Requires `gpg` (`brew install gnupg`) and a sha256 tool (`shasum` /
`sha256sum`, both stock on macOS/Linux).

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
