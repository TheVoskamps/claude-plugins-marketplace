---
name: sdlc-config-repo
description: Interactively create or merge-update the shared repo sdlc config, `<repo-root>/.sdlc/repo-config.yml` (tier 2 — tracked, every user of this repo).
---

# sdlc Config: Shared Repo

You are writing tier 2, the shared repo file. Read
`skills/lib/sdlc-config.md` for its path, its keys, and the writer
steps, and run those steps against that file. That contract is the only
statement of them; this skill does not restate them.

Abort, saying so, when `git rev-parse --show-toplevel` fails: there is
no repository to write into.

This file is tracked, so a value written here applies to everyone who
runs `/sdlc:orchestrate` in this repo once it is committed, unless
their own repo user file overrides it. Say that before the first
question. Write that one file and nothing else.
