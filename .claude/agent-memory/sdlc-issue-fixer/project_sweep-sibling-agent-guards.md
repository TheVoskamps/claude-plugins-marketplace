---
name: sweep-sibling-agent-guards
description: a Critical fix to one sdlc agent's unguarded git branch -D was live in all four sibling agents too; round-3 human instruction swept it across issue-developer, issue-fixer, doc-updater, pr-reviewer with wording matched to the original fix
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
