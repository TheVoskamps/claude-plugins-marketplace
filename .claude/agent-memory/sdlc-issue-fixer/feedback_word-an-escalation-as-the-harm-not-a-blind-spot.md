---
name: word-an-escalation-as-the-harm-not-a-blind-spot
description: Never word a gate escalation as "the gate cannot tell what this does" — say what the operation does to the world; and check whether the unknown you were about to cite is actually the WORSE case, because an already-existing destination can be more exposed than a fresh one, not less.
metadata:
  type: feedback
---

When escalating an operation, the message states the HARM, not the
gate's ignorance. "The gate cannot tell what this publishes to" invites
the reader to treat the unknown as probably-fine and click through; "a
local file's contents land somewhere that may already have readers"
puts the actual decision in front of them.

**Why:** on PR #232 I recommended escalating `gh gist edit` and framed
the target gist's unknown VISIBILITY as the tier's weakness. Edwin
overruled the framing outright: the egress is the point, and an
existing gist may already have a circulated URL and existing readers,
which makes `edit` potentially **worse** than `create` — `create` at
least mints a URL nobody holds yet. The "we can't see it" reading had
the risk ordering backwards. He also settled the tier at ASK rather
than DENY on a reason worth remembering: the guardrails gate governs
interactive HUMAN sessions as well as agent ones, and there are
legitimate human reasons to do the thing — one click preserves those,
a deny does not.

Two things that follow, both of which cost a round if missed:

- **Scope the escalation to the whole VERB, not to the flag spellings
  that carry the payload.** Scoping by flag is the sensitivity that
  produced the `-p`/`--public` hole this same PR had already fixed, and
  the argument does not get weaker the second time.
- **Assert the framing in a test.** A message-content test can require
  the harm words ("may already have readers", "does not un-read it")
  AND forbid the blind-spot words ("cannot tell", and here the
  visibility vocabulary "unlisted"/"secret"), so a later reword cannot
  quietly reintroduce the framing that was overruled.

**How to apply:** on any new ask/deny message, and on any review
recommendation that reaches for "the gate has no signal for X". Before
citing an unknown, ask which value of that unknown is the bad one — if
the answer is "either, and one of them is worse than the case we
already escalate", the unknown was never the argument.

Related: [[a-tier-premise-can-be-a-vendor-fact]],
[[implement-the-findings-broader-rule]],
[[scope-guarantee-claims-to-actual-caller]].
