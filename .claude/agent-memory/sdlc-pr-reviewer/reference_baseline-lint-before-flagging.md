---
name: baseline-lint-before-flagging
description: Never file a markdownlint/style finding without linting the SAME files at origin/main first; most hits in this repo's plugin docs are pre-existing
metadata:
  type: reference
---

Before filing any lint/style finding on a docs PR, run the linter on the
**same file set** at `origin/main` and at the branch tip, then compare
the two summaries. Only a *delta* is a finding.

**Why:** On PR #192 (`plugins/issues` doc rewording) the branch tip
linted as `Summary: 3 issues in 3 files` — two `MD041` plus an `MD013`
line-length at `plugins/issues/skills/lib/repo-config.md:441`. All three
were byte-identical at `origin/main`; the PR introduced none of them.
Reporting them would have been three fabricated findings on a
wording-only diff, and `MD013` in particular looks damning on a PR whose
whole job is re-wrapping prose paragraphs — the reflowed lines are
*adjacent* to the pre-existing long line, so the causal story is
seductive and wrong.

**How to apply:** Extract the base versions with `git show
origin/main:<path>` into a mirror tree under the worktree's
`.claude/tmp/`, copy the repo's lint config in (this repo uses
`.markdownlint.jsonc`, not `.yaml`/`.json` — a missing config silently
changes which rules fire), then lint both trees and diff the summaries.
Note the global "leave Markdown files clean" rule means a *pre-existing*
error is still worth a Low-severity mention at most — but only once you
know it is pre-existing, and never graded as something the PR broke.

Config discovery is **per-directory, closest wins**, and this repo
nests a second config: `.claude/agent-memory/.markdownlint.jsonc`
(extends the root, turns off only MD041/MD013). A mirror tree under
`.claude/tmp/` that reproduces just the root config lints under the
wrong rules: an extracted `MEMORY.md` fires bogus MD013 hits that are
switched off in its home tree. When the
mirror's config lineage is in doubt, skip the mirror and prove
**line provenance** instead: `wc -l` the `origin/main` blob and check
whether the offending line exists there at all — a hit on a line the
diff adds is PR-introduced under the *in-place* lint, which is the
only lint run that used the right configs.

**The lint CONFIG itself can differ between the branch's fork point and
main** (PR #217 round 2): `main` had added
`.claude/agent-memory/.markdownlint.jsonc` (MD041/MD013 carve-outs for
the memory tree) and fixed the root config's inert `MD060` → `MD055`
after the branch forked, so the branch's memory files raised ~79
MD041/MD013 hits under the branch's stale config that all dissolve on
rebase. markdownlint-cli2 discovers config upward from each FILE's
directory, so linting the primary clone's copy of the same file is a
quick main-config baseline. Only errors that survive under main's config
(e.g. an MD033 from dropped backticks) are findings.

Related: [[verify-doc-cross-reference-headings]],
[[read-branch-tip-via-git-show]],
[[recheck-main-facts-every-round]].
