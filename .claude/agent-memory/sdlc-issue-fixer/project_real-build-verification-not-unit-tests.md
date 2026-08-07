---
name: real-build-verification-not-unit-tests
description: to catch bugs a full podman-mkosi build hits, stub only the blocking external command (podman) and let the real script run its real path — don't trust unit tests of pure helper functions
metadata:
  type: project
---

`plugins/claude-vm/payload/provisioners/podman-mkosi.sh` (issue #105 /
PR #161) shipped with 151 passing unit tests in `config-test.sh`, all
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

**Addendum (issue #106 PR #174, round 5)**: on this run's machine,
`podman` + `vfkit` + `tinyproxy` were actually present (only `gvproxy` was missing
from PATH, and `test/host-acceptance.sh` resolves it from podman's libexec
via `claude_vm_resolve_gvproxy`, not PATH) — so no stubbing was needed at
all; `bash plugins/claude-vm/payload/test/host-acceptance.sh` ran a fully
real build + real vfkit boot end-to-end and printed a per-criterion
pass/fail list. Don't assume a stub is required — check binary
availability first (`command -v podman vfkit gvproxy tinyproxy`) and just
run the real acceptance script if the host is equipped.

Separately, this round surfaced a sibling failure mode: the acceptance
**harness's own stub fixtures** can silently go stale when the product
code gains a new hard requirement (issue #104 added a settings.json
hard-abort to the boot launcher; `host-acceptance.sh`'s stub
`claudecreds` share was never updated to include one). The harness kept
exiting cleanly-looking but criterion (b) had actually been failing
since #104 landed — masked across multiple PR rounds because each round's
"real vfkit boot passed" claim in the PR body was taken at face value
without rerunning the harness. When a PR touches a build/boot surface
that has its own acceptance harness, sweep the harness's stub fixtures
for staleness against the product code's current hard requirements, not
just the product code itself — see
`plugins/claude-vm/payload/test/host-acceptance.sh` for the
concrete fixture-construction pattern that worked: mirror the real
launcher's own render function (e.g. `claude_vm_render_guest_settings`)
over a minimal merged-config stub, rather than hand-rolling a literal, so
the stub exercises the actual render path instead of drifting from it.

**Addendum (issue #157 PR #231, fix round): run it even for a
comment-only guest edit.** `build-guest-image.sh` emits the guest boot
launcher from a `cat <<'BOOT'` heredoc spanning ~1000 lines, so *any*
edit inside that range — a comment included — changes the script baked
into the image. Two cheap checks before the expensive one: extract the
heredoc body by line range and `bash -n` it, and confirm any constant
you touched still greps out of the extract. Then run
`payload/test/host-acceptance.sh`, which on an equipped host does a
genuinely real image build plus a real vfkit boot and printed 14/14
across criteria (a)–(d) in a few minutes. It exercises no `mounts:`, so
it does not verify a mount change — what it does verify is that the
launcher you emit still boots, which is exactly the risk a heredoc edit
carries (cf. [[backtick-comments-in-unquoted-heredocs]]; this heredoc is
quoted, so backticks in comments are literal — check the delimiter
before relying on that).

**Addendum (issue #157 PR #231, owner round): the harness's criteria are
the limit of what it verifies.** host-acceptance.sh attaches only the
four built-in shares and writes no `mounts.tsv`, so it cannot say
anything about a `mounts:` change. Reuse its criterion-(b) choreography
in a scratch script and add the missing pieces —
[[real-boot-that-exercises-mounts-from-a-worktree]] has the recipe, the
AF_UNIX/gvproxy blocker a worktree path hits, and the launcher-rev trap
that makes a boot-test measure a stale image.
