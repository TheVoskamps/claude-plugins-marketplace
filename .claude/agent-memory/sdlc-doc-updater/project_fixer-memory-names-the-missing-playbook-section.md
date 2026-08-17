---
name: fixer-memory-names-the-missing-playbook-section
description: On a fixer round that changed HOW a claim was verified, the issue-fixer's newest memory file usually states a technique the /docs verification playbook does not yet carry — that gap is the doc-updater's edit
metadata:
  type: project
---

When an `issue-fixer` round changes **how** a property is pinned rather
than what the code does, read the memory files that round added under
`.claude/agent-memory/sdlc-issue-fixer/` (they arrive in the same diff,
one commit after the code). The lesson in them is usually a
verification *technique*, and this repo's CLAUDE.md → "Settle a claim
with the playbook, not by reasoning" makes `/docs/*-verification-playbook.md`
its home. The fixer writes it to memory and to the local code comment;
nobody but the doc-updater carries it into the playbook.

**Why:** PR #273 round 3 replaced a string-match control
(`assert_contains … 'cp -RL'`) with a behavioral one — a one-filesystem
harness cannot see a dropped `-L` by content, only in the SHAPE of the
staged artifact. That went into the test file's comments and into
`project_one-filesystem-harness-cannot-see-a-deref-drop.md`, while
`docs/claude-vm-verification-playbook.md` → "Slice the real launcher
loop to read what it emits" — the section the same PR had already
extended — still said nothing about it.

**How to apply:** `git show --stat` the round's memory commit, read the
new fixer files, and ask of each whether it is a technique (playbook)
or a repo policy (CLAUDE.md) rather than a one-off fix (nothing). Do
not edit or stage the fixer's memory file itself — only your own — see
[[read-the-worktree-not-the-primary-clone]] for the path trap and the
agent definition for whose memory is whose.

The same rounds leave ragged line wraps wherever a clause was spliced
into an existing paragraph or comment: grep the diff for lines far
short of the file's column limit and reflow, per
[[de-specify-round-leftovers]].
