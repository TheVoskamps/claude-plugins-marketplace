---
name: podman-egress-probe-passes-vacuously
description: The documented `apt-get update -qq >/dev/null && echo OK` container-egress probe passes even with ZERO outbound TCP -- apt-get exits 0 on "W: Failed to fetch". Probe with /dev/tcp instead, and know that a live gvproxy is no evidence the machine has egress.
metadata:
  type: project
---

Corrects the egress-verification step in
[[claude-vm-real-build-and-boot-is-doable]]. That memory says to run

```bash
podman run --rm docker.io/library/debian:trixie \
  sh -c 'apt-get update -qq >/dev/null 2>&1 && echo OK || echo FAILED'
```

before concluding anything about your own diff. The intent is right; the probe
is **broken**. `apt-get update` exits **0** when every index fetch fails -- the
failures are `W:` warnings, not errors -- so the probe prints `OK` on a machine
with no outbound TCP at all. In issue #108 it printed `OK` twice (once
`--privileged`, matching the provisioner's own invocation) while the mkosi
build container failed on `Unable to connect to deb.debian.org:80`. That reads
exactly like "my probe says the network is fine, so the build failure is my
change" -- which is the wrong conclusion the probe existed to prevent.

**Probe the socket, not the package manager:**

```bash
podman run --rm docker.io/library/debian:trixie bash -c \
  'timeout 10 bash -c "echo > /dev/tcp/deb.debian.org/80" && echo OK || echo FAIL'
```

`bash`, not `sh` -- debian's `/bin/sh` is dash, which has no `/dev/tcp` and
reports the confusing `cannot create /dev/tcp/...: Directory nonexistent`, a
false FAIL that looks like a network verdict. Note also that macOS has no
`timeout`, so the same line run on the HOST is a false FAIL for a different
reason; use `curl --max-time` for the host leg.

**A live gvproxy proves nothing.** `podman machine start` succeeding, and
`ps` showing a fresh non-zombie gvproxy plus its vfkit, are both compatible
with containers having zero egress. DNS keeps working (it resolves through the
machine), so `getent hosts` is not a discriminator either. A stop/start cycle
did not repair it, and `podman machine stop` first failed with
`unable to clean up gvproxy: process has not ended` against a **zombie**
gvproxy from an earlier session.

Where that leaves you: a real claude-vm build+boot is simply unavailable on
that host until the human repairs the machine. Say so plainly, corroborate on
the guest's platform another way -- the sliced boot-launcher fragments run fine
in a cached `docker.io/library/debian:trixie` container, which is real
linux-arm64 GNU coreutils and is the right control for copy/mount semantics
(see [[claude-vm-guest-boot-probe-via-stub-claude]]) -- and restore the machine
to the state you found it in.
