---
name: documentation-definition
description: The three file classes of an sdlc run — documentation, instruction Markdown, and code — and the path rules that sort a file into one. Preloaded into the sdlc agents that decide which files they may edit, check, or review; not invoked from the user's slash menu.
user-invocable: false
---

# The Three File Classes

Every file in the repo is in exactly one class, decided by its path
alone:

- **Documentation** — any `README.md`, and any file under a `docs/`
  directory, at any depth in the repo, that is not under that
  directory's `rules/`.
- **Instruction Markdown** — `CLAUDE.md` at any depth,
  `.claude/rules/**`, `**/docs/rules/**`, and every Markdown file other
  than a `README.md` under a component directory, at any depth below
  it. A component directory is a plugin's `skills/`, `agents/`,
  `commands/` or `output-styles/`, and the project's own
  `.claude/skills/`, `.claude/agents/`, `.claude/commands/` or
  `.claude/output-styles/`. Markdown under a plugin's `payload/` is not
  instruction Markdown: it is a template rendered into another repo.
- **Code** — everything else.

Claude reads instruction Markdown into its context, so a change to one
changes what an agent does. That is why it is implemented, fixed,
style-checked, and reviewed exactly as code is, inside the review loop,
while documentation is written by `docs-writer`, after it.
