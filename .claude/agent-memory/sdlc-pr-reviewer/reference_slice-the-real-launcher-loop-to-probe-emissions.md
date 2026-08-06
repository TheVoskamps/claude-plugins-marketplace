---
name: slice-the-real-launcher-loop-to-probe-emissions
description: A claude-vm validator guards the CONFIG value, but what breaks is the DERIVED string the launcher emits — reuse config-test.sh's own line-range slice to run the real loop under a hostile $TMPDIR/$RUN and read the actual --device flags.
metadata:
  type: reference
---

When a `plugins/claude-vm` PR adds a guard on a config field (a comma in
`source:`, a charset on `tag:`), the guard runs at config load over the
**config value**. What actually reaches vfkit is a **derived** string the
launcher builds later — `sharedDir=$MOUNT_WRAP_DIR/<tag>`,
`sharedDir=$MOUNT_SHARED_DIR` — from host paths the validator never sees
(`$RUN`, `$TMPDIR`, `$HOME`). Grade the guard against the emitted string,
not the checked one, and *measure* it rather than reading the code.

`config-test.sh` already contains the extraction; reuse it rather than
hand-copying the loop:

```bash
START="$(grep -n '^EXTRA_MOUNT_FLAGS=()$' "$LAUNCHER" | head -1 | cut -d: -f1)"
END="$(awk -v s="$START" 'NR >= s && /^done < <\(claude_vm_mount_specs/ { print NR; exit }' "$LAUNCHER")"
```

then wrap the captured lines in a harness that sources the real `lib/config.sh`
and supplies `MERGED_BOOT`, `RUN`, `MOUNT_SHARED_DIR`, `CONFIG_DIR`, and
`printf` the resulting `EXTRA_MOUNT_FLAGS`. Pass `MOUNT_SHARED_DIR` = the
tree `$RUN` sits in to get the `repo.mount: live` branch, or `$RUN/worktree`
for `clone`. Same trick works for the config-load gate block
(`GATE_START`/`GATE_END` in the same file) when you want the real validator.

**What it found on PR #231 (issue #157):** the new comma guard exempts a
single-FILE source because "what gets shared then is the wrap directory,
named after the already-checked tag" — but only the `<tag>` component is
checked. With `repo.mount: live`, a clean repo path and a `$TMPDIR` carrying
a comma, the real loop emits
`virtio-fs,sharedDir=<...>/tmp,dir/claude-vm-wrap.X/cfg,mountTag=cfg` on a
config the validator **accepted**, and vfkit answers
`unknown option for virtio-fs devices: dir/claude-vm-wrap.X/cfg`. Loud, so
Low — and it is the one member of that class the PR's own diff *adds*.

**The premise I attached to it was false, and measuring it was one grep
away.** I wrote that the wrap share was reachable "with every built-in path
clean, since in the git-repo + `live` shape no built-in device touches
`$TMPDIR`". `--device virtio-net,unixSocketPath=$GVPROXY_SOCK` is a
`mktemp -d` under `$TMPDIR` on **every** launch, and `$RUN` also rides
`efi,variable-store=`, `virtio-blk,path=` and `virtio-serial,logFilePath=` —
each splitting on a comma exactly like `sharedDir=`. So a guard there buys an
earlier, cause-naming abort, never a rescue. Enumerate the emitted strings
with `grep -n -- '--device'` plus the assignment of each interpolated
variable *before* filing; see [[measure-the-quantifier-in-your-own-premise]].

Related: [[vfkit-is-installed-probe-it-directly]] (feed the emitted string to
the real parser), [[negative-control-assertions-via-hybrid-tree]] and
[[git-sandbox-via-script-file]] (the gate blocks compound inline probes).
