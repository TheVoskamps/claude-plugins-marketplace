---
name: declaration-vs-state-sweep-is-two-sided
description: a "this prose describes the state, but the code tests the declaration" sweep is not find-and-replace — some hits are genuinely state-testing and must KEEP the state framing, with the ambiguous word swapped toward state, not toward declaration
metadata:
  type: project
---

PR #228 (issue #226) spent three review rounds on one prose class, one
instance-set per round, before the reviewer demanded a terminal sweep.
The class: comments describing a host-side gate
(`claude_vm_boot_marketplace_egress_needed`) by the image state it
approximates ("not already baked into the image") when it actually
tests membership in a bake **declaration**, deliberately conservatively
because the host cannot know whether the build's best-effort add
succeeded.

**Why the sweep is not a find-and-replace.** The ambiguous word
("baked") appears on both sides of the very distinction being fixed:

- **Declaration side** — the host-side gate. Fix by naming the
  declaration ("bake-declared", "not ALSO declared in config-bake.yml")
  and stating why it is conservative.
- **State side** — the guest's own boot phase, which genuinely asks the
  CLI what is registered. That framing is *correct* and must survive.
  But its prose used the same declaration word for a state fact ("a
  baked marketplace is already registered"), so the fix there is the
  mirror image: swap toward the explicit **state** word ("already
  registered in the image"), and say which of the two the step reads.
- **Unrelated-but-identical phrase** — a sibling subsystem (apt
  packages/apt_sources) carried the byte-identical phrase "hard-secure
  all-baked config" in eight places. Not in the class: reading its gate
  showed it has **no membership test at all**, only boot-knob reads, so
  there is no declaration/state confusion to fix. Editing those would
  have been pure churn.

**How to apply.** Grade every phrase-family hit by *reading the gate
the sentence describes*, not by the phrase. Three verdicts, not one:
reword-to-declaration, reword-to-explicit-state, leave alone. Report
the leave-alones with the reason, so the next reviewer can see they
were graded rather than missed, and report the grep patterns so the
sweep is replayable. Patterns that found everything here:
`(everything|all|already|not)[ -]+baked|baked into|inside the image|is baked|all-baked`,
`already (registered|present|carr)|(does not|doesn't) carry|guaranteed to carry|image carries`,
`hard.secure|derives (nothing|NOTHING)`, plus the identifier names
themselves.

**A sweep round writes new prose, so the new prose needs verifying
too.** Fixing the state-side comment, I wrote "this is the ONE path
that reads the IMAGE" — false: the same function's step 4 also queries
`claude plugin list`. Caught by reading the function before pushing.
Structural absolutes ("the one", "all three", "the only caller") are
the highest-yield thing to re-check in your own fix, and a prose-sweep
round is full of them by construction. See
[[shared-predicate-list-is-one-claim]] and
[[audit-a-prose-sweep-by-added-words]] — this hit is exactly that
memory's "the sweep ADDED words" hunk class. Sweep-scope lore lives in
[[sweep-sibling-agent-guards]].
