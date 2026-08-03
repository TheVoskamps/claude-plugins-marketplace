---
name: procsubst-redirect-position-unclassified
description: Guardrails #225's procSubstFD reduction leaked allow through every position descendProcSubsts lacked a call site for — redirect, item-list words, case patterns, assignment RHS — until round 3 replaced the hand-listed call sites with a per-statement syntax.Walk, and round 4 did the same for `$(…)`; probe positions against BOTH binaries before believing any "covers both/all" or "inexactness catches it" claim.
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

**Round 2 (be6d64c): the same reduction leaked through more positions.**
The class was "any word position whose exactness now propagates while
`descendProcSubsts` has no call site there", not "redirect words".
Measured ask → allow regressions beyond the redirect fix: `for f in
<(cat /etc/passwd); do cat "$f"; done` (staticForItems fans out and
binds the loop var to procSubstFD) and `x=<(cat /etc/passwd); cat "$x"`
(recordAssign puts procSubstFD into knownVars). Pre-existing allow on
BOTH binaries — the inner command is arbitrary, not just a read:
`for f in <(rm -rf ~/x); do echo x; done`, `select … in <(…)`,
`case <(…) in`, and the case-PATTERN position `case x in <(cmd))`.

**Round 3 closed the class structurally — do not re-report these rows
as open.** `descendProcSubsts` no longer takes a word from a hand-listed
call site: it takes a NODE and finds substitutions with `syntax.Walk`,
applied per statement to `stmt.Redirs` and `stmt.Cmd`, stopping at any
nested `*syntax.Stmt` (the main walk reaches those). Every row above now
DENIES, as do the positions round 2 recorded as "unchanged defers"
(array element `a=(<(…))`, `[[ -e <(…) ]]`) and the ones no round had
listed (an inline `FOO=<(…) cmd` prefix, `export y=<(…)`). Pinned by
`TestProcSubstGradedInEveryWordPosition_225` (verdict rows, each with a
substitution-free control) and `TestProcSubstDescentIsExhaustive_225`
(structural: graded count == the parser's `ProcSubst`-node count). The
one position bash runs but the gate cannot see is an unquoted parameter
expansion word (`: ${Q:-<(cmd)}` runs it, the quoted spelling does not),
where `mvdan.cc/sh` reports no `ProcSubst` node at all. A here-document
body only looks like one: bash takes `<(…)` literally there.

**Round 4 closed the `$(…)` class the same way — two claims above were
WRONG, and one of them was mine.** "A non-plain expansion leaves the word
inexact, so it cannot ride the allow track" is false: inexactness stops
the allow track ONLY where the inexact word rides a command the walk
emits. A `for`/`select` item list, a `case` subject or pattern, an inline
`VAR=… cmd` prefix, an array element, a `[[ … ]]` operand and an
assignment RHS emit no command, so
`for f in ${Q:-<(cat ../sib/.env)}; do echo x; done` and
`for f in $(cat ../sib/.env); do echo x; done` both ALLOWed — measured at
PR #227's merge base, so pre-existing, not a regression. And the
argv-position `$(…)` body was not merely "a deferring class": every
non-emitting position of it allowed outright. `descendCmdSubsts` now
takes a NODE too, runs per statement beside `descendProcSubsts`, and is
pinned by `TestCmdSubstGradedInEveryWordPosition_225` /
`TestCmdSubstDescentIsExhaustive_225`. Its one exception is an
allowlisted ANCHOR substitution, skipped rather than graded
(`TestAnchorCmdSubstIsNotDescendedInto_225`) because bare `pwd` earns no
allow of its own and descending would turn `cat "$(pwd)/x"` into a
prompt. The `${Q:-<(cmd)}` PROCESS-substitution row is the one hole left,
and it is unclosable — there is no node to hang a descent off; the
`${Q:-$(cmd)}` spelling IS graded, in both quotings.

The lesson survives the fix: a "covers both/all positions" claim written
from freshly-wired call sites was false twice on this PR, which is why
the third fix was made structural instead of enumerated.

**Round 5 verified all three structural claims and found the round's real
defects elsewhere.** Independently confirmed, so do not re-litigate:
mvdan/sh v3.13.1 reports `ProcSubst=0` for `${Q:-<(cmd)}` in BOTH quotings
(the default word is a single `*syntax.Lit` holding the raw text) while
`${Q:-$(cmd)}` reports `CmdSubst=1`; the anchor skip is exact argv
token-equality against a closed 3-form allowlist on a plain single-statement
`CallExpr`, and the RESOLVED value still hits the `.git/` deny and cross-repo
deny; the emitting-position `defer -> deny` denies only where the direct
spelling denies (eight everyday shapes probed, zero new denies). "Unclosable"
is true of GRADING the `${Q:-<(cmd)}` inner command but not of WITHHOLDING
the allow — that distinction is a follow-up issue, not a finding, because the
row allows at the merge base too.

The lesson for the next round: on a PR whose whole story is one mechanism,
the surviving defects are in the parts nobody framed as the story. Here both
were flag values on the newly widened read track — see
[[reference_new-allow-track-entries-need-flag-value-audit]].

Related: [[reference_guardrails-binary-verification]],
[[reference_flag-model-cannot-swallow-containment-operands]],
[[reference_new-allow-track-entries-need-flag-value-audit]].
