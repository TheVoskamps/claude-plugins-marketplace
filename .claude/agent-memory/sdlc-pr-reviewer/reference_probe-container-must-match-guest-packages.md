---
name: probe-container-must-match-guest-packages
description: A claude-vm in-guest behavior probe is only valid in a container whose package set matches the guest image's mkosi Packages= list; a toolchain container hides missing guest deps — found the guest-side `claude plugin marketplace add/update` needs system git the guest doesn't bake (PR #212).
metadata:
  type: reference
---

A claude-vm PR's "verified against the real linux-arm64 CLI in a container"
claim does NOT transfer to the guest unless the container's package set
matches the guest image's. The guest's packages are the mkosi `Packages=`
list in `provisioners/podman-mkosi.sh` (`[Content]` section) — currently
systemd/udev/ca-certificates/curl/bash/iproute2/util-linux/apt and whatever
the bake config adds. The build container is much richer (line ~691 installs
`python3 ... git curl ca-certificates`), so a probe run there, or in any
container where a dependency was apt-installed, silently carries tools the
guest lacks.

The incident (PR #212, issue #107): `boot_plugin_phase` was verified in a
container with git; the guest bakes no git; the CLI spawns **system git**
for git-url marketplace operations, so in the real guest every
`claude plugin marketplace add`/`update` fails (fail-soft) and
`update_at_boot: true` is inert. Decisive probe, from a plain arm64
`debian:trixie` with the cached verified binary:

```bash
podman run --rm \
  -v ~/.config/claude-vm/cache/<ver>/linux-arm64/claude:/work/guest-claude:ro \
  -v <repo>/.claude/tmp/<slug>/probe.sh:/work/probe.sh:ro \
  docker.io/library/debian:trixie bash /work/probe.sh
```

with HOME=/root + DISABLE_AUTOUPDATER/TELEMETRY exports; the failure is
unambiguous: `Failed to clone marketplace repository: Command failed with
ERR_STREAM_PREMATURE_CLOSE: git ... clone --depth 1 ...` (a spawn failure,
not network). Note: the CLI can exit 0 on this failure — check
`plugin marketplace list` output, not the exit code.

Fingerprints that settle "does the CLI shell out or bundle it":
`~/.claude/plugins/marketplaces/<name>/.git/hooks/*.sample` present means a
real system-git clone (a JS git writes no sample hooks); the official
marketplace instead has `.gcs-sha` (tarball path, no git needed). Grading
guide: a missing guest dep behind a fail-soft phase still fails the issue's
acceptance criterion in the shipped artifact → High, and the fix precedent
is the `Packages=` list's own `apt` comment ("boot_apt_phase failing with
'apt-get: command not found' before this was added").

See also [[checkout-pr-branch-before-exercising]] and the podman-machine
start/stop etiquette in the issue-developer's
claude-vm-real-build-and-boot-is-doable memory (start it yourself, restore
the stopped state after).
