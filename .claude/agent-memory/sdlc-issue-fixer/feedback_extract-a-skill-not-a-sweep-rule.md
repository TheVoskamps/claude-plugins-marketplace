---
name: extract-a-skill-not-a-sweep-rule
description: When a rule is restated across plugins and the proposed remedy is a CLAUDE.md sweep section with grep needles, the duplication is the defect — extract a skill (cross-plugin invocation is the sanctioned interface) and delete the sweep section
metadata:
  type: feedback
---

A CLAUDE.md section that tells the next agent which grep needles keep
N copies of a rule in step is not a fix; it is a maintenance contract
for a defect. When a fix round is choosing between "document the
sweep" and "remove the duplication", remove the duplication.

**Why:** on PR #224 the branch-name grammar ended up restated in five
places (`git-branch-create` as emitter, `pr-create`, `pr-link-issue`,
`plugins/github-prs/README.md`, `pr-reviewer`) with a CLAUDE.md
section "Sweep the branch-name grammar across plugins when it
changes" prescribing needles (`all-numeric`, `issue-<N`, `∩`,
`` `B` empty ``). Three review rounds chased instances of that class
one at a time — including a Low about one needle being wrap-fragile.
Edwin ruled the duplication itself the defect: encapsulate the parse
in a skill, delete the section entirely, replace it with nothing. The
Low about the needle dissolved with the section that carried it. This
is the agent-side instance of Edwin's standing "duplication is the
defect" and "simplification means less code" positions.

**How to apply:** the plugin file sandbox is what makes duplication
look forced — a bare cross-plugin `Read` cannot resolve. But **skill
invocation is not sandboxed** (`docs/plugin-authoring-constraints.md`
→ "Skill invocation is global and namespaced"), and that doc already
says to prefer invoking a real skill over sharing a lib. So:

- Duplicated *behavior* (a parse, a lookup, a derivation) → a new
  skill in the plugin that owns the concept, invoked by name from the
  other plugins. Add a `dependencies` edge in the consumer's
  `plugin.json` so the skill is present. Precedents to cite:
  `issue-developer` → `git-tools:git-branch-create` /
  `github-prs:pr-create`, `pr-reviewer` → `/issue-view`.
- Duplicated *config reads* → still the ladder in
  [[cross-plugin-lib-sharing-resolved-for-real-config-needs]].
- Split mechanism from policy: only the shared mechanism moves into
  the skill. Each consumer keeps its own policy about what to do with
  the result (here: `C ∩ B`, the one-member stand-in, the
  multi-member refusal, the per-issue verdicts), so the extraction
  does not flatten deliberate per-caller differences.

Registration surfaces for a new skill in this repo are the owning
plugin's `plugin.json` `description` and the root `README.md` roster
bullet — `.claude-plugin/marketplace.json` is per-plugin, not
per-skill, and `docs/plugin-migration-plan.md` is frozen.
