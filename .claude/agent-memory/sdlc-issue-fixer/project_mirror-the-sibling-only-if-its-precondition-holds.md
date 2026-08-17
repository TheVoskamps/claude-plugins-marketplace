---
name: mirror-the-sibling-only-if-its-precondition-holds
description: "'Do what the other side already does' is a recommendation about a sibling whose destination it solely owns; check that ownership on your side before copying its rm -rf, or the fix deletes bytes your layer never wrote"
metadata:
  type: project
---

When a finding's remedy is "mirror the sibling — the host side already
does this", the sibling's code carries an unstated **precondition**,
and the fix is only correct where that precondition also holds. The
most common one is *sole ownership of the destination*.

**Why:** on PR #273 the guest-side working-rules install left a
half-copied tree on a failed `cp -R`, and the finding quoted the host
staging loop, which does `rm -rf "$dst"` on failure, as the shape to
copy. It is right there: the host stages into a fresh
`$CREDS_DIR/claude-home/` it created this launch, so removing an entry
removes exactly what it wrote. The guest's destination is
`$HOME/.claude/`, and the whole feature is an **additive merge** into
the image's baked `~/.claude` — an unconditional `rm -rf` would have
deleted baked `plugins/`, or any future baked `rules/`/`skills/`
content, on a copy error. The verbatim mirror would have shipped a
worse defect than the one it fixed, and the seed suite would have
stayed green, because nothing asserted the baked content survives a
*failed* copy.

**How to apply:** before copying a sibling's cleanup, ask what the
sibling owns that you do not. Where the precondition holds only
sometimes, condition the remedy on it and measure it (`[ -e "$dst" ]`
*before* the copy, so "did this run create it?" is answerable
afterward), then pin both arms — the removal AND the non-removal — with
a test whose non-removal case would fail under the unconditional
mirror. Say plainly in the code comment and in the PR body which case
the guarantee does not cover, rather than restating the sibling's
absolute wording. Related: [[the-absolute-half-of-a-standing-claim]],
[[negative-control-the-approved-snippet]].
