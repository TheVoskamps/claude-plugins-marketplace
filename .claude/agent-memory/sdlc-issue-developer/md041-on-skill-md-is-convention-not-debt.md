---
name: md041-on-skill-md-is-convention-not-debt
description: markdownlint MD041 fires on every plugins/*/skills/**/SKILL.md by design; do not "fix" it under the leave-Markdown-clean rule
metadata:
  type: project
---

`npx markdownlint-cli2` reports `MD041/first-line-heading/first-line-h1`
on essentially every `plugins/*/skills/**/SKILL.md` in this repo, always
at line 6 — the first prose line after the YAML frontmatter. Leave it
alone. It is the repo's shape for skill files, not accumulated debt.

**Why:** a `SKILL.md` body is a *prompt* the model reads, not a
document, so it opens with an instruction ("You are running the
`/foo` skill...") rather than an H1. Measured on this tree: MD041 hits
33 skill files and is the **only** error class across all of them —
zero non-MD041 errors. A rule that fires uniformly and alone, in a repo
whose Markdown is otherwise spotless, is a tolerated convention.

**How to apply:** the global "Leave Markdown clean" rule (`core-principles.md`
§4) tells you to fix pre-existing errors in files you touch. That rule
would push you into adding an H1 to a skill file — which changes the
prompt payload the model receives and, swept properly per "sweep the
class", would churn 33 files across every plugin. Don't. When you edit a
`SKILL.md`, verify you introduced **no new** error classes (stash the
diff and re-lint the base to compare counts, per
[[feedback_stale-origin-main-ref-after-fetch]]'s habit of checking the
territory), then say in the PR body that the remaining MD041 hits are
pre-existing and why. Changing the convention is a repo-wide decision
for Edwin, not a doc-pass sweep — the same shape as the `Phase 1` /
`Phase 2` heading carve-out already written into `CLAUDE.md`.

`lib/*.md` files under a plugin's `skills/` are ordinary documents and
DO carry an H1 — they lint clean, and a new one you write should too.
