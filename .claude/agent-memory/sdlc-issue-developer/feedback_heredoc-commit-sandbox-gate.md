---
name: heredoc-commit-sandbox-gate
description: git commit -m "$(cat <<'EOF' ...)" is blocked by the sandbox gate in this worktree; use git commit -F <file> instead
metadata:
  type: feedback
---

`git commit -m "$(cat <<'EOF' ... EOF)"` — the heredoc-into-command-substitution
form recommended by the git-workflow doc for multi-line commit messages —
is blocked in this repo's subagent worktrees with: "a 'git' command whose
arguments are not all static literals ... cannot be statically classified".
The sandbox's git-argument gate rejects any git invocation containing a
command substitution, even a static one.

**Why:** the harness's CVE-2025-59536-style gate statically classifies
git command arguments and refuses to reach into `$(...)` to verify it's
safe, regardless of content.

**How to apply:** when a commit message needs to be more than one line,
write the message to a file under `.claude/tmp/<task-slug>/` with the
`Write` tool, then run `git commit -F <path>`. This produces an
identical commit (same multi-paragraph body, same trailers) without
tripping the gate. Clean up the scratch file at end-of-run alongside the
rest of `.claude/tmp/<task-slug>/`.
