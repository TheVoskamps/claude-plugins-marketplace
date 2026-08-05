---
name: probe-mount-semantics-in-a-privileged-container
description: Kernel mount-semantics claims in a claude-vm PR (ro inheritance through a bind, write-through, EBUSY, and whether root can remount a ro share rw) are settled by a privileged podman container plus the vfkit source, not by reasoning; facts already established for FILE bind mounts.
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
  Probe the named tools, not just `mv`: real `git config` fails
  `error: could not write config file …: Resource busy`, GNU `sed -i`
  fails `sed: cannot rename …: Device or resource busy`, and both
  succeed through a **directory** mount (the contrast that makes the
  sentence true). `docker.io/library/debian:12` has `sed` but no `git`;
  `docker.io/alpine/git` has git and needs `--entrypoint sh`.

**`ro` is a guest-side flag, not a host-side export (PR #231 round 2).**
vfkit's virtio-fs device has **no** read-only knob — `VirtioFs` in
`crc-org/vfkit` `pkg/config/virtio.go` is `DirectorySharingConfig` +
`SharedDir` (so `sharedDir` + `mountTag`), while `virtio-blk` and USB
mass storage do parse a `readonly` option. Read it with
`gh api repos/crc-org/vfkit/contents/pkg/config/virtio.go --jq .content
| base64 -d`. So the host always shares read-write and `mode: ro` is a
VFS flag inside a guest whose boot launcher runs as root. In the
container, root lifts exactly that: a `ro` bind refuses a write
(`Read-only file system`), `mount -o remount,rw,bind <mnt>` succeeds,
and the next write lands on the source. Virtiofs in a real guest is
**not** proven by that (different fs, one command to check:
`mount -o remount,rw /mnt/<tag>` in a booted guest), so raise it as a
labelled question, not a finding — but do raise it whenever a claude-vm
doc frames `ro` as something the guest "cannot write", because a fix
justified by that promise inherits its strength.
