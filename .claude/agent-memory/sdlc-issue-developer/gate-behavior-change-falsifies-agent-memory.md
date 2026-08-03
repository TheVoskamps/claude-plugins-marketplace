---
name: gate-behavior-change-falsifies-agent-memory
description: A permission-gate behavior change silently falsifies the .claude/agent-memory/ notes that taught agents to route around the old behavior; grep every agent-memory dir for the old verdict and delete or correct the notes in the same PR.
metadata:
  type: feedback
---

When you change a gate verdict, grep `.claude/agent-memory/` (ALL agent
subdirectories, not just your own) for prose describing the OLD verdict,
and delete or correct it in the same PR. Repair each affected
`MEMORY.md` index line and any `[[wikilink]]` pointing at a note you
delete.

**Why:** a workaround note outlives the bug it worked around, and it is
read as current fact by every later run — so agents keep paying the cost
of a defect that no longer exists. #225 found exactly this: the issue
itself cited
`sdlc-pr-reviewer/reference_regex-address-sed-awk-blocked-by-gate.md` as
evidence that "a guardrail agents have memorized workarounds for is not
enforcing anything". Sweeping the class turned up a second note
(`reference_gate-blocks-pathlike-grep-patterns.md`) and two more with
one falsified sentence each, including one of this agent's own.

**How to apply:** the grep terms that actually find them are the gate's
own message fragments ("resolves outside the current repository", "not
all static literals", "cannot resolve statically"), not the feature
name. When a doomed note carries a paragraph that is still true and
unrelated, move that paragraph into a sibling note rather than losing
it with the deletion. Deletions go in the agent-memory commit, not the
code commit.

Related: [[permission-gate-self-hosting]].
