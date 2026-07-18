---
name: real-build-verification-not-unit-tests
description: to catch bugs a full podman-mkosi build hits, stub only the blocking external command (podman) and let the real script run its real path — don't trust unit tests of pure helper functions
metadata:
  type: project
---

`plugins/claude-vm/payload/provisioners/podman-mkosi.sh` (issue #105 / PR
#161) shipped with 151 passing unit tests in `config-test.sh`, all
exercising pure functions in `payload/lib/config.sh` (bake-hash
canonicalization, variant-path derivation, etc.). None of them render or
execute the actual generated `mkosi.conf` / `build-in-container.sh`
artifacts the provisioner writes. A real end-to-end build on a real podman
machine hit three failures the unit tests never had a chance to catch —
see [[backtick-comments-in-unquoted-heredocs]] for two of them, and a
missing `curl`/`ca-certificates` in the build-container apt-get install
list for the third.

**Technique that worked**: write a `podman` stub (in a repo-local
`.claude/tmp/<slug>/bin/podman`, prepended to `PATH`) that answers `info`
with exit 0 (passes the preflight) and, on `run`, captures the bind-mount
source paths (`-v <src>:/work/recipe`, `-v
<src>:/work/build-in-container.sh:ro`) by pattern-matching the arg list,
copies them out, then exits nonzero. This lets the REAL provisioner script
run to completion on the real host code path — every `mkdir`, every
heredoc, every `install`, every `cp` — with no podman machine required,
right up to the point it would hand off to the container. Then inspect the
captured, actually-generated `mkosi.conf` and `build-in-container.sh` for
literal content, and/or `bash -x` the whole run and grep the trace for
unexpected command executions.

**Regression-test structure that followed from this**: the new
`plugins/claude-vm/payload/test/podman-mkosi-test.sh` uses the exact same
stub technique as a permanent test, asserting on the generated files'
literal content (`grep -c` for exact line counts, not just substring
presence — a corrupted-but-still-substring-matching line can pass a naive
`grep -qF` check). Proved the test was a real regression test (not a
tautology) by running it against the pre-fix commit via `git stash` and
confirming 5 of 13 assertions failed there.

**How to apply**: when a PR review brief reports a *real build failure*
(not a static-review finding) in any script that shells out to an external
tool (podman, docker, aws, kubectl, ...) and orchestrates file generation,
don't declare the fix verified on unit-test-of-helpers strength alone.
Stub the one external command that would otherwise block/require
infrastructure the sandbox doesn't have, and let the rest of the real
script execute for real. This generalizes past claude-vm to any
provisioner/build script in this repo.
