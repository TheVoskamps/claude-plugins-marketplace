---
name: apt-get-clean-verified-behavior
description: empirically verified (real Debian container, docker-clean helper config removed) exactly what `apt-get clean` deletes and does not delete -- relevant to any claude-vm or Debian-guest disk-bloat fix
metadata:
  type: project
---

Verified with `podman run --rm debian:bookworm bash -c '...'`, after
`rm -f /etc/apt/apt.conf.d/docker-clean` (the stock `debian:bookworm`
Docker image ships a `docker-clean` apt.conf.d drop-in that already
disables `pkgcache.bin`/`srcpkgcache.bin` via
`Dir::Cache::pkgcache/srcpkgcache ""` — without removing it first, a test
of native apt behavior is actually testing Docker's helper config and
gives a false negative for "does clean remove the .bin files").

Native `apt-get clean` (no `Dir::Cache::pkgcache` override in effect):

- Deletes every fetched `.deb` under `/var/cache/apt/archives/`.
- Deletes `/var/cache/apt/pkgcache.bin` AND `/var/cache/apt/srcpkgcache.bin`
  (36 MB each in the test run — these regenerate on EVERY subsequent
  apt-get invocation, including a bare `apt-get autoclean`, so `clean`
  must be the LAST apt-get call in a sequence to actually leave the
  working set trimmed).
- Does **NOT** touch `/var/lib/apt/lists` (verified: 19M before and after)
  — that's the package-index data a subsequent `apt-get install` needs to
  resolve packages without a fresh `update`; it must survive.

Used to justify issue #106's `boot_apt_phase` ending with `apt-get clean`
(payload/build-guest-image.sh) instead of guessing from training-data
priors about what `clean` does — see [[mkosi-v26-source-verification-technique]]
for the sibling "verify, don't recall" pattern applied to mkosi itself in
the same PR.
