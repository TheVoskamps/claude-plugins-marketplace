---
name: worktree-write-path-must-be-worktree-copy
description: Write/Edit are rejected on shared-checkout absolute paths in an isolated worktree, and the tool tracks Read state per exact path — so Read the worktree copy before writing it
metadata:
  type: feedback
---

In an `isolation: worktree` subagent, `Read` happily accepts an
absolute path into the **shared checkout**
(`<repo>/plugins/foo/SKILL.md`), but `Write`/`Edit` on that same path
fail with: "This agent is isolated in the worktree
`<repo>/.claude/worktrees/agent-<hash>`. Edit the worktree copy of
this file instead of the shared-checkout path."

The second half of the trap: the Read-before-Write requirement is
tracked **per exact path string**. Having read the shared-checkout
copy does not satisfy it for the worktree copy, so the retry needs its
own `Read` of the worktree path first — two wasted round trips per
file if you discover this one file at a time.

**Why:** reads outside the worktree are allowed (the boundary rule
only restricts writes), so nothing stops you from doing all your
exploration against the shared path and only finding out at the first
edit. Bare relative-path Bash commands (`grep`, `git`) already run in
the worktree, which makes the shared path feel equally live when it
is not.

**How to apply:** resolve the worktree root once at the start of the
run (it is your cwd; the harness names it in the env block) and prefix
**every** `Read` with it, not just the writes. Cheapest fix is to
never form a shared-checkout absolute path at all. Related: the gate
also refuses `git -C <abs-path> <subcommand>` outright — see
[[heredoc-commit-sandbox-gate]] for the sibling static-argv
restriction on git commands.
