---
name: scope-guarantee-claims-to-actual-caller
description: a skill's doc claimed "autonomous mode always runs on a freshly checked-out branch" — true only because of who currently calls it, not a property of the skill itself; narrow the claim to name the caller instead of generalizing over the mode
metadata:
  type: feedback
---

Round 4 of PR #185 (issue #184) flagged
`plugins/cc-tools/skills/agent-memory-cleanup/SKILL.md` for asserting
"autonomous mode always runs on a freshly checked-out branch" as the
justification for skipping an untracked-file safety check in that
mode. The skill's own "Resolve the scope" section only does
`git checkout <headRefName>` — no fresh-worktree requirement, no
clean-tree precondition, nothing that actually restricts callers to
producing a fresh checkout. The claim was true only because the
skill's sole current caller (`agent-memory-scrubber`) happens to
always run in a fresh `isolation: worktree` and check out the branch
fresh before invoking the skill. A hypothetical human running
`/agent-memory-cleanup <PR>` by hand over a dirty local checkout would
violate the claim immediately.

**Why:** a skill's own doc should describe what the skill's own logic
guarantees, not what happens to be true of its current call sites.
Call sites change (a future caller might invoke the same skill
differently); a claim phrased as an intrinsic property of "autonomous
mode" reads as durable even after the call site that made it true is
gone.

**How to apply:** when a skill or agent doc justifies skipping a check
by asserting an environmental precondition ("X always runs fresh",
"Y is always clean", "Z never has untracked files"), verify the
precondition is enforced by the skill's *own* code path. If it's
actually a property of one specific caller, say so explicitly by name
("the guarantee comes from `<caller>`, which does `<mechanism>`, not
from this skill itself") rather than generalizing the claim over the
whole mode. This keeps the doc honest if a second caller is added
later without that caller's own worktree/checkout guarantee.

Related to [[no-invented-policy-in-agent-defs]] (same PR, same
principle applied to a different failure mode: that one is an
uncited categorical prohibition, this one is an overclaimed intrinsic
guarantee) and [[sweep-sibling-agent-guards]] (the round-4 sibling
finding on the same PR, same review round).
