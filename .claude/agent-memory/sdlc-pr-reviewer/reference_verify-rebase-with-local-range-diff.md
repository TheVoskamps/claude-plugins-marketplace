---
name: verify-rebase-with-local-range-diff
description: To verify a rebased+force-pushed PR lost nothing, walk both series with pairwise `git patch-id --stable` (range-diff's `!` fires on message-only edits and its matcher can cross-pair near-identical commits); the gate blocks the GitHub compare API (`A...B` contains `..`); pre-rebase tips are usually already in the shared object store, anchored by review commit ids
metadata:
  type: reference
---

To verify that a rebased-and-force-pushed PR lost nothing, compare the
two commit *series* locally with `git range-diff`. The GitHub compare
API is not available for this: `gh api
repos/<o>/<r>/compare/<oldtip>...<newtip>` is refused by the permission
gate ("endpoint contains '..' (server-side path traversal)"), which
blocks every three-dot compare URL by shape.

The local route is better anyway and needs no fetch:

1. **Anchor the pre-rebase tip.** `gh pr view <N> --json reviews` gives
   each review's `commit.oid` — the round-K approval commit is a known
   pre-rebase SHA. The timeline
   (`gh api repos/<o>/<r>/issues/<N>/timeline`, event
   `head_ref_force_pushed`) gives the post-force-push head; commits
   after it were normal pushes.
2. **Old objects are already local.** The worktree shares the primary
   clone's object store, and earlier review rounds fetched the
   pre-rebase branch — `git cat-file -t <old-sha>` confirmed both old
   tip and new base present without any network.
3. **Compare series, not trees — and prefer a pairwise patch-id walk
   over range-diff's verdicts.** `git rev-list --reverse` both ranges,
   then per position `git show <sha> | git patch-id --stable` and
   compare in lockstep. This answers exactly "did any commit's *diff*
   change?": on PR #217 round 4 it flagged precisely the five
   hand-resolved conflict commits and nothing else. `range-diff` over
   the same ranges was noisier in two ways: its `!` also fires on
   message-only edits (a `--cleanup=strip` pass marks every stripped
   commit), and its similarity matcher cross-paired the two
   near-identical "Rebuild the linux-arm64 gate binary…" commits,
   faking a reorder that `git log --oneline` disproved. Keep
   range-diff for *reading* the interdiffs of the commits the patch-id
   walk flagged: a correct conflict resolution appears as
   *context-line* changes only (the other side's neighbors moved) with
   every payload `+`/`-` line common to both patches. New round-N work
   shows as unpaired `>` commits. A tree-level
   `git diff <oldtip> HEAD` mixes main's advance into the picture and
   cannot distinguish loss from base movement.
4. **Union checks on end state.** For conflict-resolved index files,
   `comm -23` the link sets of `git show origin/main:<idx>` vs the
   worktree copy proves no main-side entry was dropped; the
   files-vs-index cross-check proves no branch-side entry was.

Bonus tell: replayed conflict commits can carry literal `# Conflicts:`
comment blocks in their final messages — `git commit --no-edit` uses
cleanup=whitespace, which keeps `#` lines. That is both commit-message
noise (gradeable, at most Low) and a free map of exactly which commits
needed resolution. Related: [[skip-fetch-when-origin-ref-matches]],
[[re-review-the-whole-diff-fresh]].
