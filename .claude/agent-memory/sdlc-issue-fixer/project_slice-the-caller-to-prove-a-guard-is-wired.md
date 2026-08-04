---
name: slice-the-caller-to-prove-a-guard-is-wired
description: A test that calls a new abort-guard directly proves only that the guard returns non-zero; slice the CALLER's own gate block out by line range and run the fixture through it, so "the launch aborts" is measured rather than assumed
metadata:
  type: project
---

A new validator has two separable claims: *it rejects the bad input*, and *the
program actually asks it*. A unit test that invokes the helper proves only the
first. The second is the one that silently regresses — a guard can be written,
tested, and never wired in, or wired in after the code that already consumed
the bad value.

**How to settle it in claude-vm.** The launcher's config-load gates sit as
bare top-level code in `payload/claude-vm.sh` (merge both tiers, then a run of
`claude_vm_check_*` calls, each with its own abort message). Slice that block
by line range with `grep -nF` on a distinctive first and last line, wrap it in
a harness that sources `lib/config.sh` and sets `GLOBAL_/REPO_ BAKE/BOOT
_CONFIG` from `$1..$4`, append an `echo GATE-OK`, and run it under
`TMPDIR="$WORK"` so the block's own `claude_vm_mktemp` files land where the
suite's trap cleans up. Assert on `"<rc>|<stdout+stderr>"`. The fixture then
travels the real merge and the real gate order, and a gate that is never
called shows up as `0|GATE-OK`. This is the same line-range extraction the
suite already uses for `boot_apt_phase`, `boot_plugin_phase` and the
extra-mount loop; the gate block is just a bigger slice.

**Always include the passing cases.** On PR #228 the two that mattered were a
config declaring neither key (which caught a real bug: yq prints ONE EMPTY
LINE, not zero bytes, for an empty result set, so the first draft of both new
gates rejected every ordinary config) and a well-formed one. Without them a
gate that rejects everything looks perfect. Related:
[[old-code-claim-hits-a-different-guard]] and
[[real-build-verification-not-unit-tests]] (same instinct — exercise the
artifact the program really runs, not a restatement of it).
