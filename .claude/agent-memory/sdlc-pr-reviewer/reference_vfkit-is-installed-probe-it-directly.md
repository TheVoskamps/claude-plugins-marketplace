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
is safe to run in a review worktree. **A device string that PARSES does not:**
it proceeds to VZ config construction and then to an actual boot. Keep the
probe non-booting by pointing `sharedDir=` at a path that does not exist — the
run then dies on `Error: stat <path>: no such file or directory`, which also
proves the parse succeeded. Never probe a valid device with an existing dir.

**Proving "last key wins" needs a position-reversal control (PR #231 r5).**
Two repeated `sharedDir=` keys, both nonexistent, and the error names the
survivor; then swap them and the survivor swaps too, which is what rules out
"the second name just happens to be the one it stats":

```text
sharedDir=/tmp/vfk-first-nx,sharedDir=/tmp/vfk-second-nx -> stat /tmp/vfk-second-nx
sharedDir=/tmp/vfk-second-nx,sharedDir=/tmp/vfk-first-nx -> stat /tmp/vfk-first-nx
```

**The comma is the only metacharacter in that string.** Also measured on
v0.6.4: `sharedDir=/tmp/vfk-nx-a=b` and `sharedDir=/tmp/vfk nx sp` both reach
`stat` with the path intact, so an `=` or a space in an operator path is
harmless and a guard that widens the comma check into a charset is
over-reach. A bare comma gives `unknown option for virtio-fs devices: <rest
of the path up to the next comma>`.

**What it establishes:** on v0.6.4, `virtio-fs` rejects `readOnly`, `readonly`
and a bare `ro` as `unknown option for virtio-fs devices: <key>`, while
`virtio-blk,…,readonly=true` fails on the *value*
(`unexpected value for virtio-blk 'readonly' option: true`) and a genuinely
unknown key on that same device gives the `unknown option` wording. That
contrast is the whole evidence that the read-only gap is specific to
virtio-fs rather than a quirk of the option parser — run the block-device
control too, not just the virtio-fs case. Related:
[[probe-mount-semantics-in-a-privileged-container]].
