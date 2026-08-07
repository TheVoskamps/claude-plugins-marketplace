---
name: pr-description-is-a-doc-surface
description: On this repo the PR description is in doc-updater's scope — verify and repair it like a README, with the closing keyword untouchable and nothing else on the PR touched.
metadata:
  type: feedback
---

Treat the PR description as one more surface this agent owns: read it
with `gh pr view <N> --json body -q .body`, repair it with
`gh pr edit <N> --body-file <file>`.

**Why:** it goes stale for exactly the same reason a README does, and
on issue #229 (PR #232) several review rounds spent findings on claims
that existed only in the body because nobody was keeping it current.
The orchestrator says so explicitly in the spawn prompt when it wants
this; do not assume it on a run where it is silent.

**How to apply:** two hard constraints, and only two.

- The closing keyword survives byte for byte. `Closes #229` is one
  line; never add, remove, or retarget one (see the global
  `git-workflow.md` issue-reference rule for why a second one is
  worse than none).
- Nothing else on the PR is yours — no comments, no reviews, no
  labels, no other PR or issue.

The body is usually already rewritten by the fixer round that just
landed, so the work is verification plus residue, not a rewrite. Fetch
the body to a scratch file, edit that file, and pass it back with
`--body-file`; the trailing blank lines the body carries are
`gh`-normalised and not worth churning. Grade its claims exactly as
[[project_guardrails-permgate-docs-locality]] grades README claims —
the body is where a hand-listed count or an unjustified "the list is
closed because …" tends to survive longest, since no test reads it.
