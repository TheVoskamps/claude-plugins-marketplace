---
name: pointer-target-must-carry-the-claim
description: A "(see <section>)" pointer is a claim that the named section carries the thing being pointed at — open it and grep before accepting the pointer, and retarget to the section that actually defines it
metadata:
  type: project
---

A cross-reference of the form *"X is derived mechanically … (see
`<section>`)"* asserts two things: the derivation rule, and that
`<section>` is where it lives. The second half is the one that rots,
because a section gets renamed, split, or moved to another skill while
the pointer keeps reading plausibly. On PR #258 the orchestrator's
severity bullet pointed at its own "Run the review pipeline" section,
which describes invoking the pipeline and never mentions grading at
all — the grading rules live in
`plugins/sdlc/skills/pr-review-pipeline/SKILL.md` → "Findings by
severity".

**Why:** the pointer's *reader* is an agent following the reference to
learn a rule. A pointer at a section that lacks the rule is a dead end
that reads as a live one, so the agent invents the rule instead.

**How to apply:** for every `(see "…")` in a diff, `grep -n` the
target heading, read the section it names, and confirm the claim is
stated there. When it is not, aim the pointer at the file+heading that
does state it — a cross-skill pointer (`the <plugin>:<skill> skill →
"<Heading>"`) is preferable to an in-file one that is merely nearer.
Related: [[a-dangling-pointer-usually-has-the-rule-inline]], which is
the repair when nothing carries the rule at all.
