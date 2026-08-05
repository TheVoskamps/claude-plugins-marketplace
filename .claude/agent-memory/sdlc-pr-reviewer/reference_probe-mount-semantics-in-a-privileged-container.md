---
name: probe-mount-semantics-in-a-privileged-container
description: Kernel mount-semantics claims in a claude-vm PR (ro inheritance through a bind, write-through, EBUSY) are settled by a privileged podman container, not by reasoning; two facts already established for FILE bind mounts.
metadata:
  type: reference
---

A claude-vm PR that mounts things in the guest makes **kernel** claims a
unit test can never reach ("`ro` is enforced", "the bind inherits
read-only-ness", "writes reach the host"). Do not reason about
`clone_mnt` from memory and do not accept the developer's real-boot
table as the only evidence — run the shape in a container:

```bash
podman run --rm --privileged --platform linux/arm64 \
  -v <repo>/.claude/tmp/<slug>:/probe-in:ro \
  docker.io/library/debian:12 bash /probe-in/probe.sh
```

`--platform linux/arm64` is required (see
[[podman-platform-flag-required]]); the script goes in a file under the
repo's `.claude/tmp/` because the gate blocks compound inline probes
(see [[git-sandbox-via-script-file]]). `findmnt -no OPTIONS <path>`
prints the resulting mount's real flags.

**What works and what does not in that container.** `mount --bind`,
`mount -o remount,ro,bind` and writes through them all work. A **loop**
mount (`mount -o loop file.img`) is refused with
`Operation not permitted` even under `--privileged`, so a
superblock-level `ro` filesystem cannot be built that way — reach the
`ro` case with bind + `remount,ro` instead, which is the *weaker* form
and therefore the stronger evidence.

**Two facts already established (issue #157 / PR #231), reusable:**

- **A file bound out of a read-only mount is read-only.** `mount --bind
  <ro-mount>/f /target/f` yields a mount whose options carry `ro`, and a
  write gets `Read-only file system` with the source unchanged. So
  claude-vm's `ro` single-file mount (wrap share mounted `-o ro`, then
  one file bind-mounted onto the target) really does reject guest
  writes.
- **A file bind mount cannot be replaced by rename.** `mv new target`
  onto the bind fails with `Device or resource busy`. In-place appends
  do reach the source inode. So an `rw` single-file mount serves `>>`
  writers but *not* `git config`, `sed -i` or an editor that writes a
  temp file and renames — the failure is loud, not silent, but "behaves
  exactly like an `rw` directory mount" is an over-claim worth a Low.
