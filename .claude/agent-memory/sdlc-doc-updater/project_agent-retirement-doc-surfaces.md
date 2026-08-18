---
name: agent-retirement-doc-surfaces
description: When a PR retires an sdlc agent and replaces it with a differently-shaped mechanism, the rename sweep lands everywhere but leaves "previously did X" history sentences in consumer docs false, with the new name substituted into them
metadata:
  type: project
---

A PR that **retires** an sdlc agent (rather than adding a variant)
gets the mechanical rename right on every surface — the developer
sweeps `orchestrate/SKILL.md`, `git-review-pr`, `github-prs` docs,
`docs/plugin-authoring-constraints.md`, root `README.md` and
`CLAUDE.md`. What survives the sweep is the class of claim whose
*subject* moved:

- **History sentences with the new name substituted in.** `"This is
  the review-submission the ... pipeline previously performed as a raw
  gh pr review"` and `"This mirrors what <new thing> already does"` in
  `plugins/github-prs/skills/*/SKILL.md`: the retired agent did those
  things, the replacement never did, and the replacement usually
  *delegates* the behavior to the skill whose doc claims to mirror it.
  Read every "previously" / "mirrors what" / "already does" sentence
  in a consumer doc that a rename touched.

**Why:** a rename sweep matches on the old *name*; the defect is in
the *predicate* attached to it, which no grep for the old name
surfaces.

**How to apply:** after a retirement PR, grep the diff's new agent /
skill names in `plugins/github-prs/skills/`, and read the whole
sentence around each hit, not the hit. That plugin is usually already
version-bumped by the same PR, so the fix costs no extra bump. See
[[agent-variant-doc-surfaces]] and
[[no-blanket-predicate-over-a-list]].
