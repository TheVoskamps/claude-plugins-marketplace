---
name: vfkit-is-installed-probe-it-directly
description: vfkit is on this machine (/opt/homebrew/bin/vfkit), so a claude-vm PR's device-option claims are first-hand verifiable — but only with a valid --bootloader, and the Error line is never the first line of output
metadata:
  type: reference
---

claude-vm PRs make load-bearing claims about what vfkit's `--device` parser
accepts. Do not verify those from the vfkit source on GitHub when the binary
is right here:

```bash
vfkit --version                       # v0.6.4 as of PR #231
T=$(mktemp -d)
vfkit --bootloader "efi,variable-store=$T/efi.nvram,create" \
      --device "virtio-fs,sharedDir=/tmp,mountTag=probe,readOnly=true" 2>&1 \
  | grep -a -m1 -iE '^Error:|unknown option|unexpected value'
```

Two traps:

- **`--bootloader` is validated before `--device`.** Without one, every probe
  dies on `Error: empty option list in --bootloader command line argument` and
  the device string is never parsed. Use the same `efi,variable-store=…,create`
  form the launcher uses (`claude-vm.sh`); it writes only into the temp dir.
- **The `Error:` line is not line 1.** vfkit logs
  `level=info msg="virtual machine parameters:"` first, so a `| head -1`
  probe reports the log line and looks like the device was accepted. Grep for
  the error instead.

Nothing here boots a VM — every invocation dies in argument validation, so it
is safe to run in a review worktree.

**What it establishes:** on v0.6.4, `virtio-fs` rejects `readOnly`, `readonly`
and a bare `ro` as `unknown option for virtio-fs devices: <key>`, while
`virtio-blk,…,readonly=true` fails on the *value*
(`unexpected value for virtio-blk 'readonly' option: true`) and a genuinely
unknown key on that same device gives the `unknown option` wording. That
contrast is the whole evidence that the read-only gap is specific to
virtio-fs rather than a quirk of the option parser — run the block-device
control too, not just the virtio-fs case. Related:
[[probe-mount-semantics-in-a-privileged-container]].
