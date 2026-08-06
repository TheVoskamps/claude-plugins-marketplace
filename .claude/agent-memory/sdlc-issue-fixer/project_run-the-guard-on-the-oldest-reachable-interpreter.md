---
name: run-the-guard-on-the-oldest-reachable-interpreter
description: A guard that runs EARLY can fail open on an old interpreter while the file's later bash-4 constructs fail loudly — measure the guard itself under the oldest shell that can reach it, not the file's declared floor
metadata:
  type: project
---

When a fix lands in a **security guard**, run that guard under the
oldest interpreter that can physically reach it — not the one the
file's other code implies is required.

**Why:** on claude-vm PR #231 I collapsed `.` segments in
`claude_vm_mount_guest_path` and the suite went green under the PATH
bash (5.3). Under `/bin/bash` (3.2, what macOS still ships) the same
input was *accepted*. Root cause: a backslash-escaped slash in the
**replacement** half of `${var//pattern/replacement}` is
version-dependent — bash >= 4.3 unescapes `\/` to `/`, bash 3.2 leaves
the backslash in. With the literals written inline, `${path//\/\//\/}`
turned `/mnt/repo/` into `/mnt/repo\` and `/./etc` into `\/etc` there,
silently defeating the entire normalization and every guard built on
its output. The pre-existing `//` pass had shipped with the same
defect. Holding the `/`, `//` and `/./` literals in **variables** makes
both shells agree, because a variable expands to a plain `/` with no
escape to interpret.

The trap is the "it already needs bash 4" reflex. `lib/config.sh` does
— `local -A` in `claude_vm_render_guest_settings` — so it is tempting
to call 3.2 unreachable. But that construct fails **loudly and much
later** in the launch, long after `claude_vm_check_mounts` has already
decided whether a mount is safe. Ordering decides reachability: a
guard on the early path can fail *open* on the way to somebody else's
error. The same run found the sibling gotcha — bash 3.2 under `set -u`
treats a bare `"${arr[@]}"` on an **empty** array as an unbound
variable and kills the script, so a new array needs
`${arr[@]+"${arr[@]}"}`.

**How to apply:** when the fix is in a validator, a permission gate, a
path normalizer or anything else whose job is to say no, (1) find the
oldest interpreter actually on the box (`/bin/bash` vs `command -v
bash` differ on macOS), (2) run the *real function* under it, not a
transcription, and (3) pin it with a **self-skipping live test** that
sources the lib under whatever old interpreter the host has and skips
where there is none — plus a negative control proving the hazardous
spelling still differs there, so the test retires itself honestly when
the hazard is gone. A fixture cannot substitute: it would only restate
the belief that the two shells agree. Related:
[[pin-a-specs-empirical-premise-with-a-live-test]],
[[negative-control-the-approved-snippet]],
[[real-build-verification-not-unit-tests]].
