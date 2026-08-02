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
