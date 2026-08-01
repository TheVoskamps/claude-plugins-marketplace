---
name: claude-vm-real-build-and-boot-is-doable
description: A claude-vm real image build, a real vfkit boot, and real linux-arm64 execution of a compiled hook ARE all achievable from a throwaway subagent worktree -- start the podman machine yourself and verify container network first; inspect the built .raw with debugfs, not mount; probe arm64 binaries in a plain podman container.
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
`CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS`). ~7 minutes. A verified linux-arm64 claude
binary is already cached at `~/.config/claude-vm/cache/<version>/linux-arm64/claude`.

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

**Still NOT reachable this way:** an interactive in-guest *claude session*
(the harness actually firing the hook). The binary and the hooks.json wrapper
are both fully testable; the claude-code integration on top of them is not.
And per [[baked-plugin-changes-unverifiable-pre-merge]] the guest bake pulls
the marketplace's default branch, so a feature branch can't be guest-tested at
all pre-merge. See [[unit-tests-are-not-real-runs]] -- the standard is
unchanged, this memory just widens how much of it you can actually meet.
