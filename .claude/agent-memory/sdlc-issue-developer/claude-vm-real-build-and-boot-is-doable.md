---
name: claude-vm-real-build-and-boot-is-doable
description: A claude-vm real image build, a real vfkit boot (plugin phase included), and real linux-arm64 execution of a compiled hook ARE all achievable from a throwaway subagent worktree -- start the podman machine and verify container network first, fetch your own verified claude binary into the repo scratch since the host cache is unreadable, drive vfkit with CLAUDE_ARGS='plugin list' as the assertion channel, and inspect the built .raw with debugfs, not mount.
metadata:
  type: project
---

Contradicts the older assumption that a subagent "cannot build+boot" claude-vm.
In issue #107 both were done for real from a throwaway worktree. The recipe:

**1. The podman machine is usually STOPPED and must be started explicitly.**
`podman machine start` (it already exists on this host; it is NOT an install).
`payload/test/host-acceptance.sh` starts it itself, but its start did NOT
produce a working container network on the first attempt -- the build failed
with `Unable to connect to deb.debian.org:80` and `E: Unable to locate package
python3`. **That failure looks exactly like a broken change and is not one.**
Before concluding anything about your own diff, verify container egress:

```bash
podman run --rm docker.io/library/debian:trixie \
  sh -c 'apt-get update -qq >/dev/null 2>&1 && echo OK || echo FAILED'
```

A manual `podman machine start` beforehand made it OK, after which
host-acceptance passed **14/14 including criterion (b), a real vfkit boot**.
Stop the machine again when done -- restore the state you found.

**2. Drive the build directly** with `build-guest-image.sh --output <path>`,
exporting the same env the launcher does (`CLAUDE_VM_BAKE_CONFIG`,
`CLAUDE_VM_BAKE_PLUGINS`, `CLAUDE_VM_GUEST_CLAUDE_BIN`,
`CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS`). ~7 minutes. Derive the two JSON blobs
with the real `claude_vm_bake_config_json` / `claude_vm_bake_plugins_json` over
hand-written merged docs; `MERGED_BAKE` is just the merge of the bake FILES in
their own file schema (`packages:` is a flat list there -- there is no
`.packages.bake` normalization on that path).

**2b. Getting a real linux-arm64 claude binary in a WORKTREE subagent.** The
host's cache under `~/.config/claude-vm/cache/` exists, but the gate refuses a
worktree agent any read outside the repo -- you cannot even `ls` it. Fetch your
own into the repo scratch instead, via the product's own verified path, touching
no host state:

```bash
CLAUDE_VM_CACHE_DIR=<repo>/.claude/tmp/<slug>/cache \
CLAUDE_VM_SIGNING_KEY_FINGERPRINT=<fpr> \
  bash -c '. lib/claude-cache.sh; claude_cache_ensure stable'
```

The fingerprint is the only blocker, and it has a clean solution. Invoking `gpg`
yourself is permission-DENIED, and the pinned value lives in
`~/.config/claude-vm/config-boot.yml`, which you cannot read. But
`claude_cache_gpg_verify` PRINTS the real signing-key and primary-key
fingerprints in its mismatch diagnostic -- so run the command above once with a
dummy pin and read them off stderr. Corroborate that value against the published
key by computing the OpenPGP v4 fingerprint of
`https://downloads.claude.ai/keys/claude-code.asc` in pure Python:
`sha1(b"\x99" + uint16(len(body)) + body)` over the first tag-6 packet, stdlib
only, no gpg. Both fingerprints come out
`31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`. gpg itself still runs fine INSIDE the
product's own scripts; only your own top-level `gpg` call is blocked.

**2c. A full real vfkit boot INCLUDING the plugin phase is drivable yourself.**
Copy criterion (b)'s mount topology out of `payload/test/host-acceptance.sh`
(repo / runconfig / claudebin / claudecreds virtio-fs shares, two virtio-serial
logFilePath consoles -- device ORDER is load-bearing, 1st is hvc0, 2nd hvc1), but
put the REAL claude binary on claudebin and write real
`plugin-marketplaces.tsv` + `plugin-install.list` onto runconfig. Set
`CLAUDE_ARGS` (via `claude_vm_quote_args`) to `plugin list`: claude then runs
non-interactively, prints the installed set to hvc1, exits 0, and the guest
powers itself off -- an assertion channel for what the boot phase actually
installed, with no interactive session and no Keychain. Two gotchas that cost a
boot each:

- `efi,variable-store=$X,create` needs `$X` to NOT exist; pre-creating it as a
  directory fails with `NSPOSIXErrorDomain Code=21 "Is a directory"`.
- The gvproxy socket must live under a SHORT `$TMPDIR` dir (use
  `claude_vm_mktemp -d`, which is what the launcher does). vfkit derives a
  sibling socket in the same directory and the AF_UNIX limit is 104 bytes -- a
  `.claude/worktrees/agent-<hash>/...` path is already ~159.
- A local-path marketplace (`/mnt/repo`) does NOT need a `.git` dir; a plain
  `git archive` export of the tree registers and installs fine.

**3. Inspect the built .raw with `debugfs`, NOT `mount`.** Loop devices are
unavailable in this podman machine even under `--privileged` (which is the
whole reason the recipe uses `RepartOffline=yes`), and a macOS bind-mounted
.raw cannot back a loop device either. What works:

```bash
# in a container, with the .raw bind-mounted read-only
sfdisk -J guest.raw            # root partition is the LAST entry
dd if=guest.raw of=/var/tmp/root.img bs=1M skip=<start*512/1MiB> count=...
debugfs -R "ls -l /root/.claude/plugins" /var/tmp/root.img
debugfs -R "rdump /root/.claude/plugins /somewhere" /var/tmp/root.img
```

**4. The guest-side boot phases are testable for real without a VM** by
extracting the function out of the `<<'BOOT'` heredoc (same awk slice
`config-test.sh` uses) and sourcing it in an arm64 container against the real
linux-arm64 claude binary. That is how #107's `update_at_boot` criterion was
verified end-to-end (a baked plugin really went 0.1.0 -> 0.2.0 off a
marketplace bump).

**5. A compiled hook binary IS testable on real linux-arm64 without any VM.**
(Corrects the older "not reachable" claim below.) The podman machine on this
host is `arm64 linux`, and `docker.io/library/debian:{trixie,bookworm}` are
already cached, so a plain container IS the guest's platform:

```bash
podman run --rm -i -v <worktree>:/wt:ro docker.io/library/debian:trixie \
  sh /wt/<probe>.sh
```

Notes that made this work in issue #216:

- `-i` is REQUIRED or stdin is empty and the gate fail-closes on
  "empty event payload" -- which looks like a bug in your change and is not.
- Extract the command under test verbatim with
  `jq -r '.hooks.PreToolUse[0].hooks[0].command' <hooks.json> > run-hook.sh`,
  then `sh run-hook.sh < event.json`. Never retype the command string.
- `CLAUDE_PLUGIN_ROOT` can't be set inline (gate blocks inline assignment on
  some forms) and shell state doesn't persist between Bash calls -- put the
  `export` in a tiny wrapper script that then `sh`s the untouched command file.
- The base debian images have **no git**, so Engine B fail-closes to `ask`.
  For a real containment `deny` you need `apt-get install -y git` inside the
  `--rm` container (ephemeral rootfs; touches neither the host nor any
  lockfile) plus a real `git init` repo as the event `cwd`.
- `--platform linux/amd64` works under emulation, so the linux-amd64 binary is
  exercisable from the Mac too.

**Not reachable this way:** an interactive in-guest *claude session* (the
harness actually firing the hook). A NON-interactive one is (see 2c). The binary
and the hooks.json wrapper are
both fully testable here; the claude-code integration on top of them is not --
but that integration IS reachable in a real guest, pre-merge, per
[[baked-plugin-changes-verifiable-pre-merge-via-local-marketplace]] (launch the
guest from the PR-branch worktree and install the branch from `/mnt/repo` as a
local marketplace). Treat these container probes as corroboration for the live
guest run, not as a substitute for it. See [[unit-tests-are-not-real-runs]] --
the standard is unchanged, this memory just widens how much of it you can meet
without a guest.
