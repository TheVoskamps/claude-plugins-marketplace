---
name: claude-vm-bash32-rule-surface-pair
description: The bash-3.2 portability rule for claude-vm lives on exactly two surfaces (root CLAUDE.md section + payload/README.md "A guard must survive the oldest bash that can reach it"); widening one without the other is the recurring drift.
metadata:
  type: project
---

The "write claude-vm for bash 3.2" rule has two homes and no others:
the root `CLAUDE.md` section of that name, and
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
both interpreters and against `origin/main` via `git archive`. The
bash ≥ 4 side needs a container: this host has no Homebrew bash, so
`/bin/bash` is the only local shell.

The rule is scoped to the whole file, not to the guards alone, and the
suite is fully green on 3.2 with no baselined failing set — so a PR
body carrying a 3.2 failure count is itself the defect. Never restore
a "these N always fail on 3.2" sentence to either surface.

Widening the rule's scope leaves a third kind of stale prose the
two-surface diff does not reach:
a *justification* clause elsewhere in README that explains why some
unrelated code avoids bash 4 "because the gate beside it is a
config-load guard" (the `env.set` precedence paragraph). After a
widening, grep README for `bash 4` as well as diffing the two rule
homes — see [[widened-guard-narrow-prose]].
