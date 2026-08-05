---
name: real-boot-that-exercises-mounts-from-a-worktree
description: host-acceptance.sh never exercises `mounts:`; to boot-test the guest mount phase, copy its criterion-(b) choreography and add a reporting stub claude — but the worktree path breaks gvproxy's AF_UNIX socket, so boot with NO network instead
metadata:
  type: project
---

`plugins/claude-vm/payload/test/host-acceptance.sh` does a genuinely real
build + boot, but its criteria are (a)–(d) only: it attaches the four
built-in shares and never writes a `mounts.tsv`. A change to
`boot_mount_phase` is therefore **not** verified by running it — it only
proves the launcher you emit still boots
([[real-build-verification-not-unit-tests]]).

**Recipe that did exercise it** (issue #157 PR #231): copy criterion (b)'s
choreography into a scratch script — the four shares, the stub run.env,
the stub credential/seed/settings, `--bootloader efi,...,create`, two
`virtio-serial,logFilePath` devices in that order (1st → hvc0
diagnostics, 2nd → hvc1 where the stub claude's stdout lands) — then add
the `mounts:` shares, hand-write a `mounts.tsv` on the runconfig share,
and make the **stub claude a reporting probe**: it runs after
`boot_mount_phase`, so `grep virtiofs /proc/mounts`, `cat` the mounted
files, and write into an rw mount, all echoed with a greppable prefix.
Host-side write-through is then checked after the VM exits. This produced
a per-criterion table of *guest-observed* facts in one boot.

**The blocker, and the way around it.** AF_UNIX `sun_path` is ~104 bytes
and vfkit derives a CHILD socket beside the one it is handed. A
`.claude/worktrees/agent-<hash>/` path is already ~112 bytes before any
filename, so the gvproxy socket cannot live under the worktree at all —
and a relative path does not help: gvproxy parses `--listen-vfkit` as a
URL, so `unixgram://net.sock` puts `net.sock` in the HOST component and it
binds `""` (`listen unixgram : bind: invalid argument`). The real launcher
sites the socket under the short system `$TMPDIR`, which is outside the
repo boundary a worktree agent may write to.

So **boot with no `virtio-net` device and no gvproxy**. Nothing about the
mount phase needs the network: it runs before everything else, the getty
only `Wants=network-online.target` (not `Requires=`), and the two phases
that would hang are switched off from run.env with
`CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT=false` and
`CLAUDE_VM_PLUGINS_UPDATE_AT_BOOT=false`. Boot-to-probe took ~60s.

**Bump `LAUNCHER_LOGIC_REV` before boot-testing a launcher change, even
mid-PR.** The launcher's source is not covered by the image-identity hash
— the rev is the *only* cache invalidator — so an image built earlier on
the same branch silently keeps the old phase and the run measures nothing
(cf. [[getty-respawn-is-restart-not-dash]]). For a throwaway negative
control, set an obviously fake rev (`9024`) so its image can never be
mistaken for the real one.

**Negative-control the boot, not just the unit tests.** Building a second
image from the same tree with only the guard removed, and booting it with
the identical manifest, is what turns "the mount was skipped" into "the
check is what skipped it" — Linux stacking a mount over a non-empty
directory is exactly the kind of thing worth demonstrating rather than
asserting. It showed `/etc` really does get shadowed, and the boot then
failed somewhere unrelated (`/etc/apt/apt.conf.d/...: No such file or
directory`) with claude never starting.
