---
name: recheck-main-facts-every-round
description: On round N of a PR, re-derive every main-relative fact fresh — mergeable state, plugin-version collisions, and committed-binary vcs.revision vs CURRENT origin/main — because other PRs merging mid-review invalidate round-1 conclusions without the branch changing at all
metadata:
  type: reference
---

A multi-round PR's branch can be unchanged while its review facts rot:
`main` moves between rounds. On PR #217 round 2, PR #208 merged to
`main` mid-review and silently invalidated three round-1 facts:

- **Version collision.** #208 took guardrails `0.9.15` and claude-vm
  `0.17.1` — the exact strings #217 bumps to. Because both sides change
  the same line to the same string, `plugin.json` **auto-merges
  cleanly**; neither `CONFLICTING` state nor conflict resolution ever
  surfaces it. Only an explicit
  `git show origin/main:<plugin>/.claude-plugin/plugin.json` per round
  catches it. Consequence if missed: the same version id republished
  with different bytes, and version-keyed plugin caches pin installed
  hosts/baked guests at the OTHER PR's content — a security fix that
  silently never ships.
- **Committed-binary staleness.** The branch's new foreign-arch binary
  embedded `vcs.revision=<merge-base>`; #208 changed gate Go source and
  rebuilt the *other* two binaries on `main`. Post-merge the platforms
  diverge in policy under one version. Check
  `go version -m <bin> | grep vcs.revision` against the CURRENT
  merge-base each round, not just round 1 — nm-identity to the branch's
  own HEAD source (see [[guardrails-binary-verification]]) proves
  branch-consistency, NOT merge-consistency.
- **Mergeability.** `gh pr view <N> --json mergeable,mergeStateStatus`
  is one cheap call; `git merge-tree --write-tree origin/main HEAD`
  names the conflicted paths read-only, no checkout needed.

**How to apply:** treat "vs main" claims in the PR body ("byte-identical
to main", "version bumped per repo rule") as stamped with the date they
were written. On every round, after `git fetch`-equivalent freshness is
established (origin/main ref), re-run the three checks above before
grading. Related: [[version-bump-check-history-can-lie]] (the show +
last-touching-commit recipe), [[re-review-the-whole-diff-fresh]] (same
principle, diff axis instead of base axis).
