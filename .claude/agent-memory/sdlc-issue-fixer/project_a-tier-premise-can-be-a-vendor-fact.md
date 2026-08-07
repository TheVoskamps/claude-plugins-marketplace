---
name: a-tier-premise-can-be-a-vendor-fact
description: When a classifier tier rests on "this form is the safe/sanctioned one", that premise is usually a claim about the VENDOR's product, not about the code — check it against the vendor's own docs and quote them; and when the fix makes a branch unconditional, delete the screen that decided it rather than reusing it for message wording.
metadata:
  type: project
---

A gate tier that carves one form out as safe ("a default gist is
secret", "a draft release is not published") rests on a claim about the
third-party product, which no amount of reading the repo can settle.
Check it at the vendor's docs and QUOTE them in the message, so the next
reader can re-grade the premise without re-deriving it.

**Why:** on #232 the gate allowed `gh gist create <file>` outright
because "a gist created without the flag is secret". GitHub's own docs
say a secret gist stays out of Discover and out of search but that "if
someone you don't know discovers the URL, they'll also be able to see
your gist" — unlisted, not private. So the ALLOW published a readable
copy of any contained repo file to a durable URL. Containment could
never have caught it: containment bounds WHICH file, and a contained
file is exactly where "the bytes stay on the machine" fails.

Two follow-ons, both of which cost real work if missed:

- **A screen that decided a branch you are making unconditional is
  dead, not repurposable.** The obvious next move is to keep the
  `--public` walk to sharpen the ask's wording. It cannot: the walk
  reported the flag being NAMED, not the value it carried, so it would
  describe `--public=false` — a genuinely secret gist — as a public one.
  Delete it with its tests and put both cases in one message. A
  predicate built for a fail-safe over-ask is the wrong instrument for
  prose that has to be true.
- **Negative-control a structural escalation as a PAIR.** Removing the
  arm must fail loudly (58 assertions across 8 tests) *and* restoring
  the old table entry — `"create": true` back in
  `ghRecoverableWriteVerbs` — must fail NOTHING. The second is what
  proves the ask comes from the arm above `isGhRecoverableWrite` rather
  than from the table edit, so a later re-add cannot silently restore
  the allow. Assert the ask's REASON in every row too: dropping a verb
  from an allow table alone lands it on the fail-closed floor, which is
  the same bucket for an entirely different reason.

**How to apply:** on any finding that overturns a "this form is the
sanctioned one" premise. Grep the PREMISE across the tree — tier-summary
doc comments, the table entry's own comment, the README paragraph, the
rules/*.md sibling and every `.claude/agent-memory/` subdirectory — not
the table entry the finding named; see
[[new-arm-falsifies-the-formula-back-references]]. Expect the sweep to
turn up a measured COUNT that the change re-composes without changing
its total ([[a-parity-fix-moves-verdicts-in-every-direction]]).
