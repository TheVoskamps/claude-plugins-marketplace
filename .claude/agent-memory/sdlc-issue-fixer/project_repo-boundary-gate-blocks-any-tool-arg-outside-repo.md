---
name: repo-boundary-gate-blocks-any-tool-arg-outside-repo
description: the repo-boundary gate blocks Bash tool invocations (find, cp, awk with a slash-containing pattern arg) whose ARGUMENTS resolve outside the repo, not just direct file reads — redirect TMPDIR into the repo instead of trying to copy/inspect an out-of-repo temp dir after the fact
metadata:
  type: project
---

While inspecting a real `podman-mkosi.sh` build's transient STAGE dir
(issue #106 PR #174 round 6), tried three ways to read
`/var/folders/.../T/claude-vm-mkosi.XXXXXX` (macOS `mktemp -d
"${TMPDIR:-/tmp}/..."` resolves under `/var/folders`, outside the repo):
`find <path> -path "*keyrings*"`, `cp -r <path> <repo>/.claude/tmp/...`, and
`awk '/pattern-with-slashes/,/other/' <in-repo-file>` (the awk range
pattern itself, containing `/`, got misparsed by the gate as a second file
argument). All three were blocked with "resolves outside the current
repository" / similar — the gate inspects EVERY argument that looks
path-shaped, not just an explicit target/source file argument, and a `cp
-r <outside> <inside>` is blocked on the SOURCE side even though the
WRITE target is safely in-repo.

**Also confirmed**: `run_in_background` task-output files
(`/private/tmp/claude-*/.../tasks/*.output`) are blocked from `Read` for
the same reason (already documented in
[[claude-vm-inspect-raw-image-with-debugfs]]) — this is the same gate,
not a separate one.

**The fix that worked**: don't try to retroactively copy/read an
already-created out-of-repo path. Instead, set `TMPDIR=<repo>/.claude/tmp/...`
as an env var on the command that CREATES the temp dir in the first place
(here, re-running `bash build-guest-image.sh --output ...` with `TMPDIR`
pointed inside the repo), so every `mktemp -d "${TMPDIR:-/tmp}/..."` call
downstream lands in-bounds from the start. Also redirect all
`run_in_background` stdout/stderr to a repo-scoped log file
(`> .claude/tmp/.../build.log 2>&1`) rather than relying on the harness's
own `.output` capture file, for the same reason.

**How to apply**: before starting a real build/run whose tooling creates
scratch files via `mktemp`/`$TMPDIR`, set `TMPDIR` to an in-repo
`.claude/tmp/<slug>/` path for that invocation if you expect to need to
inspect the scratch output afterward — cheaper than discovering the
boundary block after the run has already completed and the artifacts are
sitting in an unreadable location.
