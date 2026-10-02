---
name: documentation-definition
description: The three file classes of an sdlc run — documentation, instruction Markdown, and code — and which agent owns an edit to each. Preloaded into the sdlc agents that decide which files they may edit or review; not invoked from the user's slash menu.
user-invocable: false
---

# File Classes: Documentation, Instruction Markdown, and Code

Every file in the repo is in exactly one of three classes:

- **Documentation** is any `README.md`, and any file under a `docs/`
  directory, at any depth in the repo, that is not under that
  directory's `rules/`.
- **Instruction Markdown** is `CLAUDE.md` at any depth,
  `.claude/rules/**`, `**/docs/rules/**`, every `SKILL.md`, every agent
  definition, and every output style. Claude reads these into its
  context, so a change to one changes what an agent does.
- **Code** is everything else.

## Review

Instruction Markdown is reviewed as code. Documentation is the only
class outside the review.

## Ownership

Who edits a file is decided by its class and by the files-affected
sections, as `sdlc:orchestrate-readiness` defines them, of the issues
the PR closes:

- **Code** is `issue-developer`'s and `issue-fixer`'s, whether a
  files-affected section lists it or not.
- **Instruction Markdown a files-affected section lists** is the
  deliverable, and is `issue-developer`'s and `issue-fixer`'s like
  code.
- **Instruction Markdown no files-affected section lists** is
  `docs-writer`'s.
- **Documentation** is `docs-writer`'s, always.

An agent whose change makes a file it does not own wrong leaves that
file alone and hands the edit to `docs-writer`. That handoff is the
designed route for the edit, never a failure, an escalation, or open
work.
