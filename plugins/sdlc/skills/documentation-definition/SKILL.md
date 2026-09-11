---
name: documentation-definition
description: What counts as documentation in an sdlc run, as opposed to code. Preloaded into the sdlc agents that decide which files they may edit or review; not invoked from the user's slash menu.
user-invocable: false
---

# What Counts as Documentation

Documentation is any `README.md`, and any file under a `docs/`
directory, at any depth in the repo, that is not under that
directory's `rules/`.

Everything else is code, including `CLAUDE.md` at any depth,
`.claude/rules/**`, `**/docs/rules/**`, every `SKILL.md`, and every agent
definition. Claude reads those into its context, so a change to one
changes what an agent does, and it is reviewed as code.
