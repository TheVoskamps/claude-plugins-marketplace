---
name: lint-sweep-must-cover-the-agent-memory-tree
description: agent-memory is a linted tree with its own nested markdownlint config, so a markdown sweep must glob it explicitly; inside a worktree its `extends` needs no depth correction, and MD055 is the discriminator that proves the chain resolved
metadata:
  type: project
---

`.claude/agent-memory/` carries its own `.markdownlint.jsonc` and is a
**linted tree**, so the global "leave Markdown clean" rule applies to
every memory commit. It is also the tree a sweep misses: PR #232 shipped
the SAME MD018 defect twice — round 1 found a wrapped line beginning
`#232).**` in a memory file, it was fixed, and a later doc-updater
memory commit reintroduced the identical shape in the identical file.

**Why:** each agent commits its own memory at the END of its run, after
whatever lint it ran, and the memory files are not what the agent thinks
of as "the files I changed". The wrap that causes it is invisible to the
author — a `(#229, PR\n#232)` reference wrapped at the wrong space puts
`#` in column 1, which MD018 reads as a malformed ATX heading.

**How to apply:**

1. Sweep from the PR's own changed set, not from the files you edited:
   `git diff --name-only --diff-filter=d origin/main...HEAD -- '*.md'`,
   then `xargs npx markdownlint-cli2 < <that file>`. macOS `xargs` has
   no `-a`, so redirect stdin.
2. Add the whole memory tree, because your own about-to-be-written
   memory files are not in that diff yet:
   `npx markdownlint-cli2 '.claude/agent-memory/**/*.md'`. Check the
   reported file count against `find .claude/agent-memory -name '*.md'
   | wc -l` — equality rules out a silently-skipped glob.
3. Lint again AFTER writing your memory files and before the memory
   commit. That is the step both failures skipped.
4. **No depth correction is needed inside a worktree.** The tree config
   says `extends: "../../.markdownlint.jsonc"`, which from
   `<worktree>/.claude/agent-memory/` resolves to the worktree's own
   root config. Depth correction is only for an extracted `origin/main`
   copy at a different depth.
5. Prove the chain is live rather than assuming it — a broken `extends`
   would make the whole sweep vacuous. Drop a throwaway probe INTO the
   tree carrying a table with no leading/trailing pipes plus a
   200-column line: MD055 firing (`leading_and_trailing` is set ONLY in
   the root config) proves the parent merged, and MD013 staying silent
   proves the local carve-outs did. Delete the probe immediately. This
   is non-mutating, unlike flipping a value in the parent — see
   [[prove-config-inheritance-chain-live]] and
   [[lint-config-control-needs-its-own-directory]] for when you must
   mutate instead.
6. Negative-control the fix: `git show HEAD:<path>` into a temp file
   **in the same directory** (config discovery is per-directory, so a
   copy under `.claude/tmp/` would resolve a different config) and
   confirm the sweep reproduces the reviewer's exact error line. "0
   issues" proves nothing until the command has been shown to fail on
   the pre-fix bytes. See [[negative-control-the-approved-snippet]].

Repo-wide, `git ls-files '*.md'` turns up a standing set of pre-existing
MD041 hits in `plugins/issues/skills/**/SKILL.md` and `PRIOR_ART.md` —
frontmatter-then-prose, the same format contract the agent-memory config
carves out. Report those; they are not yours, and their count drifts, so
re-measure rather than quoting a remembered figure.
