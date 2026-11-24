---
name: cc-all
description: Load all global Claude Code rules and principles from CLAUDE.md.
---

Run `claude-home`, then read `CLAUDE.md` in the directory it prints and
every file it includes, directly or through another included file. On a
non-zero exit, relay its stderr verbatim and stop.
