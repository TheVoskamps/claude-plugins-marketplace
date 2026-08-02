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
two different byte-contents — a main-clone `Read` of a file this PR
extends returns the main-branch version, missing the PR's additions,
while `wc -l` / `git show` run through Bash report the worktree copy's
real length. That stale map makes every subsequent Edit match against
the wrong content. Bash commands with *relative* paths correctly hit the
worktree (pwd is the worktree root), which is what exposes the
discrepancy.

**Writes fail loudly; reads do not.** `Write` and `Edit` against a
main-clone path are refused outright with "This agent is isolated in the
worktree ... Edit the worktree copy of this file instead", so the
stale-write hazard is caught by the harness. `Read` has no such guard —
it silently returns the other checkout's bytes. The refusal also costs a
wasted round-trip on every slip, and the slip is easy to make even while
knowing the rule: the worktree segment
(`.claude/worktrees/agent-<id>/`) sits in the *middle* of a long path,
so a path reconstructed from recall rather than copied drops it. Any
`.claude/`-rooted destination is the most slip-prone — the agent-memory
tree and the `.claude/tmp/<task-slug>/` scratch dir both — precisely
because a path that already opens with `.claude/` *looks* worktree-local
while still missing the `.claude/worktrees/agent-<id>/` prefix, and both
are long and familiar from other checkouts.

**How to apply:** the harness env block prints
`Working directory: <worktree>`. Copy that worktree root verbatim and
append to it; never retype a long path from recall. Build all
Read/Edit/Write `file_path` values that way. If a Read's line count
disagrees with `wc -l` / `git show HEAD:<file> | wc -l` run via Bash
(which uses the worktree pwd), you are reading the wrong clone — switch
to the worktree-absolute path. See [[verify-territory-not-relay]] for
the general map-vs-territory discipline this is an instance of.
