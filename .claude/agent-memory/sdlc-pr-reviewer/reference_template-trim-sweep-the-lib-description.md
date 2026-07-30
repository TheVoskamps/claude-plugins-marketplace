---
name: template-trim-sweep-the-lib-description
description: When a PR trims the /repo-config generated-body template, also check lib/repo-config.md's three-part body description and cross-references — the predecessor PR set that sweep precedent
metadata:
  type: reference
---

A PR that trims the canonical body template in
`plugins/issues/skills/repo-config/SKILL.md` must be checked against
`plugins/issues/skills/lib/repo-config.md`, which independently
*describes* the generated file's structure ("A body. … and a prose
section that documents the file's own fields."). That description is
a second doc surface asserting what the template emits, and it does
not appear in the template-trim diff.

**Why:** PR #194 (the predecessor trim) established the precedent —
it swept a `fields.*.default` cross-reference in that same lib file
that its own template trim invalidated. So this is a known,
already-recognized class here, not a novel nit. The successor PR #199
trimmed the template further (to heading + one directive line) without
re-checking the lib's body description, leaving it describing prose
the template no longer emits.

**How to apply:** on any `/repo-config` template change, grep
`plugins/issues/skills/lib/repo-config.md` for `body`, `prose`,
`heading`, and `hand-edit` before accepting an "all sites updated"
claim. Also verify the `# Repo Config` heading survives — the
tracker-metadata block terminates at the first column-0 non-blank
line (`skills/lib/issue.md`: "The block runs until the next column-0
non-blank line (a new top-level key) or EOF"), so the heading is the
block terminator, not decoration. Related: [[sweep-stale-behavior-comments-in-sibling-files]].
