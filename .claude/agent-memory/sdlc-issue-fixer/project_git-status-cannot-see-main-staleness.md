---
name: git-status-cannot-see-main-staleness
description: git status compares against the branch's own remote ref and never against main, so only git merge-base --is-ancestor origin/main HEAD detects that a branch is behind; a CONFLICTING PR never self-heals because auto-rebase-prs.yml drops DIRTY; if a real conflict makes a rebase necessary, re-derive from the rebased tree, prove it disturbed nothing with a changed-path set check (patch-id flags benign context shifts too), push with an explicit-SHA lease, re-check any SHA already quoted in the PR body, and resolve MEMORY.md as a union that honors a Curate commit's deletions
metadata:
  type: project
---

**Detection.** `git status` reporting "up to date with
`origin/<branch>`" says nothing about main: it compares against the
branch's own remote ref, and `git fetch` alone does not surface the
gap either. Only `git merge-base --is-ancestor origin/main HEAD`
answers whether the branch is behind main; non-zero means it is. When
that matters — a PR reading `CONFLICTING`, or a fix being computed
against a file main has since rewritten — `git diff --name-only
<merge-base>..origin/main` names which of the target files moved.

Being behind main is not by itself something to act on. A rebase is a
response to an actual conflict, not a precondition for editing a file.

**Nothing else will do it for you.** This repo's `auto-rebase-prs.yml`
acts only on `mergeStateStatus` of `BEHIND` or `BLOCKED`, and its own
comments say `DIRTY` is deliberately dropped. So a PR reading
`CONFLICTING`/`DIRTY` never self-heals — do not end a run assuming the
sweep will pick it up.

**If a rebase is warranted:**

1. `git rebase origin/main`, resolve, then re-derive the change from
   the rebased tree — do not carry over a working-tree diff computed
   against the stale files (`git checkout -- .` and redo; the
   re-derivation is cheap and the stale hunks are not).
2. Push with an explicit-SHA lease:
   `git push --force-with-lease=<branch>:<old-remote-sha> origin
   <branch>`. `git-workflow.md` sanctions `--force-with-lease` exactly
   for "after rebasing a branch onto the default branch's HEAD".
3. Verify with `gh pr view <N> --json mergeable` — it should flip
   `CONFLICTING` → `MERGEABLE`. (`BLOCKED` alongside `MERGEABLE` is
   just pending review/checks, not a conflict.)
4. **Re-check any commit SHA you already published.** A rebase rewrites
   every replayed commit, so a SHA quoted in the PR body — the exact
   thing a "completion commit reference" asks for — is left dangling.
   Order the work rebase-then-quote when you can; when you cannot,
   `grep -c <old-sha>` the live body afterwards and re-edit. The same
   applies to a SHA quoted in a review comment or a report.

Feature-branch commits in this repo are unsigned (`git log
--format=%G?` shows `N` before *and* after), so a rebase strips no
signatures here. Conflicts land almost entirely in
`.claude/agent-memory/*/MEMORY.md` indexes and resolve as a union of
both sides' bullets — except when the branch's own `Curate agent
memory` commit is the one being replayed, where the correct resolution
is to keep main's new bullet and honor the scrubber's deletion.

**Union-resolving an index by script — and the anchor trap.** On a long
branch the same `MEMORY.md` conflicts once per replayed memory commit,
so it pays to script the union (`grep -vE` away the three marker line
kinds). The trap: BSD `grep` (macOS) treats `$` as a **literal** when it
is not at the very end of the pattern, so a branch like
`'^<<<<<<< |^=======$|^>>>>>>> '` silently never matches the separator
and leaves a bare `=======` in the resolved file, which `git add` then
happily commits. Anchor the separator branch at the start only, and make
the script re-grep for surviving markers and exit non-zero.

**Proving the rebase disturbed nothing.** Two cheap checks beat
re-reviewing the diff. `git diff --stat <pre-rebase-tip>..HEAD --
<subtree>` printing nothing proves that subtree (e.g. a whole plugin,
sources *and* committed binaries) is byte-identical to the approved tip,
so no rebuild is owed. `git range-diff <old-base>..<old-tip>
origin/main..HEAD` should mark every substantive commit `=`; only the
commits you hand-resolved may read `!`.

Prefer a **pairwise `git patch-id --stable`** walk (`git rev-list
--reverse` both ranges, `git show <sha> | git patch-id --stable`, compare
in lockstep) over reading `range-diff`'s verdicts. `range-diff` grades on
the whole commit, so a message-only edit — exactly what the
`--cleanup=strip` pass in [[rebase-continue-editor-gate]] does to every
replayed commit — reads `!` on commits whose *patch* never moved, and its
similarity pairing silently mis-matches near-identical commits (PR #217
round 4: two "Rebuild the linux-arm64 gate binary…" commits paired
crosswise, faking a reorder that `git log --oneline` disproved). The
patch-id walk answers the question you actually have — "did any diff
change?" — and on that run flagged exactly the five hand-resolved commits
and nothing else.

That last clause is run-specific, not a general property: `patch-id`
hashes the diff's **context** lines too, so an *auto-merged* commit
whose neighbourhood main happened to revise also reads `!` even though
nobody touched it. PR #224 rebased 13 commits with 2 hand-resolved
conflicts and the walk flagged 4 — the two extras were memory-index
appends whose surrounding entries main had rewritten. Treat `!` as
"look at this commit", never as "this commit changed".

**The decisive check is at the path level, and it has no false
positives:** every path where the rebased tip differs from the
pre-rebase tip must be a path main itself changed. Two `git diff
--name-only` runs (`<old-tip>..HEAD` and `<old-base>..origin/main`),
sorted, then `comm -23` — an empty left column proves the branch's own
content survived byte-identically everywhere main did not touch, which
is exactly what the patch-id walk is groping at. Pair it with a
`--numstat` on the overlap files: a union resolution must show `N 0`
(additions, zero deletions) against main, since any deleted line is a
silent revert of main's side. Both ran clean on #224 and settled in
seconds what four `!` marks could not.

For agent memory, also prove the
final file set equals the union of both sides
(`git ls-tree -r --name-only` on each of main, the old tip, and HEAD,
then `comm`), and check each index in both directions — every pointer
resolves to a file, every file has exactly one pointer.

See [[git-command-form-gate-cd-then-bare-git]] and
[[rebase-continue-editor-gate]] for the command forms the gate allows
while doing this, [[worktree-isolation-gate-blocks-compound-bash]] for
why these checks have to live in `.sh` files under `.claude/tmp/` rather
than compound Bash calls, and
[[rebase-absorbs-an-identical-version-bump]] for the version-bump
follow-up a rebase silently creates.
