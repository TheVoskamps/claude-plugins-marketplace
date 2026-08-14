---
name: deferral-pointer-outruns-its-target
description: A round that replaces a restatement with a "see the other file's X section" pointer promises more than the target section says; read the target before accepting the deferral.
metadata:
  type: project
---

When a fixer round de-duplicates prose by turning a restatement into a
pointer ("what that tally enumerates, and **which of its counts never
reach severity**, is the pipeline skill's own 'Report back' section"),
grade the pointer against the target section's actual text. The
pointer is written from the author's mental model of the target, not
from a re-read of it.

**Why:** on #259 both callers (`skills/git-review-pr/SKILL.md` and
`skills/orchestrate/SKILL.md`) deferred to
`pr-review-pipeline/SKILL.md` → "Report back" for which tally counts
never reach severity. That section named surviving and refuted only,
while the disposition table and review-body section 7 both give the
unsettled row "no severity" — so the deferral pointed at an
enumeration missing a third of its subject. Nothing was wrong; the
target was just narrower than the pointer claimed.

**How to apply:** on any round whose commit message says "defers to X
rather than restating", open X and check it covers every noun the
pointer names. Repair on the TARGET side when the omitted fact is
already established elsewhere in that file — that keeps the single
source of truth single. Same shape as
[[no-blanket-predicate-over-a-list]]: a pointer is one claim per thing
it promises. Related: [[fan-out-doc-surfaces]] on two-sided contracts.

**Prefix-quoted headings are the cheap sibling of this**, and the
repo states that rule itself: CLAUDE.md's cross-reference-sweep
paragraph carries how strictly a `→ "Section"` pointer must resolve —
that a grep hit is not the check, and that a line wrap inside the
quotes is joined back before comparing. Apply it from there.
