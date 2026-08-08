---
name: equivalence-by-sourcing-identity-by-text
description: Two renderers of the same value are compared by SOURCING both (spellings differ legitimately); a "nothing else changed" claim is compared by TEXT against the pre-change function
metadata:
  type: project
---

When a fix changes how a value is rendered, two different assertions are
needed, and swapping them wastes a round.

- **Cross-renderer equivalence → source both, compare the resulting bytes.**
  bash `printf %q` writes `$'a\nb\n'`; Python `shlex.quote` writes `'` + real
  newlines + `'`. Both are correct quoting of the same value, so a text
  comparison FAILs on a difference that does not exist. (PR #243: my first
  boot-vs-bake assertion failed exactly this way.) bash 3.2 vs bash 5 `%q` also
  disagree — 3.2 spells a space `a\ b`, 5 spells it `'a b'`.
- **"Every other value emits byte-identically" → compare the emitted TEXT
  against the pre-change function.** Sourcing cannot see this: it collapses
  the very spelling the claim is about. Extract the old function with
  `git show HEAD:<path> > scratch/old.sh`, run both through
  `bash -c '. "$1"; <fn> "$2"' _ <lib> <fixture>`, and `diff -u`. Cover int,
  bool, empty string and shell metacharacters in the one fixture. This is what
  lets a fix that was NOT re-verified by a real build/boot say honestly that
  the already-booted paths are untouched — see
  [[pick-the-fix-that-spares-the-expensive-verification]].

**Why:** a value-rendering fix has two obligations that pull in opposite
directions — the new case must change, and every old case must not — and each
needs the assertion the other one cannot make.

**How to apply:** any round that touches a quoting/escaping/capture helper.
Write both assertions plus a negative control that the pre-fix shape fails the
new one ([[negative-control-the-approved-snippet]]).
