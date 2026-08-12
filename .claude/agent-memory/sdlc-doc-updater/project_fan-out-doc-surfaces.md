---
name: fan-out-doc-surfaces
description: A round that adds a caller-did-this parameter to a fan-out brief (--fetched/--head-sha) documents both ends but not the authoring constraint in /docs; and an owner-directed mechanical repoint leaves mid-sentence line-wrap stubs
metadata:
  type: project
---

A round that tunes a **parallel fan-out** — the pipeline fetches once
and passes `--head-sha` / `--fetched yes` so k disprovers skip their
own fetch — updates both ends of the brief (the pipeline's fan-out
step, the agent's Inputs list and its step 1) and stops there. Two
surfaces it leaves:

- **`docs/plugin-authoring-constraints.md` → "Fanning out parallel
  agents".** That section already carries the shared-ref-store
  consequence for *checkout* (detach or die at exit 128). Contention
  on `git fetch` is the same invariant with a second consequence, and
  a future fan-out author reads the section, not the sdlc pipeline.
  Generalize it as: spawning session fetches, and the receiving agent
  must still work when the assertion parameter is absent.
- **CLAUDE.md's sdlc sweep section.** It enumerates the review
  surfaces (pipeline skill, orchestrate's two sections,
  git-review-pr) but not the brief-vocabulary contract, which is
  prose on both sides and greppable only by parameter name.

The same commit's mechanical repoint (dropping a dangling
`~/.claude/rules/worktree-cleanup.md` pointer mid-paragraph) left
two-line stubs — `If the lock reason` / `does` / `not match…` — in
`git-tools/skills/git-cleanup-branches-and-worktrees/SKILL.md`. Same
class as [[issue-ref-sweep-artifacts]]: read the reflowed paragraph,
not the changed line.

**Why:** the fix round's author is looking at the two files that
implement the behavior; the constraint doc and the sweep index are
where the *next* author looks.

**How to apply:** on any sdlc fan-out or brief-parameter change, open
`docs/plugin-authoring-constraints.md`'s fan-out section and CLAUDE.md's
review-exception paragraph before deciding the round has no doc
impact. See [[checkout-contract-doc-surfaces]].
