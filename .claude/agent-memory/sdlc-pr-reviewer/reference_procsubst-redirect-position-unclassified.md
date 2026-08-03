---
name: procsubst-redirect-position-unclassified
description: In the permission-gate, descendProcSubsts (the walk that classifies a process substitution's inner command) is wired ONLY to the CallExpr argv branch, so a `<(cmd)` in a REDIRECT position (`cat < <(cmd)`, `wc -l < <(cmd)`) is classified by nobody while the outer command allows — an escaping/arbitrary-file read rides the allow track. Probe by building both the PR binary and origin/main's binary and comparing verdicts on the same shape.
metadata:
  type: reference
---

Since guardrails #225 (PR #227), an INPUT process substitution `<(cmd)`
reduces to `procSubstFD` (a `/dev/fd/<...>` token the containment walks
skip) and no longer marks the enclosing command inexact. `descendProcSubsts`
classifies the inner command on its own terms — but it is called ONLY from
the `CallExpr` argv branch of `extractSimpleCommands`. So:

- ARGV position: `comm -3 <(cat ../sibling/.env) x` / `cat <(cat sibling/.env)`
  → the inner `cat` escapes → correctly **DENIES**.
- REDIRECT position: `cat < <(cat ../sibling/.env)`, `wc -l < <(…)`,
  `grep x < <(…)`, `cat < <(cat /etc/passwd)` → inner command graded by
  nobody, redirect target reduces to procSubstFD which the walk skips →
  outer command **ALLOWS** silently.

**Verified technique (do this, don't reason):** `git archive origin/main
plugins/guardrails/hooks/permission-gate | tar -x -C <tmp>`, drop a
throwaway `zz_docprobe_test.go` calling `classifyBash` into BOTH the PR
tree and the extracted main tree, `t.Logf` the verdict, run
`go -C <dir> test -run … -v .`. On #227 main ASKed all these shapes; the
PR ALLOWs the redirect ones — proving it is a NEW widening, not a
pre-existing hole. The doc-updater flagged this as a "known gap" in the
README and the `applyRedirs` code comment but did not fix it.

**Binary provenance recipe that worked on #227:** rebuild each committed
binary with `GOOS=… GOARCH=… CGO_ENABLED=0 go -C <permission-gate-dir>
build -trimpath -o <out> .` and `shasum -a 256` against
`hooks/bin/<goos>-<goarch>/permission-gate`. With `-trimpath` all three
(darwin-arm64, linux-amd64, linux-arm64) reproduced byte-identical SHA-256.

Related: [[reference_guardrails-binary-verification]],
[[reference_flag-model-cannot-swallow-containment-operands]].
