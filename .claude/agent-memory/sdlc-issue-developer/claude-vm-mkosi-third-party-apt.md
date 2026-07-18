---
name: claude-vm-mkosi-third-party-apt
description: In claude-vm's podman-mkosi provisioner, third-party apt repos for BUILD-TIME package installs go in the mkosi SANDBOX tree (mkosi.sandbox/etc/apt/...), and signed-by must be the runtime path (/etc/apt/keyrings), not the staging path.
metadata:
  type: project
---

claude-vm's guest image is built by mkosi inside a throwaway podman
container (`payload/provisioners/podman-mkosi.sh`). To make a
third-party apt repo (e.g. `gh` from cli.github.com) installable at
IMAGE-BUILD time, the repo's `sources.list.d` entry + keyring must go in
the mkosi **SandboxTree**, NOT `mkosi.extra` (SkeletonTree).

**Why:** mkosi invokes apt from OUTSIDE the target image and reads
package-manager config from the sandbox tree's canonical `/etc`
locations. Files placed via `mkosi.extra`/`SkeletonTrees=` land in the
built rootfs but are NOT seen by the apt mkosi runs to install packages
(confirmed in mkosi v26 man page: "To add extra package manager
configuration files such as extra repositories, use SandboxTrees="). The
convention `mkosi.sandbox/` in the recipe dir is auto-used as a
SandboxTree rooted at `/`.

**How to apply:** write keyrings to
`recipe/mkosi.sandbox/etc/apt/keyrings/<name>.asc` and sources to
`recipe/mkosi.sandbox/etc/apt/sources.list.d/<name>.list`. CRITICAL: the
`[signed-by=...]` path baked into the source line must be the RUNTIME
path apt sees (`/etc/apt/keyrings/<name>.asc`), NOT the staging path
(`/work/recipe/mkosi.sandbox/etc/apt/keyrings/...`) — the sandbox tree is
mounted at `/` for the build, so the staging path won't exist at apt
runtime. The `render_apt_source` helper (issue #105) takes both a
write-dir and a separate runtime-keyring-dir arg for exactly this; the
boot-install slice (#106) will pass the same value for both (write ==
runtime == live `/etc/apt`).
