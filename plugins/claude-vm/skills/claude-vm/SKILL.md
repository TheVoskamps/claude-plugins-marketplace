---
name: claude-vm
description: Launch Claude Code inside an isolated macOS VM with config-driven egress, mounts, VM resources, and repo isolation (clone or live). All non-secret knobs come from two-tier YAML (global + per-repo); only ANTHROPIC_VM_TOKEN stays an env var.
---

# claude-vm

Run Claude Code inside an isolated macOS VM. Every non-secret
operational knob — VM resources, the egress allowlist, extra mounts,
the proxy, and how the repo is made available to the guest — comes from
layered **YAML config** rather than environment variables. Only the
scoped access token (`ANTHROPIC_VM_TOKEN`) stays an env var and is
never written to config.

The launcher and image-build scripts ship as payloads under
`${CLAUDE_PLUGIN_ROOT}/payload/`. This skill is the entry point that
explains the config surface and drives the launcher.

## Quick start

```bash
# 1. Provide the scoped token as an env var (never in config).
export ANTHROPIC_VM_TOKEN=<scoped-key-for-the-guest>

# 2. (Optional) drop a global config at ~/.config/claude-vm/config.yml
#    and/or a per-repo config at <repo>/.claude-vm/config.yml.
#    Run /claude-vm-config-global to write the global config from the
#    resolved defaults, and /claude-vm-config-repo (from inside a repo)
#    to write per-repo overrides (both idempotent), or see
#    payload/config.example.yml for a starting point.

# 3. Launch against a repo. The repo is made available RW to the guest.
"${CLAUDE_PLUGIN_ROOT}/payload/claude-vm.sh" /path/to/repo [claude args...]
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

- **Scalars** (`cpus`, `mem`, `guest_image`, `repo.mount`,
  `repo.copy_back`, `proxy.*`): repo overrides global; global fills
  gaps; a hardcoded default applies only when neither layer sets the
  key.
- **Lists** (`egress.allow`, `mounts`): **merged** — the union of
  global + repo entries, de-duplicated.

### Keys

```yaml
cpus: 4
mem: 8192
guest_image: /path/to/guest.raw   # repo may override; default cache
                                  # location (~/.config/claude-vm/images/
                                  # guest.raw) when unset

repo:
  mount: clone                    # clone (default) | live
  copy_back: local                # local (default) | none

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
```

- `egress.allow` is written to a newline-delimited file whose path is
  exported as `CLAUDE_VM_EGRESS_ALLOWLIST`. When `proxy.cmd` is unset,
  the launcher defaults to the bundled tinyproxy launcher
  (`payload/proxy/tinyproxy-launch.sh`), which reads that file and binds
  `CLAUDE_VM_PROXY_PORT`. A `proxy.cmd` override must likewise read that
  file instead of a hand-maintained allowlist baked into the command.
- `mounts` generates the extra `virtio-fs` device flags. A leading `~`
  in `source` expands to `$HOME`.

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

## Guest image — built on demand, version-pinned, claude fetched at boot

Claude Code updates daily, so the guest image does **not** bake in
`claude`:

- The baked image is a **stable base**: a pinned OS plus a one-shot
  boot launcher that, on boot, loads the run environment and stops at an
  explicit **claude-fetch seam**. `claude` is never baked in; a later
  slice fills the seam by mounting a host-side GPG-verified `claude`
  binary into the guest (rather than a `curl install.sh | bash` path).
  The base only changes when the base OS pin or the launcher logic
  changes — not when claude does.
- The base is **version-pinned** in `payload/build-guest-image.sh`
  (`BASE_OS_REV` + `LAUNCHER_LOGIC_REV`; never the claude version).
- On startup, the launcher **ensures the image exists and matches the
  pinned version**. If `guest_image` is missing or version-mismatched,
  it builds the image (`payload/build-guest-image.sh --output …`)
  rather than erroring. The image's pinned version is stamped at
  `<image>.version`.
- **No image artifact is committed to the repo**, and there is no
  publish-prebuilt-image path. Every machine builds its own.

The provisioning step that produces the bootable raw image defaults to
the bundled `payload/provisioners/podman-mkosi.sh`: mkosi run inside a
throwaway rootless podman container (Debian Trixie build container,
systemd ≥ 254 for the offline, loop-device-free `RepartOffline=yes`
path), emitting a raw EFI-bootable Debian guest with the boot launcher
installed as a `Type=oneshot` unit. vfkit boots it `--bootloader efi`.
`build-guest-image.sh` pins the version and emits the boot launcher, then
hands `<boot-launcher-path> <output-image-path>` to the provisioner. The
`CLAUDE_VM_IMAGE_PROVISIONER` env var overrides the bundled default with
your own script honoring the same two-argument contract.

## Secrets

`ANTHROPIC_VM_TOKEN` is the only secret. Supply it as an env var (or a
secret reference your shell resolves to an env var) before launching.
The launcher passes it to the guest at runtime via the run-config
mount. It is **never** read from or written to any config file. The
launcher fails fast if it is unset.

## Requirements

`yq` (mikefarah v4+), `git`, and — for an actual VM boot — `vfkit`,
`podman` (with a started podman machine, for the bundled podman-mkosi
provisioner that builds the guest image), and `tinyproxy` (for the
bundled default `proxy.cmd`). On a clean host:
`brew install yq git vfkit podman tinyproxy`.

`gvproxy` is **not** a separate install and need not be on PATH: it
ships inside the podman Homebrew formula at
`<brew-prefix>/libexec/podman/gvproxy` and a stock `brew install podman`
does not symlink it onto PATH. The launcher resolves it automatically
(an explicit on-PATH `gvproxy` first, then podman's libexec), so
installing podman is enough.

Before any build/boot work, the launcher runs a **dependency
preflight** that checks the whole toolchain up front (gvproxy
resolvable, `vfkit`/`podman` on PATH, podman machine running, and —
only when the bundled default proxy is in use — `tinyproxy`). It fails
fast with one actionable remediation line per missing piece rather than
dying deep in the boot sequence. A custom `proxy.cmd` owns its own
dependencies, so the `tinyproxy` check is skipped then.

The config-resolution half (layering, scalar/list resolution) is
exercisable without the virtualization stack; see
`payload/test/config-test.sh`. The end-to-end acceptance test —
default-provisioner build, vfkit boot to the claude-fetch seam, and
egress confinement — is `payload/test/host-acceptance.sh`; it is
host-gated by cause: it skips cleanly when a required binary is absent,
but a stopped or absent podman machine is not a skip — the test starts
the machine itself and tears down exactly what it changed on exit. A
bring-up the test attempted that then fails (`podman machine
init`/`start`) is a real failure, not a skip: the test exits non-zero
rather than green-exiting with nothing proven. Diagnostics (including
the machine init/start stderr) are retained under
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/logs/<run-id>/` so a failed
run stays diagnosable.
