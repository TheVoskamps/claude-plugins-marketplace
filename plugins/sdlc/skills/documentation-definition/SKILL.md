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
  `.claude/rules/**`, `**/docs/rules/**`, every `SKILL.md`, every agent
  definition, and every output style.
- **Code** — everything else.

Claude reads instruction Markdown into its context, so a change to one
changes what an agent does. That is why it is implemented, fixed,
style-checked, and reviewed exactly as code is, inside the review loop,
while documentation is written once, by `docs-writer`, after it.
