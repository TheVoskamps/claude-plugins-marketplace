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

**How to apply:** concrete forms it blocks that bit me during
issue #113 (all correctly — do not fight them):

- `git commit -m "$(cat <<EOF ...)"` and any git with a command
  substitution / heredoc arg → DENY (non-static argv, #64 precondition).
  Write the commit message to a file under
  `<worktree>/.claude/tmp/<slug>/` and use `git commit -F <file>`.
  Same for PR bodies: `gh pr create --body-file <file>`. Since #229 that
  `<file>` must also be CONTAINED — the gate now runs read containment on
  the local files a gh publish verb sends to GitHub, so a body/notes file
  outside the worktree denies with the ordinary cross-repo read message.
  Anchoring scratch to `<worktree>/.claude/tmp/` satisfies both rules at
  once; the harness scratchpad is fine too.
- `mkdir`/`Write` to `<primary-clone>/.claude/tmp/...` → DENY (resolves
  to the primary clone, not this worktree). Anchor scratch to
  `$(git rev-parse --show-toplevel)/.claude/tmp/` — i.e. the worktree's
  own `.claude/tmp/`, which the gate names in its remediation.
- `sed -n '/A/,/B/p' <in-repo-file>` and a path-shaped `grep` PATTERN
  used to DENY (the regex was tested as an out-of-repo path). Fixed in
  #225 by giving the read track a per-program operand grammar, so no
  workaround is needed once that gate binary is installed. The
  workaround-era caveat still applies mid-task: the gate adjudicating
  YOUR calls is the installed plugin cache's binary, so while you are
  editing the fix it is still main's pre-fix behavior you are hitting.
- `git -C <abs-path> <sub>` → forbidden form even inside a subagent
  (harness prompts regardless). Just run bare `git <sub>`; the subagent
  cwd is already the worktree root on every Bash call.
- `gh api ...` (REST or graphql) → under the OLD binary, graphql denies
  and REST asks. After [[gh-api-gate-113]] lands, query-only graphql
  and allow-listed REST GETs allow. Either way, plain `gh` subcommands
  (`gh issue view`, `gh pr create`, ...) are allowed.
- A `for f in …; do …; done` loop (or any multi-construct one-liner)
  containing a redirect → DENY with "this command is too complex to
  verify that it stays inside the worktree; break it into plain,
  separate commands". This bites exactly when probing the rebuilt
  binary with several synthetic event JSONs: run one
  `<binary> < <event>.json` per Bash call instead of looping. The
  inline-env workaround is closed too — `PERMISSION_GATE_LOG=… <binary>`
  and `env PERMISSION_GATE_LOG=… <binary>` are both the denied
  inline-assignment form, so ASK/DENY probes append to the real
  `~/.claude/logs/permission-gate.jsonl`. That is the log's normal
  purpose; don't try to redirect it.

Forms that turned out to be **allowed** (issue #216) — don't invent
workarounds for these:

- `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go -C <dir> build ...` — the
  README's literal cross-compile recipe passes. The inline-assignment
  denial noted above is narrower than "any leading `VAR=`".
- `podman run --rm -i -v <abs-worktree-path>:/wt:ro <image> sh /wt/...`
  including the host bind-mount.
- `mkdir -p <relative-path>` and `>` redirects, when relative to the
  worktree cwd.

The **Edit tool** enforces the worktree boundary independently of the
gate: editing a `<primary-clone>/...` absolute path fails with "This
agent is isolated in the worktree ... Edit the worktree copy". Reading
the primary clone's copy is allowed, so it is easy to Read one path and
then try to Edit it — always anchor edit paths to the worktree root.

Acceptance for permission-gate changes is verified by piping synthetic
PreToolUse event JSON (`{"hook_event_name":"PreToolUse",
"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"..."}}`) into
the locally rebuilt binary and reading
`.hookSpecificOutput.permissionDecision` — no live GitHub calls needed.
Build all three committed binaries with the README's exact commands
(CGO_ENABLED=0, -trimpath, into `../bin/<goos>-<goarch>/`):
`darwin-arm64`, `linux-amd64`, `linux-arm64`.
