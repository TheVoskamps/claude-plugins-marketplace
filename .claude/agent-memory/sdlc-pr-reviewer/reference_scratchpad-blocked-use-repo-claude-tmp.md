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

Related: [[json-payload-via-file-not-echo]] (why bodies go through a
file at all), [[git-sandbox-via-script-file]].
