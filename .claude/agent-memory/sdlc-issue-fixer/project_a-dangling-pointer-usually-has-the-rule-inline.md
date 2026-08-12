---
name: a-dangling-pointer-usually-has-the-rule-inline
description: Before inlining a rule to repair a "see <file>" pointer at a file that does not exist, read the surrounding prose — it usually already states the rule, so the repair is deleting the pointer or aiming it at an existing skill, not duplicating instructions
metadata:
  type: project
---

A repeated `see ~/.claude/rules/<x>.md` pointer at a file that does not
exist is repaired by reading each call site's own paragraph first. On
PR #250, all seven citations of `worktree-cleanup.md` (five in
`orchestrate/SKILL.md`, two in
`git-tools/skills/git-cleanup-branches-and-worktrees/SKILL.md`) already
spelled out unlock-then-remove and its skip conditions in the lines
immediately around them.

**Why:** the owner's ruling was explicitly "do NOT inline the rule (no
duplicated instructions)" — and inlining would have been redundant
anyway. The pointer was decoration on prose that already carried the
content, so four sites lost the pointer outright, one absorbed the
parenthetical's not-allowed cases, and two gained a pointer to
`/git-tools:git-cleanup-branches-and-worktrees`, a skill that exists
and runs the same pattern.

**How to apply:** enumerate every citation with one grep before editing
any of them, and check what each site loses if the pointer just goes
away. Verify the target's non-existence by listing the directory
(`ls ~/.claude/rules/`), not by failing to Read it. Finish with a
repo-wide grep for the dangling name — the fix is only done when it
returns nothing. A cross-reference to a *heading* is the same class:
prefer the heading a `grep -n '^#'` confirms over one you remember.
