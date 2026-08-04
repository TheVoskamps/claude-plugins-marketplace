---
name: entry-index-is-against-the-structure-the-gate-walks
description: an "entry #N" diagnostic numbers against the data structure the validator walks (usually a merged/normalized document), not the file the operator edits — so example-config prose saying "its position in this list" is false the moment tiers union; measure it with a two-tier fixture through the real merge and the real gate
metadata:
  type: project
---

A validator that emits `entry #N` counts through whatever it iterates.
That is almost never the file the operator has open: it is the merged,
normalized, defaulted document the loader built. When the config layers
(global + per-repo, base + override, defaults + user), the operator's
first entry can be reported as `#3`.

**Why:** the prose that documents such a gate gets written next to the
key it describes — in one tier's example file — so "naming the entry by
its position in this list" reads as obviously true while being wrong for
every operator whose other tier is non-empty. It is also unfalsifiable
by the test suite: the suites drive a single merged fixture, so the
number they assert on is right and the sentence about it is still wrong.
Nothing fails. (#226 round 5: `claude_vm_check_mounts` walks the merged
BOOT document; `payload/config-boot.example.yml` and
`skills/claude-vm/SKILL.md` both claimed a single-file position.)

**How to apply:** when a finding — or your own sweep — touches prose
about a numbered per-entry diagnostic, settle it by *driving* it, not by
reading the loop. Build a two-tier fixture (two entries in the global
file, the offending entry first in the repo file), source the real
library, run the real merge and then the real gate, and read the number
off the real message. That probe also settles the order question the
prose depends on: in claude-vm's merge, `unique` over `global ++ repo`
preserved insertion order (a `/zzz` global entry stayed ahead of an
`/aaa` one), so "counts through the global entries before the per-repo
ones" is safe to write — but that is a measured fact about this yq, not
a general one, so re-measure rather than reuse the sentence elsewhere.

Sweep the class both ways: grep the codebase for the other `entry #`
emitters and check each one's prose, and grep the docs for "position in
this list" / "in the list" wording. A sibling gate that already words it
correctly (here `claude_vm_check_marketplace_names`, which says "in the
merged ${tier} config") is the phrasing to converge on — matching an
existing correct sibling beats inventing new wording.

Related: [[shared-predicate-list-is-one-claim]] (the completeness half
of a scoped list), [[verify-a-predicted-verdict-before-implementing-it]]
(measure the row, don't trust the prediction),
[[slice-the-caller-to-prove-a-guard-is-wired]] (run the real gate
through the real caller).
