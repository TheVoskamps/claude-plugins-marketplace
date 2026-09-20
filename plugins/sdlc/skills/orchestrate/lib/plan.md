# Plan

How the issues are grouped into batches, how the batches are ordered
into waves, and the plan the human confirms before anything spawns.

## Grouping: assign issues to batches, then order the batches

A **batch** is an ordered set of issues implemented on one branch by
one `issue-developer` and delivered as one PR that closes all of them.
A batch of one is the ordinary single-issue shape, so every issue
lands in a batch, possibly alone.

Grouping decides both what goes on a branch together and what runs
concurrently:

1. **Assign every issue to a batch.**
2. **Order the batches into waves.** Batches with no dependency
   between them and no file conflict go in the same wave and are
   spawned simultaneously; a batch that depends on another batch's
   work, or would conflict with it on files, waits for a later wave.

### When to batch

Batch two issues together when **all** of these hold:

- **Shared change surface** — they touch the same files, or the same
  plugin/module, such that separate PRs would conflict or force a
  rebase. Settle it on each member's "Files likely affected" list
  from the analysis. The canonical instance is a shared version-bump
  line: a repo that requires one version bump per touched plugin per
  PR makes three PRs against one plugin conflict on that line by
  construction, and two of them get rebased.
- **Combined size stays reviewable** — at most one `complex` member,
  at most 5 members.
- **No unmerged external blocker** on any member. A blocker outside
  the set you were given stops the whole batch, not just that member.

A blocked-by edge **inside** a candidate batch is not a bar — it is a
*reason* to batch. Separated, that edge costs two serial waves: fix
the first, PR it, then start the second. One developer working both in
dependency order in one worktree collapses it to one PR. Put the
blocker before the blocked issue in the batch's implementation order.

### When not to batch

- **Unrelated areas.** A stalled member then blocks unrelated work,
  and the review has no coherent story to tell.
- **Overhead is the only argument.** Saving agent spawns is not a
  shared change surface. Per-issue overhead is real — developer,
  code-documenter, style-checker, review pipeline, docs-writer,
  scrubber, worktree churn — but it never justifies a batch on its own.

The judgment call is: batch when the **conflict cost of separating**
exceeds the **blocking cost of joining**. A trivial README change
batched with a hard gate change waits on the hard review — worth it
when they share a version bump, not worth it when they do not.

### Choose the compound slug at plan time

A batch of two or more needs a **compound slug** for its branch name
(`issue-<N1>-<N2>-…-<Nk>-<compound-slug>`). Mechanically merging k
titles produces garbage, so you choose it during planning and pass it
in the spawn prompt — `git-tools:git-branch-create` validates the
shape (kebab-case, no leading digit, branch name at most 100
characters) and refuses to invent one. Name the batch's shared change
surface, e.g. `guardrails-gate-sweep`. A batch of one needs no slug —
the skill derives it from the issue title.

## Present the plan

Present the plan to the human in this format before proceeding:

```text
## Fix Plan

| Batch | Issue | Title | Complexity | Notes |
|-------|-------|-------|------------|-------|
| A | <link-prefix>101 | ...   | simple  | —     |
| B | <link-prefix>106 | ...   | medium  | shared version bump w/ 102 |
| B | <link-prefix>102 | ...   | medium  | blocked by 106 — batched, so no extra wave |
| C | <link-prefix>103 | ...   | complex | conflicts with B on <file> |
...

Batch B branch slug: <compound-slug>
Batch criteria applied: <one line per batch of two or more — which of
shared-change-surface / internal-dependency / size it turned on, and
the conflict-cost-vs-blocking-cost call you made>
Decision items: <one per body instruction you did not agree with on
reading the file — the sentence quoted, and what you would do instead
— or "none">

### Wave 1 (parallel): Batch A, Batch B
### Wave 2 (after Wave 1 PRs open): Batch C

Ready to proceed? (y to continue, or give me adjustments — e.g.
"split 102 out of B", "merge 101 into B", or "generator high for C")
```

The confirm step is the human's escape hatch on grouping, and the only
cheap moment for it: regrouping before any spawn is free, and after a
branch carries commits and a PR it is not. Accept a regrouping
instruction — re-emit the table with the change applied and confirm
again. A generator tier the human names here is a `--generator`
override for that batch: it wins outright for the seed generator and
for every reviewer round on the batch's PR. If the run is large (more
than 8 issues across all batches), split it into two separate sessions
and say so here before proceeding.

## Wave sequencing

Do not start Wave 2 until all Wave 1 issue-developers have reported
back; their code-documenters, style-checkers, review pipelines, and
fix loops do not block the next wave. This ensures file-conflicting
batches never run concurrently.
