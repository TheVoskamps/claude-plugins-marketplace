---
name: sourcing-order-decides-who-wins
description: "X's value always wins" is a claim about SOURCING/ASSIGNMENT ORDER, not about ownership — read the consumer's line numbers before letting it stand, and expect it copied to every operator surface.
metadata:
  type: feedback
---

A sentence of the form "the launcher's value always wins, so a config
that fights it can never take effect" is settled by *where* each
assignment is read, not by who owns the name. Open the consumer and
compare line numbers before the sentence survives a pass.

**Why:** a gate can be right for a false reason, on every surface at
once, with nothing red. Such a rationale is restated on a library
header, its `echo` diagnostics, a call-site comment, the README, both
example configs, the skill and both config wizards — and a test that
matches only a diagnostic's first line never touches the rationale
line. Ownership of a name is not evidence about order; only the
consumer's read sequence is.

A reword sweep of the rationale is only half the fix. The *enumeration*
the rationale ranges over sits in the same sentence on those surfaces,
so an exception member named on one or two of them leaves the rest
asserting a set that is short by one and applying the majority
rationale to all of it. Fix the list and the reason together.

**How to apply:** when a doc says one writer beats another, grep the
consuming script for both assignments and order them. In `claude-vm`,
the boot launcher's read order and the one reserved name that really
is written after the env files are stated in `payload/README.md` —
read them there rather than reconstructing them. Related:
[[no-blanket-predicate-over-a-list]] — a rationale copied to N surfaces
is N claims, and fixing the obvious two looks complete.
