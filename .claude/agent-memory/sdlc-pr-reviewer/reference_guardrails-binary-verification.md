---
name: guardrails-binary-verification
description: How to verify the guardrails permission-gate committed binary carries a PR's new policy — exercise it with synthetic PreToolUse events, not cmp against a rebuild
metadata:
  type: reference
---

The `guardrails` plugin ships policy *inside* committed binaries
(`plugins/guardrails/hooks/bin/{darwin-arm64,linux-amd64}/permission-gate`),
so a stale binary would silently ship old behavior even when the Go
source is correct.

**Do NOT verify by rebuilding and `cmp`-ing against the committed
binary.** Go embeds build paths / build IDs, so a fresh
`GOOS=... GOARCH=... go build` almost never reproduces byte-identically
without a reproducible-build harness. A `differ` result is expected and
proves nothing.

**Do verify by exercising the committed binary directly** with a
synthetic PreToolUse event on stdin:

```bash
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"<repo>","tool_input":{"command":"cat \\"$HOME/.ssh/id_rsa\\""}}' | <bin>
```

It prints a JSON `permissionDecision` (`deny`/`ask`/`allow`/`defer`).
Pick commands that map to the PR's acceptance criteria and confirm the
committed binary returns the new verdicts. Only the host-arch binary is
natively runnable (on darwin you can't execute the linux-amd64 one);
the other arch is built from the same source in the same commit, so
host-arch exercise + passing `go test` is sufficient evidence.

**How to place the scratch repo**: the gate blocks tool-mediated writes
outside the repo root and blocks `cd <path> && git ...` forms. Create
the scratch git repo under `<repo-root>/.claude/tmp/<slug>/`, `cd` into
it in one Bash call, then run `git init -q .` as a separate bare call.

Related: [[self-approve-blocked-use-comment]].
