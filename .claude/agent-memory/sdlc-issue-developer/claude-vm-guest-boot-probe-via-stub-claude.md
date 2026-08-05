---
name: claude-vm-guest-boot-probe-via-stub-claude
description: A claude-vm guest boot can be turned into an arbitrary in-guest assertion runner by putting a SHELL SCRIPT named `claude` on the claudebin share -- no real claude binary, no GPG pin, no Keychain, no api.anthropic.com. This is how issue #157's guest-observable acceptance criteria were verified for real.
metadata:
  type: project
---

Extends [[claude-vm-real-build-and-boot-is-doable]]. That memory's recipe drives
a real boot with the REAL claude binary and `CLAUDE_ARGS='plugin list'` as the
assertion channel, which costs you the GPG-fingerprint dance and only answers
"what plugins got installed". When the thing under test is **guest filesystem
state** (mounts, paths, permissions, file content) there is a far cheaper channel.

**The boot launcher runs `"$CLAUDE_BIN" "$@"` as the hvc1 session, and
`CLAUDE_BIN` is `/mnt/claudebin/claude` -- a path on a share YOU stand up.** Put
a `#!/bin/sh` script there instead of the binary. It only has to be executable
(the seam's check is `[ ! -x "$CLAUDE_BIN" ]`). It then runs as root inside the
booted guest, can assert anything, and `exit 0` makes the guest power itself off.
`payload/test/host-acceptance.sh` criterion (b) already does exactly this, so it
is established practice in the repo rather than a hack.

Write results to `/dev/console` (hvc0), not stdout: hvc0 is the host-captured
`logFilePath` console, so the assertions survive in a file you grep afterward.

**A build needing no claude binary at all.** `CLAUDE_VM_GUEST_CLAUDE_BIN` is only
consumed when the plugin manifest is non-empty. Drive `build-guest-image.sh
--output` with `CLAUDE_VM_BAKE_CONFIG` / `CLAUDE_VM_BAKE_PLUGINS` derived from
two `{}` documents and the whole verified-cache/GPG path is skipped. ~7 min,
1.9 GB. Set `CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS` to a probe-specific string so
you never collide with a real cached image.

**Skip the boot phases you are not testing** by writing empty
`apt-install.list` / `apt-sources.tsv` / `plugin-marketplaces.tsv` /
`plugin-install.list` on the runconfig share and
`CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT=false` /
`CLAUDE_VM_PLUGINS_UPDATE_AT_BOOT=false` in run.env. Boot drops to well under a
minute, and no egress is needed.

**Non-obvious requirements, each of which costs a boot:**

- `settings.json` on the claudecreds share is a HARD abort if absent -- render
  it with the real `claude_vm_render_guest_settings` over a `{}` doc. A missing
  `.credentials.json` / `claude-json-seed.json` only warns.
- Attach a SECOND `virtio-serial,logFilePath` even headless. Without a second
  console device `serial-getty@hvc1` has no tty, the boot launcher never runs,
  and nothing at all appears.
- The gvproxy socket dir must be a SHORT `$TMPDIR` path (AF_UNIX 104-byte
  limit); a `.claude/worktrees/agent-<hash>/...` path overflows.
- `efi,variable-store=$X,create` needs `$X` to not exist.

**Write-through is checkable from the host side afterward**: the shares are
ordinary host directories, so after the VM exits just `cat` them. That is how
"an rw mount's guest write reaches the host immediately" was proven for #157,
along with a hard-linked single-file mount writing through to the real host file.

Artifacts are large (820 MB with the .raw). Keep them under
`.claude/tmp/<slug>/` and delete when the run succeeds.
