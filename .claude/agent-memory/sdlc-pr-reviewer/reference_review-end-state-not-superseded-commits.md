---
name: review-end-state-not-superseded-commits
description: On a branch that works forward past a wrong-approach commit, verify supersession in the working tree (grep/test -e), never from the diff of the correcting commit alone.
metadata:
  type: reference
---

# Verify supersession in the working tree, not the correcting diff

When a branch deliberately works forward (a wrong-approach commit
stays in history, superseded by a later correction) rather than
rewriting history, `gh pr diff` already shows only the net end state
— but the correcting commit's own diff does not prove the superseded
content is gone, because a later commit could have partially
reintroduced it.

Check the **working tree** at the PR head instead:

- `test -e <path>` for a file the correction deleted.
- `grep -rn '<distinctive phrase from the wrong version>' <dirs>` for
  prose the correction was supposed to remove.
- For a de-duplication PR, grep the *whole repo* for every value that
  was supposed to stop being restated (e.g. every model/effort tier
  name), not just the file the correction touched — a sibling doc can
  carry the same duplication the issue never named.

**Why:** on PR #200 (issue #197) two of five commits were the wrong
fix, superseded by the last two. Grading the correcting commit's diff
would have confirmed only that *that commit* did the right thing;
`grep -rn -i 'sonnet|fable|xhigh'` across the repo plus `test -e` on
the deleted memory file is what actually established the end state was
clean, and it also surfaced the one remaining `sonnet` hit
(`plugins/show-agent-calls/README.md`) as a genuine out-of-scope
false positive rather than a missed sweep.

**How to apply:** whenever a spawn brief says a branch "works forward
rather than rewriting history", or the commit list contains a commit
whose message says "Supersedes"/"was the wrong fix", run the
working-tree greps before writing any finding about whether the
correction is complete. Pairs with
[[re-review-the-whole-diff-fresh]] — same instinct, applied across
commits instead of across review rounds. Baseline-check any lint hit
you find this way per [[baseline-lint-before-flagging]]; a
de-duplication reflow inherits the file's pre-existing MD041/MD013
state.
