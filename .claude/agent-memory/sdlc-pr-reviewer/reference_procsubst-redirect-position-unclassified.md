---
name: procsubst-redirect-position-unclassified
description: Guardrails #225's procSubstFD reduction leaks allow through EVERY position descendProcSubsts lacks a call site for — redirect (closed round 2), then item-list words, case patterns, and assignment RHS (found round 2, open at be6d64c); enumerate bash's substitution positions and probe each against BOTH binaries before believing any "covers both/all" claim.
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
(darwin-arm64, linux-amd64, linux-arm64) reproduced byte-identical SHA-256
— but only when built from the SAME source tree, comments included; see
[[reference_guardrails-binary-verification]] for pinning WHICH commit's
source a committed binary came from when the shasum does not match.

**Round 2 (be6d64c): the same reduction leaks through more positions.**
The class is "any word position whose exactness now propagates while
`descendProcSubsts` has no call site there", not "redirect words".
Measured ask → allow regressions beyond the redirect fix: `for f in
<(cat /etc/passwd); do cat "$f"; done` (staticForItems fans out and
binds the loop var to procSubstFD) and `x=<(cat /etc/passwd); cat "$x"`
(recordAssign puts procSubstFD into knownVars). Pre-existing allow on
BOTH binaries — the inner command is arbitrary, not just a read:
`for f in <(rm -rf ~/x); do echo x; done`, `select … in <(…)`,
`case <(…) in`, and the case-PATTERN position `case x in <(cmd))`.
Unchanged defers: bare `x=<(…)`, array `a=(<(…))`, `[[ -f <(…) ]]`.
When re-reviewing the fix, probe every row of that list again — a
"covers both/all positions" claim written from freshly-wired call sites
has been false twice on this PR.

Related: [[reference_guardrails-binary-verification]],
[[reference_flag-model-cannot-swallow-containment-operands]].
