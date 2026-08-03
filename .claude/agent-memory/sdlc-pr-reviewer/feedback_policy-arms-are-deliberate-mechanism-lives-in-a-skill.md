---
name: policy-arms-are-deliberate-mechanism-lives-in-a-skill
description: Edwin's ruling on PR #224 — cross-plugin rule duplication is fixed by extracting the mechanism into a skill in the owning plugin (+ dependencies edge), never by a CLAUDE.md sweep/grep-needle section; the per-consumer policy arms that remain are deliberate, not drift
metadata:
  type: feedback
---

When a rule is restated across plugins, the remedy is extracting the
**mechanism** into a skill in the plugin that owns the concept, invoked
by namespaced name with a `dependencies` edge in each consumer's
`plugin.json` — never a CLAUDE.md section prescribing grep needles to
keep N copies in step. The worked instance:
`git-tools:git-issues-from-branch` (branch name → issue set), with the
grammar stated once in `git-branch-create` → "Branch name" and the
pattern generalized in `docs/plugin-authoring-constraints.md` →
"Sharing behavior (a parse, a lookup, a derivation)".

**Why:** on PR #224 rounds 1–3 chased grammar-restatement drift one
instance at a time under a CLAUDE.md "Sweep the branch-name grammar"
section; Edwin ruled the duplication itself the defect, had the parse
encapsulated in a skill, and the section deleted outright — which also
dissolved an open Low about one of its needles. Same-family standing
positions: "duplication is the defect", "simplification means less
code".

**How to apply:** two review consequences. (1) Do NOT file dedup or
drift findings against the per-consumer **policy** arms that survive an
extraction (the `C ∩ B` intersection, one-member stand-in, multi-member
refusal, per-issue verdicts restated in pr-create / pr-link-issue /
pr-reviewer) — only the mechanism is deduplicated; each caller keeping
its own policy is the design. (2) When a PR under review *introduces* a
sweep-section/grep-recipe contract for copies of a rule, that is
finding-shaped: the repo's sanctioned fix is skill extraction, and
recommending the recipe's needles be tuned treats the symptom. A
transferred CLAUDE.md paragraph deleted along with such a section is
sanctioned cleanup, not lost scrubber work.
