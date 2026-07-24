---
name: claude-plugin-validate-silent-on-pass
description: claude plugin validate does check skill frontmatter, but prints a "Validating skill:" line only on failure — a pass shows the manifest line alone
metadata:
  type: feedback
---

`claude plugin validate <plugin-dir>` validates each skill's
frontmatter, not just `plugin.json`. On success it prints only
`Validating plugin manifest: ...` and `✔ Validation passed`. The
`Validating skill: <path>` line appears **only** when that skill fails.

**Why:** the silent-on-pass output invites the wrong conclusion — that
the command skipped the skills and the clean run is vacuous. Verified
by copying a plugin to a scratch dir and giving a `SKILL.md` an
unquoted colon-space `description:`; validate then printed the
`Validating skill:` line and `frontmatter: YAML frontmatter failed to
parse`.

**How to apply:** treat a clean `claude plugin validate` as real
evidence that every skill's frontmatter parses. Do not re-probe to
confirm the command works, and do not claim in a PR that frontmatter
went unchecked. Agent frontmatter is not confirmed to be covered — only
skills were probed — so for a new agent file also eyeball the
`description:` for an unquoted colon-space, which is the failure mode
`docs/plugin-authoring-constraints.md` documents.
