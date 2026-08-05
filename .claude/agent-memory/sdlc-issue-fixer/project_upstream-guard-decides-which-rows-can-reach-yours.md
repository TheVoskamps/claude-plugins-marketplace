---
name: upstream-guard-decides-which-rows-can-reach-yours
description: A test row for a narrowed guard must be a command the UPSTREAM guard lets through — in the permission gate, only ghShieldingFlags values may be dynamic, and the field flags (-f/-F) shield only with a pinned `key=`, so most "dynamic + static path" rows die at the precondition instead
metadata:
  type: project
---

When a finding says "narrow guard G so case X stops escalating", every
row you write for X has to survive whatever runs BEFORE G. Pick the row
by reading the upstream guard's own table, not by picking a flag that
reads plausibly.

**Why:** on #232 the narrowing was "ask about the path tokens, not the
whole command", and the rows had to pair a static path with a dynamic
token. Two of the first three rows never reached the new code at all —
`gh gist create notes.md -d "$(date)"` and `… -f "$NAME"` both died on
the non-static-argv PRECONDITION, which is a different guard with a
different table:

- `ghShieldingFlags` (`classify_command.go`) is the ONLY set whose
  values may be dynamic: `-f`/`--raw-field`, `-F`/`--field`, `-q`/`--jq`,
  `-t`/`--template`, `-b`/`--body`, `--title`. Anything else (`-d`,
  `--desc`, `--notes`, …) denies on the precondition, so it can never
  demonstrate a downstream verdict.
- Of those, the FIELD flags (`-f`, `-F`) shield only when the value's
  `key=` is statically pinned (`valueTokenShieldable` → `fieldKeyPinned`),
  so a bare `-F "$X"` still denies. `--title`/`--body`/`-t` shield
  unconditionally.
- Consequence for `gh gist create`: it has no unconditionally-shielded
  flag at all, so the "static path + dynamic token" row is impossible on
  that verb. Use `pr create`/`pr comment`/`release create` instead.

**How to apply:** before writing rows for a narrowed guard, grep the
upstream guard's allowlist and pick tokens from it; then confirm at
binary level, because a row that dies upstream still *passes* a
`wantBucket(BucketDeny)` assertion for entirely the wrong reason. The
inverse is the useful contrast row: on a verb whose own tier ASKs
(`gh release create`), assert the reason string is the verb's tier
("publishes a release"), which proves the narrowed guard did NOT fire.

Related: [[negative-control-the-approved-snippet]],
[[verify-a-predicted-verdict-before-implementing-it]].
