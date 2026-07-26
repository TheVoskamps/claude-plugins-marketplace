---
name: verify-doc-cross-reference-headings
description: before accepting or flagging a `file.md` → "Section" pointer in an agent/skill definition, grep the target file's headings — several sdlc agent defs cite git-workflow.md sections that no longer exist
metadata:
  type: reference
---

Agent and skill definitions in this repo cite other docs as
`` `git-workflow.md` → "Section Name" ``. Those pointers are not
checked by anything, and some are dangling: `~/.claude/rules/
git-workflow.md` has no "Subagent context" and no "End-of-run cleanup
pattern" heading — that file explicitly says the subagent rules moved
into the `sdlc` plugin — yet five `sdlc` agent definitions still point
at both.

**How to verify:** `grep -n "^#\+ " <target-file>` lists every heading;
then `grep -rn "<section name>" ~/.claude/rules/ ~/.claude/CLAUDE.md`
to confirm the text isn't under a differently-named heading. Two
commands, and they turn a guess into a fact either way.

**Why it matters both directions:** a dangling pointer is a real (if
Low) defect worth naming, but flagging one that *does* resolve is a
fabricated finding. Same discipline as
[[worktree-file-can-be-stale-after-checkout]]: verify the territory
before asserting about it.

**Grading note:** when the dangling pointer in the diff matches a
convention already dangling in sibling files, it is Low and belongs in
a repo-wide sweep issue, not in the PR under review — a new file
consistent with its siblings is the right call until the whole class
is fixed.
