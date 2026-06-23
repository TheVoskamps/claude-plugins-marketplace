# permission-gate

A compiled (Go) PreToolUse hook that adjudicates the tool calls Claude
Code is about to make: **allow**, **deny**, **ask**, or **defer**. It is
the deterministic enforcement layer the OS sandbox structurally cannot
provide (issue #247). It replaces the shell hooks
`auto-approve-compound-commands.sh` and `worktree-file-guard.sh`.

## What it does

Two engines feed a three-bucket (plus defer) decision, ask-defaulting
(uncertainty escalates to a human, never to allow):

- **Engine A — command classifier** (`engine_a_bash.go`,
  `classify_command.go`, `rules.go`, `forbidden_forms.go`,
  `engine_a_mcp.go`): parses the Bash command to an AST
  (`mvdan.cc/sh/v3`) and classifies each simple command; branches on
  MCP tool names.
- **Engine B — path containment** (`engine_b_containment.go`,
  `classify_files.go`): resolves repo/worktree context with
  `git rev-parse` against the event's `cwd`, canonicalizes symlinks on
  both the git-derived root and the target, and blocks worktree escapes
  (#127) and cross-repo access (#148). Fail-closed on any git
  subprocess failure or timeout. Two refinements (#247): (1) a target
  whose canonical path lands under the real `~/.claude` is **deferred**,
  not denied as a cross-repo escape, so the `settings.json` allow-list
  governs the agent's required startup reads of its own global config;
  the carve-out is canonicalized on both sides so it cannot be
  symlink-escaped, and genuine sibling repos are still denied. (2) a
  file-mutating tool (Write/Edit/MultiEdit/NotebookEdit) whose
  canonical target is a `.git/config` is denied (the Engine B half of
  the #125 identity-write rule; Read of `.git/config` is not a write
  and is unaffected).

The decision is emitted as JSON on stdout with exit 0
(`permissionDecision: allow|deny|ask|defer`). Exit 2 + stderr is the
fail-closed backstop for crash / parse-error / panic / malformed-event
paths.

Every ASK and DENY is appended to an evolution log
(`~/.claude/logs/permission-gate.jsonl`, overridable via
`PERMISSION_GATE_LOG`) for promoting recurring ASKs into explicit
rules.

## Rules are compiled in

Policy lives in the binary, not on disk — a security gate's rule set
must not be runtime-editable. **Changing policy means editing the Go
source, re-running the test suite, rebuilding both binaries, and
recommitting them.**

## Build / test / cross-compile

```sh
# From the repo root:
go -C hooks/permission-gate test ./...      # run the test suite
go -C hooks/permission-gate vet ./...       # static checks

# Rebuild the committed binaries (pure Go, CGo disabled):
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
  go -C hooks/permission-gate build -trimpath -o ../bin/darwin-arm64/permission-gate .
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
  go -C hooks/permission-gate build -trimpath -o ../bin/linux-amd64/permission-gate .
```

Committed binaries live under `hooks/bin/<goos>-<goarch>/`
(`darwin-arm64` for this machine, `linux-amd64` for WSL2). The
`settings.json` registration selects the correct one per platform via
`uname`.

## Registration

`settings.json` wires the gate as a single PreToolUse hook matching
`Bash|Read|Write|Edit|MultiEdit|NotebookEdit|mcp__.*`, deployed to
`~/.claude/settings.json`.

## Deferred

The per-`(session, cwd)` `git rev-parse` cache (§8 of the design)
remains deferred. Worktree roots do not move mid-session, so it is a
pure optimization for the worktree-parallel case; build it only if
profiling shows the per-call fork bites.
