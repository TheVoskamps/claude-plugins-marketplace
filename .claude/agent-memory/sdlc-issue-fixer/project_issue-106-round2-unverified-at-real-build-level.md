---
name: issue-106-round2-unverified-at-real-build-level
description: PR 174 (issue #106) round-2 fix (mid-session apt proxy, apt diet, root-headroom mkosi.repart) was verified only at unit/mock level -- no real mkosi image build was run in this pass; flags specific residual risk for whoever does the real boot
metadata:
  type: project
---

Unlike the round-1 fixer on this same PR (see
[[claude-vm-inspect-raw-image-with-debugfs]] /
[[claude-vm-mkosi-installs-from-outside-image]], which built a REAL image
and inspected it with debugfs), the round-2 fix on PR 174 / issue #106 was
verified only via: `bash -n` syntax checks, the existing podman-mkosi-test.sh
mock-podman-stub harness (captures the staged mkosi recipe tree and asserts
on file contents, but never actually runs mkosi), and out-of-band research
against mkosi's real Python source (see
[[mkosi-v26-source-verification-technique]]) and a real Debian container for
`apt-get clean` semantics (see [[apt-get-clean-verified-behavior]]).

**What is NOT verified end-to-end and should be checked on the next real
boot:**

- The custom `mkosi.repart/00-esp.conf` + `10-root.conf` pair actually
  produces a bootable image at all — this is the highest-risk change in the
  round (first time this recipe supplies its own repart definitions; a
  malformed `SizeMinBytes=` unit or a subtly wrong ESP replica could break
  `mkosi build` in a way no unit test catches).
- The `mkosi.skeleton/etc/apt/sources.list.d/<suite>.sources` file actually
  pre-empts mkosi's own write as claimed — this rests on reading
  `install_apt_sources()`'s `if not sources.exists()` check and skeleton's
  copy-before-package-manager ordering in the mkosi source, not on watching
  it happen in a real build.
- `SizeMinBytes=1924M` (default: 900 MB estimate + 1024 MB headroom) is
  actually big enough / not wastefully big once the apt-diet's real effect
  on baked image size is known — `BASE_ESTIMATE_MB=900` is a static guess
  from the round-1 evidence ("guest.raw ~1.5G total, ~850M root content"),
  not a re-measurement after this round's own diet changes shrank the
  image.
- The persistent `/etc/apt/apt.conf.d/99claude-vm-proxy` drop-in and the
  lowercase `http_proxy`/`https_proxy` run.env additions genuinely fix the
  reported mid-session `apt-get install` failure — the human's original
  finding was reproduced on real hardware; the fix has NOT been
  re-verified on real hardware in this round.

If a future fixer/reviewer lands on this PR again, prioritize a real
`payload/build-guest-image.sh --output guest.raw` build + debugfs
inspection (per [[claude-vm-inspect-raw-image-with-debugfs]]) over trusting
the mock harness's captured-recipe assertions for the repart/skeleton
pieces specifically — those are the parts a stub can't catch a mkosi-level
failure in.
