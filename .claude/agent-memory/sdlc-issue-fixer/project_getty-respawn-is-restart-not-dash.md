---
name: getty-respawn-is-restart-not-dash
description: "systemd getty respawn comes from Restart=always in the stock template, NOT the leading `-` on ExecStart; and claude-vm's image identity hash never covers launcher source."
metadata:
  type: project
---

Two claude-vm guest-image facts that are easy to get backwards and expensive to
get wrong.

**1. The getty respawn is governed by `Restart=`, not the leading `-`.**
`serial-getty@.service` (systemd upstream) ships `Restart=always`. Overriding it
to `Restart=no` in a drop-in is the *only* thing that stops the unit restarting
when its login program exits. The leading `-` on `ExecStart=-/sbin/agetty` does
something different: it makes a nonzero exit be *reported* as success. Dropping
it makes a failed launcher mark the unit `failed`, which is inert unless
something sets `OnFailure=`/`FailureAction=`.

**Why:** claude-vm PR #180 shipped correct behavior with the wrong rationale in
six places. A future reader could "restore" the `-` believing it inert, or
delete `Restart=no` believing the missing `-` covered it — either one silently
rebuilds the respawn loop.

**2. The image identity hash does NOT cover the boot-launcher source.**
`claude_vm_image_identity_segments` (payload/lib/config.sh) hashes the two bake
CONFIG files plus the repo name. Nothing else. So `LAUNCHER_LOGIC_REV` in
`build-guest-image.sh` is the *sole* mechanism invalidating a cached image when
launcher logic changes. Forgetting the bump means an operator's cached
`launcherN` image is reused with the old launcher and the fix silently does not
apply. A config migration often forces a rebuild incidentally — incidental is
not a guarantee, and does not cover a re-run after the migration settles.

**How to apply:** any PR touching the emitted boot launcher or the getty drop-in
must bump `LAUNCHER_LOGIC_REV` and say so in the rev's changelog stanza. Verify
the upstream template claim against systemd source (fetchable via raw
githubusercontent) rather than from memory — see [[verify-territory-not-relay]].
