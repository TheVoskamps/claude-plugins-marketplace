---
name: scratchpad-blocked-use-repo-claude-tmp
description: The harness-provided scratchpad dir under /private/tmp is write-blocked for worktree-isolated agents; put review bodies and scratch files under <worktree>/.claude/tmp/
metadata:
  type: reference
---

The system prompt advertises a session scratchpad under
`/private/tmp/claude-501/...`, but the worktree gate blocks Write
there ("resolves outside the current repository"). For a
worktree-isolated agent, all scratch files — review bodies for
`--body-file`, probe scripts, extracted blobs — go under
`<worktree-root>/.claude/tmp/<task-slug>/` (gitignored, allowed).

A fresh review worktree does NOT have that directory: the first
redirect into it fails with "no such file or directory". `mkdir -p`
it before the first `>` redirect (the mkdir is allowed; only the
/private/tmp path is blocked). Also: `echo ===` as a compound-command
separator fails under zsh (`== not found` — zsh `=cmd` expansion);
use a quoted string or separate Bash calls.

Related: [[json-payload-via-file-not-echo]] (why bodies go through a
file at all), [[git-sandbox-via-script-file]].
