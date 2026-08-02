---
name: no-blanket-predicate-over-a-list
description: Never grade several doc surfaces with one shared predicate — describe each member separately, or the memory asserts something false about the members you never opened
metadata:
  type: feedback
---

When a memory (or a doc paragraph) lists several files and attaches one
predicate to all of them — "these three name the agents only as a list,
never their behavior" — that is not one claim, it is one claim per file.
Write per-member descriptions instead, and state the trigger that makes
each go stale.

**Why:** [[sdlc-docs-locality]] carried exactly that shape and was wrong
about two of its three members: `plugins/github-prs/README.md` attributes
a PR verb per agent and `plugins/issues/skills/lib/repo-config.md` says
which agents dispatch on `source-control`. An `issue-fixer` round on
PR #220 (commit 130bff5) had to correct it. The blanket predicate reads
as verified because it is one sentence, but its evidence was one file
skimmed and the rest assumed.

**How to apply:** before committing any memory or doc sentence of the
form `<list of files> all <predicate>`, open each file and confirm the
predicate for it individually. If they differ, they need separate
clauses — the shared sentence is the defect, not the wording. Same
check applies when *reading* such a memory: a shared predicate is a
weaker warrant than a per-file one, so re-verify the member you are
about to act on.
