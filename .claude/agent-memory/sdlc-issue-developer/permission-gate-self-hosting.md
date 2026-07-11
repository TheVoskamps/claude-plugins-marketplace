---
name: permission-gate-self-hosting
description: The guardrails permission-gate is ACTIVE in this environment while you edit its source; it enforces its own rules on your commands during the task.
metadata:
  type: project
---

The compiled guardrails permission-gate
(`plugins/guardrails/hooks/permission-gate/`) is a live PreToolUse hook
in this environment. When you work on it (or anything else in this
repo), it adjudicates YOUR own tool calls in real time.

**Why:** it is registered in the harness `settings.json` and runs on
every Bash/Read/Write/Edit call. It is not a passive artifact you build
and forget — it gates the very commands you use to build it.

**How to apply:** concrete forms it blocks that bit me during issue
#113 (all correctly — do not fight them):

- `git commit -m "$(cat <<EOF ...)"` and any git with a command
  substitution / heredoc arg → DENY (non-static argv, #64 precondition).
  Write the commit message to a file under
  `<worktree>/.claude/tmp/<slug>/` and use `git commit -F <file>`.
  Same for PR bodies: `gh pr create --body-file <file>`.
- `mkdir`/`Write` to `<primary-clone>/.claude/tmp/...` → DENY (resolves
  to the primary clone, not this worktree). Anchor scratch to
  `$(git rev-parse --show-toplevel)/.claude/tmp/` — i.e. the worktree's
  own `.claude/tmp/`, which the gate names in its remediation.
- `sed -n '/A/,/B/p'` on command output → DENY (the range address
  resolves as an out-of-repo path). Use `grep` for slicing instead.
- `git -C <abs-path> <sub>` → forbidden form even inside a subagent
  (harness prompts regardless). Just run bare `git <sub>`; the subagent
  cwd is already the worktree root on every Bash call.
- `gh api ...` (REST or graphql) → under the OLD binary, graphql denies
  and REST asks. After [[gh-api-gate-113]] lands, query-only graphql
  and allow-listed REST GETs allow. Either way, plain `gh` subcommands
  (`gh issue view`, `gh pr create`, ...) are allowed.

Acceptance for permission-gate changes is verified by piping synthetic
PreToolUse event JSON (`{"hook_event_name":"PreToolUse",
"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"..."}}`) into
the locally rebuilt binary and reading
`.hookSpecificOutput.permissionDecision` — no live GitHub calls needed.
Build both committed binaries with the README's exact commands
(CGO_ENABLED=0, -trimpath, into `../bin/<goos>-<goarch>/`).
