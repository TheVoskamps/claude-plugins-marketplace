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
  MCP tool names. Constructs whose inner command is not statically
  resolvable — process substitution `<(…)` / `>(…)`, command
  substitution `$(…)` — are classified conservatively (the word is
  marked inexact, so the line never rides the allow track) rather than
  crashing; an earlier nil `ProcSubst` expander panicked on `<(…)`
  (#5).
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
  canonical target is anywhere under a `.git/` directory is denied (the
  Engine B half of the #125 identity-write rule, broadened from
  `.git/config` to the whole `.git/` tree in #35 — a hand-edit of
  `.git/hooks/*`, `.git/info/exclude`, or a nested/submodule `.git/`
  can inject hooks or corrupt repo state just as a `.git/config` write
  rewrites identity). Reads of `.git/` files are not writes and are
  unaffected. If you need a scratch file, write it under
  `<repo-root>/.claude/tmp/` (gitignored). The containment-escape denies
  (#127, #148) are **prescriptive** (#30): a write/edit escape names
  `<repo-root>/.claude/tmp/` as the scratch destination and warns
  against `.git/`, so an open-ended denial does not induce the model to
  improvise a bad landing spot. See
  [`rules/scratch-file-location.md`](../../rules/scratch-file-location.md)
  for the convention.

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
# From the repo root (the hook lives under plugins/guardrails/):
go -C plugins/guardrails/hooks/permission-gate test ./...   # run the test suite
go -C plugins/guardrails/hooks/permission-gate vet ./...    # static checks

# Rebuild the committed binaries (pure Go, CGo disabled):
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
  go -C plugins/guardrails/hooks/permission-gate build -trimpath -o ../bin/darwin-arm64/permission-gate .
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
  go -C plugins/guardrails/hooks/permission-gate build -trimpath -o ../bin/linux-amd64/permission-gate .
```

Committed binaries live under `plugins/guardrails/hooks/bin/<goos>-<goarch>/`
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
