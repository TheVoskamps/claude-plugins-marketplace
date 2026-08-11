---
name: permgate-go-comment-edits-need-binary-rebuild
description: Editing a COMMENT in plugins/guardrails/hooks/permission-gate/*.go invalidates the three committed binaries' byte-identity, so a doc-updater pass on gate Go comments must rebuild and stage all three binaries too.
metadata:
  type: project
---

`plugins/guardrails/hooks/bin/<goos>-<goarch>/permission-gate` are
committed build artifacts of the sources beside them, and the review
pipeline verifies provenance by rebuilding and comparing (see
[[project_guardrails-permgate-docs-locality]] for what else lives
there). Go embeds file:line in the binary, so **adding or removing even
a comment line shifts them** and a rebuild-compare shows a delta the
reviewer has to adjudicate.

**Why:** a doc-updater pass that fixes a stale Go doc comment — squarely
in scope — silently leaves the shipped binaries built from a source
tree that no longer exists. On #225 this bit on `engine_a_bash.go`.

**How to apply:** after editing any `.go` file under
`hooks/permission-gate/`, run `gofmt -l .`, then rebuild all three with
the README's exact commands (`GOOS=… GOARCH=… CGO_ENABLED=0 go -C
plugins/guardrails/hooks/permission-gate build -trimpath -o
../bin/<goos>-<goarch>/permission-gate .`) and stage the binaries in the
doc commit. They cross-compile from the mac with no extra setup and take
seconds. Smoke-test the darwin one by piping a `PreToolUse` event JSON
from a file (the active gate blocks the inline `echo … | binary` form —
see [[feedback_gh-pr-diff-and-active-gate]]).

Also check `gofmt -l .` even when you touched no Go file: on #225 the
developer's new `readOnlyUtilities` map entry left the map's key
alignment unformatted, and a doc pass is the cheapest place to catch it.
