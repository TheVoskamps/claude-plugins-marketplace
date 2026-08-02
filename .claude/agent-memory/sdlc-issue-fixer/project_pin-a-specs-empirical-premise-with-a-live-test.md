---
name: pin-a-specs-empirical-premise-with-a-live-test
description: When an issue's spec encodes a SHAPE for paths some external system provisions, its "observed layout" claim is an empirical premise you can falsify in one `ls` — and the fix is a self-skipping test that walks the real directories, not a better fixture.
metadata:
  type: project
---

An issue's authoritative Design section can carry a factual premise
("observed layout across 17 projects on two machines") that is simply
wrong. Implementing it faithfully still ships the defect, and the
review round that catches it costs a full cycle.

**Why:** on #193 / PR #208 the spec prescribed a session-slug pattern
admitting only single dashes. One `ls /tmp/claude-$(id -u)/` showed
real session directories with doubled dashes (the harness rewrites
every non-alphanumeric cwd character, so a hidden directory yields
`--`). Fixtures could never catch it: a fixture only restates the
author's belief about the layout, which is the very thing that was
wrong. A second, richer set of fixtures would have restated it again.

**How to apply:** whenever a change encodes a regexp/shape/glob for
paths some *other* system creates — harness scratchpads, cache trees,
build outputs, tool-managed directories —

1. List the live surface before writing the pattern, and treat the
   issue's empirical claim as unverified until you have.
2. Add a test that walks the real tree and asserts every existing
   instance matches the shipped shape, skipping cleanly when the tree
   is absent or empty (`t.Skipf`). It costs nothing on a machine
   without ground truth and is the only thing that notices when the
   external system's layout drifts later.
3. Negate-check it: revert the shape to the old one and confirm the
   live walk names actual directories in the failure output.

`TestHarnessShapesMatchLiveLayout_193` in the guardrails
permission-gate is the worked example — it found 187 real session
subdirectories. Note the corollary for scope: a shape miss must cost a
DEFER rather than a denial, or a premise this fragile could not be
shipped at all.

Related: [[permission-gate-read-only-utility-allow-hides-carve-outs]]
(the other way a permission-gate test passes without testing
anything), and the pr-reviewer's `harness-slugs-can-double-dash`.
