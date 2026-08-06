---
name: no-blanket-predicate-over-a-list
description: Never grade several doc surfaces with one shared predicate — describe each member separately, or the memory asserts something false about the members you never opened
metadata:
  type: feedback
---

When a memory (or a doc paragraph) lists several files and attaches one
predicate to all of them — "these name the agents only as a list, never
their behavior" — that is not one claim, it is one claim per file.
Write per-member descriptions instead, and state the trigger that makes
each go stale.

**Why:** a blanket predicate reads as verified because it is one
sentence, but its evidence is typically one file skimmed and the rest
assumed. The sdlc doc-surface map now carried in the repo's `CLAUDE.md`
began life in that shape and was false about the members nobody had
opened: one of them attributes a PR verb per agent, and another says
which agents dispatch on `source-control`.

**How to apply:** before committing any memory or doc sentence of the
form `<list of files> all <predicate>`, open each file and confirm the
predicate for it individually. If they differ, they need separate
clauses — the shared sentence is the defect, not the wording. The same
check applies when *reading* such a memory: a shared predicate is a
weaker warrant than a per-file one, so re-verify the member you are
about to act on.

Two sibling shapes, both found in claude-vm prose an issue-fixer wrote
about its own change (PR #231), where the conclusion was true and the
stated mechanism false:

- **"each of these is handled the same way."** "The launcher copies each
  mounted file into `$HOME/.claude/` (mode 0600)" covered three built-in
  shares that are handled three different ways — two files copied into
  `$HOME/.claude/`, an identity seed copied to `$HOME/.claude.json`, and
  a whole share (`runconfig`) never copied at all, only read in place.
  The point being made (nothing writes back to the share) survived; the
  mechanism had to be split per share.
- **"X is in the list."** A denylist entry that *covers* a path is not
  the same claim as the path being *in* the list: `/usr/bin` is not in
  `CLAUDE_VM_GUEST_SYSTEM_PATHS`, it is caught because `/usr` is and the
  guard is an ancestor relation. Read the guard, not just the constant —
  "is in" and "is covered by" fail differently the day the guard changes
  from a relation to a membership test.
