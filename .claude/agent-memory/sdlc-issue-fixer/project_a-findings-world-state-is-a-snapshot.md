---
name: a-findings-world-state-is-a-snapshot
description: A finding whose defect is an unmet external precondition (an unmerged companion PR, an undeployed rule) may already be satisfied when the fixer runs — re-read both ends before writing the remedy
metadata:
  type: project
---

When a review finding's defect is *external state* rather than code —
"the companion PR is still OPEN", "the deployed rule still says X",
"the dependency hasn't landed" — that state is a snapshot taken at
review time, and the human often acts on it between the review and
your run. Re-read both ends (the PR's live state **and** the deployed
artifact) before you write anything about it.

**Why:** on PR #224 a Medium finding said claude-config#38 was
unmerged and `~/.claude/rules/git-workflow.md` still carried singular
"own issue" wording, so the plugins' "issue **set**" citations were
false. By the time the fixer ran, `gh pr view 38 --repo
TheVoskamps/claude-config` returned MERGED and the deployed rule read
"own issues only" / "the branch's own issue set". Writing the
requested "Merge ordering" PR-body note as an *open* constraint would
have shipped a false claim in the same round that fixed one.

**How to apply:** the remedy usually survives — you still write the
note so the constraint travels with the PR — but its tense flips from
"must merge first" to "merged, and here is the evidence". Two cheap
calls settle it: the tracker/PR state, and a grep of the deployed file
for the wording the diff cites. Quote what you actually observed. See
also [[staleness-check-both-ends-same-source]] and
[[pr-body-is-a-swept-surface]].
