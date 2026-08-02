---
name: podman-platform-flag-required
description: podman run without --platform can silently emulate the cached image's arch (amd64) with only a WARNING line, so an "arm64 probe" exercises the WRONG committed binary; always pass --platform linux/arm64 and confirm uname -m
metadata:
  type: reference
---

Verifying a `linux-arm64` artifact (PR #217's committed
`permission-gate` binary) in a podman container on this host: the
*cached* `docker.io/library/debian:trixie` image was **linux/amd64**,
and `podman run` without `--platform` used it under emulation, printing
only one warning line:

```text
WARNING: image platform (linux/amd64) does not match the expected
platform (linux/arm64)
```

The probe then "succeeded" — because the `uname`-keyed selector in
`hooks.json` resolved `linux-amd64` and ran the *amd64* binary. A
passing probe that silently verified the wrong platform's binary is the
exact hallucinated-verification failure a reviewer exists to catch.

**How to apply:** for any platform-specific probe, always pass
`--platform linux/arm64` (podman pulls the right variant if the cache
has the wrong one — network permitting) and prove the platform inside
the run with `uname -m` (`aarch64`) before trusting the result. Treat
that WARNING line as "this probe is invalid", not noise. Related:
[[probe-container-must-match-guest-packages]] (same probe-validity
class, package axis instead of arch axis).
