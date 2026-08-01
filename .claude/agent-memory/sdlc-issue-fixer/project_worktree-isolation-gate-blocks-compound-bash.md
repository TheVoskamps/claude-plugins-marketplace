---
name: worktree-isolation-gate-blocks-compound-bash
description: In a worktree-isolated agent, a multi-line Bash call mixing var assignment + mkdir + printf-redirect + npx is refused as "too complex to verify that it stays inside the worktree" even when every path IS in-bounds — create scratch files with the Write tool instead
metadata:
  type: project
---

Creating a lint probe file during PR #211 with a single Bash call of
the shape:

```text
R=<worktree-root>
mkdir -p $R/.claude/tmp/<slug>
printf '...' > $R/.claude/agent-memory/probe.md
npx markdownlint-cli2 '...'
```

was refused outright: "this command is too complex to verify that it
stays inside the worktree; break it into plain, separate commands.
Refusing to run it." Every path in that command was inside the
worktree — the block is about *static verifiability*, not an actual
boundary violation.

**Why:** this is a different gate from the repo-boundary one in
[[repo-boundary-gate-blocks-any-tool-arg-outside-repo]]. That gate
fires when an argument *resolves outside* the repo. This one fires
when the command shape (shell variable holding a path, then a
redirect through it) means the harness cannot statically prove
in-bounds-ness. Same family as the static-argument gate on git in
[[commit-heredoc-gate]] and [[git-command-form-gate-cd-then-bare-git]]:
a path that arrives via `$VAR` defeats static classification.

**How to apply:** in a worktree-isolated agent, do not build scratch
files with shell redirects behind a `$VAR` path. Use the `Write` tool
with a worktree-absolute literal `file_path` (see
[[worktree-path-not-main-clone]]), then run the consuming command as a
separate bare Bash call using a *relative* path — pwd is already the
worktree root, so relative paths are both correct and statically
in-bounds. `rm -f`/`rm -rf` cleanup with literal absolute paths is
fine; it was only the assignment-plus-redirect shape that was refused.
