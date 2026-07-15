---
name: worktree-path-not-main-clone
description: In a worktree subagent, Read/Edit the worktree-absolute path, not the main-clone path — the latter is a different checkout and gives a stale file view
metadata:
  type: feedback
---

Always address files by their **worktree-absolute** path
(`.../.claude/worktrees/agent-<id>/plugins/...`), never the main-clone
path (`.../claude-plugins-marketplace/plugins/...`), when running as a
worktree subagent.

**Why:** the orchestrator's primary clone has the DEFAULT branch checked
out; the worktree has the PR branch. The same relative file resolves to
two different byte-contents. On issue #104 I Read the main-clone
absolute path for `payload/lib/config.sh` and got a 605-line view (the
main-branch version, missing the render function this PR added), while
`wc -l`/`git show` on the worktree copy showed 834 lines. That stale map
would have made every Edit match against the wrong content. Bash
commands with *relative* paths correctly hit the worktree (pwd is the
worktree root), which is what exposed the discrepancy.

**How to apply:** the harness env block prints
`Working directory: <worktree>`. Build all Read/Edit/Write `file_path`
values from that worktree root. If a Read's line count disagrees with
`wc -l` / `git show HEAD:<file> | wc -l` run via Bash (which uses the
worktree pwd), you are almost certainly reading the wrong clone — switch
to the worktree-absolute path. See [[verify-territory-not-relay]] for the
general map-vs-territory discipline this is an instance of.
