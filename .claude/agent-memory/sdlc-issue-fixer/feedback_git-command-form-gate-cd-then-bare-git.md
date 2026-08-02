---
name: git-command-form-gate-cd-then-bare-git
description: the CVE-2025-59536 harness gate blocks BOTH "cd <path> && git ..." AND "git -C <path> ..."; the only accepted form is a bare `cd <path>` Bash call followed by a SEPARATE bare `git <subcommand>` call
metadata:
  type: feedback
---

In a subagent worktree, cwd does not persist across Bash calls, which
tempts two compound forms to run a git command against the worktree in
one call — both are rejected by the harness's CVE-2025-59536 gate:

- `cd <worktree-path> && git status` → refused as
  `Forbidden form 'cd <path> && git ...'`
- `git -C <worktree-path> status` → refused as
  `Forbidden form 'git -C <abs-path> <subcommand>'`

**Why:** both forms let a single Bash call point git at an arbitrary
directory without the harness being able to gate on the resulting cwd
independently: the gate fires "regardless of context" per its own
message.

**How to apply:** the ONLY accepted pattern is two separate Bash tool
calls: first a bare `cd <worktree-path>` (no `&&`, nothing chained
after it), then in a later, separate Bash call, a bare `git
<subcommand>` with no `-C` and no leading `cd`. cwd persists across
Bash calls within one subagent turn once set this way (confirmed
working: `cd` alone, then `git stash push -- <file>` in the next call,
succeeded). This corrects [[worktree-path-not-main-clone]], which
covers Read/Edit path selection but not this Bash git-invocation gate
— the two are different mechanisms and both matter in a worktree
subagent.
