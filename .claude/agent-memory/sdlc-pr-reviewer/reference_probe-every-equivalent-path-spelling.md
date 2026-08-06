---
name: probe-every-equivalent-path-spelling
description: A guard that compares NORMALIZED path strings is only as strong as its normalizer AND as the set of inputs feeding it — probe //, trailing /, `.`, `..`, and every OTHER config value that becomes a path component
metadata:
  type: reference
---

When a validator decides "does this path collide with a protected one?" by a
string relation over a normalized path, the guard's real boundary is the
normalizer, not the relation. Enumerate the spellings that name the same
directory and run **each one** through the real function:

- `//a//b` (repeated separators)
- `/a/b/` (trailing separator)
- `/./a/b` and `/a/./b` (a `.` segment — before *and* after the protected
  component; they behave differently, because the protected component is
  matched as a prefix)
- `/a/../b` (a `..` segment)
- a prefix-but-not-component match (`/a/bfoo` vs `/a/b`) as the
  must-still-pass control

**Why:** PR #231 (claude-vm extra mounts) normalized `//` and trailing `/`
and explicitly *rejected* `..`, with a README paragraph explaining that the
normalization is "load-bearing rather than cosmetic". `.` was the one member
of the class left open, so `path: /./etc` and `path: /./etc/ld.so.preload`
passed a guard whose whole purpose was to stop an extra mount landing on a
guest OS path. Two rounds of review, a 52-case suite and a real guest boot had
not covered it.

**How to apply:** also ask what the *runtime* does with the un-normalized
string. A host-side guard compares strings; the kernel on the other side
**resolves** them. On #231 that asymmetry cut both ways — the guest's
"is this directory non-empty?" backstop resolved `/./etc` and caught the
directory shape, while the same resolution made the single-file shape worse
(the target under the resolved system path did not exist, so the occupancy
check found nothing and the bind went through). Grade the finding on the leg
with no backstop. Related: [[fix-round-patches-named-files-not-the-class]].

**The guarded string usually has more than one input — enumerate them, not
just the spellings of one.** After #231 round 3 closed the `.` hole in the
normalizer, round 4 found the same class entering through the *other* input:
the effective mountpoint is `path:` when set, **else** `<root>/<tag>`, and the
`..` rejection sat inside `if [ -n "$path" ]`, so a tag-derived default never
reached it. Worse, the tag was ALSO a path component in two places the guard
never looked at (a host-side wrap dir, a guest-side wrap mountpoint), so
`tag: ".."` walked up out of both — with an explicit clean `path:` the gpath
check cannot help at all. Before accepting a normalizer as the boundary, grep
for every construction of a guarded path (`"$X/$y"`, defaults, fallbacks) and
ask which config value lands in each slot; a value validated only as a
*charset* (here `[A-Za-z0-9._-]`, which admits `.` and `..`) is not validated
as a path component.
