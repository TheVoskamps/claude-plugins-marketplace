---
name: adding-a-clause-to-siblings-falsifies-the-sweep-rule
description: A finding that says "add clause X to surfaces B and C" silently falsifies the CLAUDE.md sweep rule that says only surface A carries X — re-read the rule after the sibling edit, not before
metadata:
  type: project
---

When a finding tells you to propagate a clause from one surface to its
siblings, the CLAUDE.md (or README) **sweep rule** that describes the
distribution of that clause becomes false the moment you finish. The rule is
part of the class, and it is the surface you did not open.

**Why:** PR #273 round 2. Finding 3 said "add the no-`chmod` clause to
`CLAUDECREDS_MNT=` and `host-acceptance.sh`". CLAUDE.md's `claudecreds` sweep
bullet said "**The run.env one** asserts the *mode* each lands with (`0600`)
in the same breath" — true before the edit, false after, since three of the
four surfaces then asserted it. A separate finding (4) happened to point at
the same bullet for a different reason; had it not, the staleness would have
shipped.

**How to apply:**

- After propagating a clause, grep the sweep rule for the surface names and
  for the clause itself, and re-read what it claims about *which* surface
  carries it.
- Prefer a **quantified** repair over a re-enumeration: "Every one of them
  that also asserts the mode … — today all but the `CREDS_DIR=` header —" is
  cheaper to keep true than a per-surface list. Verify the exception by
  reading the named header, not by assuming: `CREDS_DIR=` describes the
  *directory* and genuinely never states a per-entry mode.
- When a finding leaves the categorical-vs-enumerated choice to you, keep the
  category and disambiguate it (`claude-home/` (issue #108), whose contents
  the launcher merges in without one) rather than adding an Nth copy of the
  five-entry list. The entry in the enumeration IS the directory, so naming
  the directory is both unambiguous and rot-free. Related:
  [[shared-predicate-list-is-one-claim]], [[count-tally-class-includes-back-references]].
