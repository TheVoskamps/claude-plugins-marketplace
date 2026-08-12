---
name: orchestrate-rationale-clauses
description: A round that changes WHAT orchestrate/SKILL.md forwards to a teammate leaves the because-clauses that justified forwarding it standing, far from the diff
metadata:
  type: project
---

When a round narrows what `/sdlc:orchestrate` puts in a spawn prompt, the
rules move but the *rationales* elsewhere in SKILL.md that were built on the
old behavior do not. Two sat hundreds of lines from the #245/#248 diff and
both had become false:

- The `effort: medium` paragraph justified the default with "because Phase 1
  and the issue bodies already carry the plan" — the same round stopped
  forwarding both.
- "What the orchestrator IS allowed to do" → *Read freely* said "the more the
  orchestrator reads before spawning, the better its spawn prompts", which is
  the exact inversion of the new principle.

**Why:** a behavior rule is edited where it is stated; a *because* clause is
prose in a different section, and nothing greps for it.

**How to apply:** after any orchestrate change to what a brief carries or what
a report is worth, grep SKILL.md for `because`, `Phase 1`, `spawn prompt` and
`brief`, and read each hit as a claim about the new behavior. Also check the
new prose's own claims about orchestrator ordering — this round shipped "you
grepped it before reading anything", while Phase 1 greps *from* the issue
body it has already read. See
[[feedback_qualifier-that-contradicts-the-next-paragraph]].
