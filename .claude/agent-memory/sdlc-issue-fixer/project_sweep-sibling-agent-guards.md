---
name: sweep-sibling-agent-guards
description: a Critical fix to one sdlc agent's unguarded git branch -D was live in all four sibling agents too; round-3 swept the guard sentence, but round-4 found the sweep itself was incomplete — it dropped the scrubber's own carve-out for the no-commit case
metadata:
  type: project
---

PR #185 (issue #184) round 1 fixed a Critical in
`agent-memory-scrubber.md`: it deleted its local branch
(`git branch -D`) at end-of-run with no check that its commit/push had
actually landed on the remote — a data-loss path if the push failed.
Round 3 (human instruction, citing the repo's "sweep the class" rule
in `CLAUDE.md`) pointed out the identical unguarded
`git checkout --detach && git branch -D <branch>` pattern was live,
unfixed, in all four sibling `sdlc` agents:
`plugins/sdlc/agents/issue-developer.md`,
`issue-fixer.md`, `doc-updater.md`, `pr-reviewer.md` — each with no
precondition that the push landed.

The fix added a one-sentence guard to each ("Run this only if your
commit and push both succeeded — if either failed, `git branch -D`
would destroy the only copy of your work, so stop and report the
failure instead of proceeding to cleanup") worded consistently across
all five files (the four siblings plus the original scrubber), scaled
down from the scrubber's own guard (which has a heavier SHA+porcelain
verification step these four don't have — that verification machinery
was NOT imported, only the guard sentence pattern).

**Why:** the human's instruction was explicit that consistency across
the five near-identical guards matters more than any one file's
"cleverness" — a class of defect found in one file that's structurally
present in siblings should be fixed everywhere in the same PR when the
PR already touches those files, per repo `CLAUDE.md` "sweep the class."
`pr-reviewer.md`'s pre-existing conditional wrapper ("If you checked
out the PR branch at any point") was preserved and the new guard
nested inside it, not replaced.

**How to apply:** when a reviewer finds a defect class inside an
sdlc-agent file that's part of a five-agent family
(issue-developer/issue-fixer/doc-updater/pr-reviewer/
agent-memory-scrubber), check whether the pattern is copy-pasted
across the other four before declaring the fix done — the family
shares near-identical end-of-run cleanup, memory-capture, and
closing-keyword sections by design. See also
[[no-invented-policy-in-agent-defs]] for the companion round-3 item on
the same PR (removing invented prose, as opposed to sweeping a
verified-necessary guard).

**Round 4 sequel — the sweep dropped a carve-out, not just a
sentence.** The scrubber's original guard (the thing being swept) had
a second clause the four siblings' guard didn't get: "...or the skill
reported no memory to curate, so there was never anything to push."
Round 3 swept only the base guard sentence ("run this only if commit
and push both succeeded") and missed that two of the four siblings
(`pr-reviewer.md`, `doc-updater.md`) document a real no-commit path
("If `.claude/agent-memory/` has no changes, skip this step") that the
base sentence, read literally, forbids cleanup for — no commit means
neither "succeeded," so the branch gets stranded on every no-op run.
Fixed round 4 by adding "...or if you had nothing to commit" to all
four sibling guards, matching the scrubber's carve-out in substance
(wording adapted, not copy-pasted verbatim, since the scrubber's own
guard has extra SHA+porcelain verification machinery the siblings
don't).

**Sweeping is only one of the two remedies.** PR #211 (issue #207)
faced the same family with the scrubber's *lifecycle* prose
paraphrased in all four writer agents, and the reviewer's follow-up
chose the other remedy: collapse each paraphrase to a pointer at the
canonical statement — the `/sdlc:orchestrate` skill → "Before
`/pr-ready`: curate the PR's agent memory" — keeping only each
agent's own operational instruction inline. Sweep when the duplicated
text has to stay inline (the `git branch -D` guard is per-agent
operational text); collapse when it is shared *rationale* that one
file can own. After that PR the lifecycle prose no longer needs the
four-file sweep — the end-of-run cleanup guard still does.

**Generalized lesson:** when the thing being swept is a guard/rule
with an exception clause, sweep the exception too, not just the
headline sentence. A partial sweep (rule copied, carve-out dropped) is
worse than no sweep in one way: it looks complete, so it doesn't get
flagged as unswept — it takes a second review round to notice the
carve-out is missing. Before calling a guard-sweep done, diff the
*full* structure of the source guard (every clause, every "or"
branch) against each sibling's copy, not just the topic sentence.
