---
name: unpinnable-guarantee-soften-the-fact-keep-the-membership
description: When a finding says a guarantee is unverified, grade each "must not" hit — normative intent survives, mechanism-fact claims get softened — and say what does NOT change, so the softening is not read as loosening the rule
metadata:
  type: project
---

A finding of the shape "you ship guarantee G as settled fact while G is
unpinned" offers two remedies: pin it, or soften it. When pinning needs
a surface the codebase cannot reach — a live harness, a real
`settings.json`, a running product — take the softening and say WHY the
pin is out of reach, rather than escalating.

**Why:** #262's hard-ask tier rests on "a hook `ask` outranks a
downstream allow, so an LLM cannot waive a publish or a credential
read". Every test in the gate package replays a synthetic event into
the classifier; none brings up a harness with a competing allow. The
claim is the documented contract of the PreToolUse channel, so it is
not wrong — it is unmeasured, and the finding was that the code sold it
as measured.

**How to apply:**

- Grep the guarantee's keyword (`waiv` here) across code, README,
  playbook and agent memory, and grade EVERY hit rather than the ones
  the finding quoted. Two classes fall out and only one moves:
  - **Normative intent** — "an LLM *must not be able to* waive these",
    "letting an evaluator waive it *would* remove the control". These
    state policy or a counterfactual and survive untouched.
  - **Mechanism fact** — "never waivable downstream", "so it is not
    waivable", "no downstream judge may waive them". These assert what
    the stack does and are the ones to soften.
- Put the full account in ONE place (a named README section) and make
  every other hit a pointer to it, so the next reader finds the caveat
  from wherever they landed. A pointer's target must carry the claim —
  [[project_pointer-target-must-carry-the-claim]].
- State the consequence in both directions, or the softening reads as
  loosening: here, the tier's MEMBERSHIP rule is unaffected (an
  enumerated policy call belongs in ASK regardless, because DEFER is
  unambiguously waivable), and what changes is only that nobody may
  cite the guarantee as established.
- Say in the PR body that the pin was declined and why the surface is
  out of reach — a reviewer who asked for a test needs to see the
  reason, not just the softened prose.
