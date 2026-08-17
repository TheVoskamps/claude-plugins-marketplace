---
name: run-the-guard-on-the-oldest-reachable-interpreter
description: Measure the real function under the oldest shell that can reach it — a guard can fail open there, and a "it already needs bash 4 anyway" carve-out is never safe; grade the resulting FAILs by reading what each label names, since a matching label diff licenses investigation, not a baseline
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

The trap is the "it already needs bash 4" reflex. `lib/config.sh` did
— `local -A` in `claude_vm_render_guest_settings` — which made 3.2 look
unreachable for the file as a whole. **That reflex was wrong twice, as
issue #108 proved: the construct is gone and nothing in the file
needs bash 4 now.** It never failed "loudly and only late": 3.2 prints
`local: -A: invalid option` and keeps going, and the
`map["$ref"]=` assignment under it is mis-parsed *silently* — an
indexed subscript is evaluated arithmetically, so a plugin ref like
`block-background-agents@thevoskamps` dies on `set -u`. "Late" meant
after the image build, i.e. the launch was already paid for. Ordering
still decides reachability — a guard on the early path can fail *open*
on the way to somebody else's error — but never accept a bash-4
construct anywhere the launcher reaches. The same run found the sibling
gotcha — bash 3.2 under `set -u`
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
the belief that the two shells agree.

**Then grade the failures the old shell hands you — by label, not by
count.** Running the whole suite there produces a wall of FAILs, and
"N of those are pre-existing" is a claim to measure rather than accept
from a report. Extract both comparison trees and diff the FAIL *labels*:
`git archive -o <tar> origin/main plugins/<plugin>/payload`, a second
archive of the pre-fix `HEAD`, untar each, and run the suite from inside
the extracted tree — claude-vm's suites resolve their lib through
`BASH_SOURCE`, so a single extracted file cannot run on its own. Round 7
of PR #231 got 465/17 pre-fix, 467/15 after, 278/15 at `origin/main`,
with the surviving 15 labels byte-identical to main's, which is what
turns "I fixed two and introduced none" into a measurement. Counts alone
would have misled: the 3.2 run totals 482 where bash 5.3 totals 483,
because one assertion inside the bash-4 `local -A` block simply never
executes there — a gap that also exists at `origin/main`, and only the
label diff shows it rather than leaving an unexplained off-by-one.
Sweeping such a class also wants a parser, not a grep: the shape is
"a `)` inside a `$( )` body that closes nothing", and its two ends are
often on different lines.

**But a matching label diff is a licence to investigate, not to keep
the failures.** That is exactly how #108's blocker survived: PR #231
established the surviving 15 as "identical to main's" and every later
round carried "568 passed / 15 failed" as a baseline, when those 15
*were* the render dying on 3.2 — a hard launch abort for any config
with a `claude.plugins.enabled` override. Read what a persistent FAIL
label names before baselining it; a whole named function failing on the
interpreter the product actually ships on is a blocker wearing a
baseline's clothes. The suite is now 584/0 on `/bin/bash` (the 584th
assertion is the one that never ran), and 570/0 in a `debian:trixie`
container under bash 5.2 both before and after the fix — the old-bash
batteries skip there, which is the whole 14-assertion difference.

Related: [[pin-a-specs-empirical-premise-with-a-live-test]],
[[negative-control-the-approved-snippet]],
[[real-build-verification-not-unit-tests]],
[[old-code-claim-hits-a-different-guard]].
