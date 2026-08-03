---
name: procsubst-redirect-position-unclassified
description: CLOSED — guardrails #225 briefly graded a `<(cmd)` in a REDIRECT position (`cat < <(cmd)`) by nobody while the argv spelling denied; the same PR wired descendProcSubsts to the redirect words too, so both positions now deny. Keep the technique: prove a widening is NEW by comparing the PR's classifier against a git-archive'd origin/main one.
metadata:
  type: reference
---

Guardrails #225 (PR #227) made an INPUT process substitution `<(cmd)`
reduce to `procSubstFD` (a `/dev/fd/<...>` token the containment walks
skip) instead of marking the enclosing command inexact. Mid-PR,
`descendProcSubsts` — the walk that classifies the substituted command on
its own terms, which is what makes that sound — was wired ONLY to the
`CallExpr` argv branch, so:

- ARGV position: `comm -3 <(cat ../sibling/.env) x` → inner `cat` escapes
  → **DENY**.
- REDIRECT position: `cat < <(cat ../sibling/.env)`, `wc -l < <(…)`,
  `< <(…)` → graded by nobody → outer command **ALLOWED** silently.

**Resolved in the same PR** (fix round after the review): `walkStmt` now
calls `descendProcSubsts` over every word of `stmt.Redirs` as well, so
both positions earn the same verdict, including the compound
(`{ cat; } < <(…)`) and redirect-only (`< <(…)`) spellings, and an output
substitution in a redirect (`cat > >(tee ../sibling/out)`) denies on its
write. Pinned by `TestProcSubstInRedirectPositionIsClassified_225`. Do not
re-report it as open — read that test first.

**Verified technique (do this, don't reason):** `git archive origin/main
plugins/guardrails/hooks/permission-gate | tar -x -C <tmp>`, drop a
throwaway `zz_docprobe_test.go` calling `classifyBash` into BOTH the PR
tree and the extracted main tree, `t.Logf` the verdict, run
`go -C <dir> test -run … -v .`. That is what proved the redirect-position
allow was a NEW widening rather than a pre-existing hole — main ASKed
every one of those shapes — and it is the cheapest way to grade any
"is this regression ours?" question on a classifier PR.

**Binary provenance recipe that worked on #227:** rebuild each committed
binary with `GOOS=… GOARCH=… CGO_ENABLED=0 go -C <permission-gate-dir>
build -trimpath -o <out> .` and `shasum -a 256` against
`hooks/bin/<goos>-<goarch>/permission-gate`. With `-trimpath` all three
(darwin-arm64, linux-amd64, linux-arm64) reproduced byte-identical SHA-256.

Related: [[reference_guardrails-binary-verification]],
[[reference_flag-model-cannot-swallow-containment-operands]].
