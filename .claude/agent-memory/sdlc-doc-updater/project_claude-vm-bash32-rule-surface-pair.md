---
name: claude-vm-bash32-rule-surface-pair
description: The bash-3.2 portability rule for claude-vm lives on exactly two surfaces (root CLAUDE.md section + payload/README.md "A guard must survive the oldest bash that can reach it"); widening one without the other is the recurring drift.
metadata:
  type: project
---

The "write claude-vm's config-load guards for bash 3.2" rule has two
homes and no others: the root `CLAUDE.md` section of that name, and
`plugins/claude-vm/payload/README.md` → *A guard must survive the
oldest bash that can reach it*. `skills/**/SKILL.md` and the example
YAMLs never mention it, so a sweep is two files, not a plugin-wide
grep.

**Why:** PR #231 widened the rule from "the guards" to "the guards and
the suite that checks them" in CLAUDE.md only; README stated the new
shape (a `case` inside `$( )`) as a bullet but its own prose still
scoped the rule to guards, and the severity clause distinguishing a
false FAIL from a shipped hole existed on one surface only.

**How to apply:** when a round touches this rule, diff both surfaces
for the same three things — scope (guards vs. suite), the severity
distinction, and how each new shape is pinned. The README paragraph
that says which shape is pinned by an assertion refers to bullets;
name the shape, never its list position ("the third"), or inserting a
bullet silently rewires the sentence.

Claims in this section are cheap to settle by running the suite under
both interpreters (`/bin/bash` 3.2 vs `/opt/homebrew/bin/bash`) and
against `origin/main` via `git archive` — the counts in the PR body
and in the README ("everything but the `local -A` render cases passes
on 3.2") are exactly that measurement. Note 3.2's total is one
assertion *lower*, not just 15 failures: `enabled-validate` emits two
assertions on the success path and one on the failure path.
