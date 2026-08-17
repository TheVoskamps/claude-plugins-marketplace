---
name: one-filesystem-harness-cannot-see-a-deref-drop
description: An off-VM harness running both sides of a host/guest seam on one filesystem cannot detect a dropped cp -L by reading content; assert the SHAPE of the intermediate (staged) artifact instead
metadata:
  type: project
---

A test that drives both halves of a producer/consumer seam over one local
filesystem **cannot** detect a dropped `-L` (dereference) on the producer's
copy by reading the consumer's content. A copied symlink still resolves
locally, so every `assert_file_is` on the consumer tree stays green while the
producer ships a link. What moves is only the **shape of the intermediate
artifact** the producer writes — the staged entry is a symlink instead of a
real directory.

**Why:** PR #273 (claude-vm #108) pinned `cp -RL` with
`assert_contains "$(cat "$HOST_FRAGMENT")" 'cp -RL'` — a string match on the
sliced source. Mutating `cp -RL` → `cp -R` yielded 43 passed / 1 failed, the
sole failure being that string check; all four behavioral symlink assertions
stayed green. The review graded it Medium: the control pinned a spelling, not
a property, so any respelling that preserved the string would pass.

**How to apply:**

- Assert the producer's own output where the drop shows up:
  `assert_real_dir "$CASE/creds/claude-home/rules"` — `[ -L ]` first, then
  `[ -d ]`, because `-d` follows symlinks and alone proves nothing.
- Retarget any slice-sanity `assert_contains` away from the flag under test
  (here: to `CLAUDE_HOME_SEED_DIR`), so the negative control demonstrates
  purely behavioral detection rather than two failures whose relative weight a
  reader has to judge.
- Negative-control by copying the whole payload tree into
  `.claude/tmp/<slug>/`, mutating the copy, and running the **copy's own**
  unmodified suite — the harness derives `PAYLOAD_DIR` from its own location,
  so it exercises the mutated source with no edit to the test.
- Run the control on both `cp` implementations that matter. Verified identical
  on macOS BSD `cp` (bash 3.2) and in `debian:trixie` aarch64 GNU coreutils
  (`podman run --user 1000`, bash 5.2.37): red on exactly the two staged-shape
  assertions, 46/46 unmutated.
- Say in the prose *why* content cannot see it — in the real VM the drop is
  fatal (the link target sits outside the shared dir), which is precisely what
  the one-filesystem harness cannot reproduce. Related:
  [[negative-control-the-approved-snippet]],
  [[delete-the-named-mechanism-to-grade-the-prose]].
