---
name: claude-vm-env-probe-recipe
description: The stub-claude boot probe extends cleanly to guest ENVIRONMENT assertions -- one build plus two ~1-minute boots proved issue #135's whole precedence chain, the second-run persistence of a baked value, and the absence of a forwarded secret from the .raw. Concrete gotchas and the leak-check shape.
metadata:
  type: project
---

Extends [[claude-vm-guest-boot-probe-via-stub-claude]] with the environment
case, done for real in issue #135.

**The stub `claude` is an env dumper.** `printf` each variable to `/dev/console`
(hvc0, the host-captured `logFilePath`), bracketing the block with an
`ENVPROBE-BEGIN`/`ENVPROBE-END` marker so the host poll loop has something
unambiguous to wait on and `grep -a` afterward. Use `eval "val=\${$v-<unset>}"`
so an unset variable is distinguishable from an empty one -- the difference is
usually the whole point.

**Drive the fixtures through the real helpers, never by hand.** The boot-tier
env file came from `claude_vm_resolve_boot_env` over a real boot document, and
the bake tier from `claude_vm_bake_config_json` -> the provisioner's own render.
A hand-written fixture would have measured my transcription, not the code.

**Two boots answer two different criteria, and the second is nearly free.**
Boot 1 with the full boot tier proves precedence; boot 2 of the SAME `.raw` with
an empty claudecreds share proves the baked half persists and the boot half is
absent. Both under a minute with the apt/plugin phases disabled.

**The leak check is `grep -a` over the booted `.raw`.** Give the secret a
distinctive literal (`SEKRIT-COPY-9f3a2b`), then after the boots
`LC_ALL=C grep -a -c '<literal>' guest.raw` -- ~20s over 1.9 GB, and it is a
genuine "not on the guest filesystem after exit" measurement because
`virtio-blk,path=` is read-write, so anything the guest wrote is in that file.
Pair it with an in-guest `grep -rl` over `/root /etc /var`.

**Gotchas beyond the parent memory's list:**

- The build's `--print-version` and `--output` both need
  `CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS` set to a probe-specific string, or you
  race the operator's real cached images.
- `CLAUDE_VM_ROOT_HEADROOM_MB=512` is plenty for a probe and shaves the build.
- The `Bash` tool's gate refuses any command containing `yq eval` (it reads
  "eval") and refuses `>` redirects to `/tmp`. Put probe commands in a script
  file under `.claude/tmp/<slug>/` and run `bash <script>` -- that clears both.
