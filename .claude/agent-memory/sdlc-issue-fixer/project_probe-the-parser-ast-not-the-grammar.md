---
name: probe-the-parser-ast-not-the-grammar
description: where mvdan/sh parks a statement's Redirs is not what bash grammar suggests — a bare `> f` has Cmd==nil, and `a && b > f` / `f() { …; } > f` park it on the INNER stmt; probe with a throwaway in-package test, don't reason
metadata:
  type: project
---

The permission-gate walks a `mvdan.cc/sh/v3/syntax` AST. When a fix
depends on *which node* a construct hangs off, measure it — a
throwaway `zz_probe_test.go` in the package that parses a list of
command strings and `t.Logf`s `%T` of `stmt.Cmd` plus `len(stmt.Redirs)`
costs one minute and deletes cleanly.

**Why:** on PR #208 three assumptions I would otherwise have shipped
were wrong or would have added dead code:

- `> /tmp/x` (the truncate idiom) parses to a `Stmt` with
  **`Cmd == nil`** and one redirect. An early `if stmt.Cmd == nil
  { return }` silently drops it — which is exactly the ungraded-write
  hole the round was fixing.
- `a && b > f` and `a | b > f` park the redirect on the **inner** `Y`
  statement; the outer `BinaryCmd` statement has `len(Redirs) == 0`.
- `f() { a; } > f` parks it on the **function body's** statement, not
  on the `FuncDecl`'s own statement.

So the interesting arms were `Block`, `Subshell`, `IfClause`,
`ForClause`, `WhileClause`, `CaseClause` — and the nil-`Cmd` case that
no grammar-level reasoning surfaces at all.

**Probe BOTH sides when the question is "which positions must I
grade": does real bash run it, and does the parser report a node for
it.** They disagree, in both directions, and only the intersection is
work:

- `.claude/tmp/<slug>/probe.sh` — one `eval` per position whose inner
  command `touch`es a marker, then test for the marker (add a
  `sleep 0.3`; a substitution is asynchronous). On #227 this said bash
  RUNS `<(…)` in a `for`/`select` item list, a `case` word *and* a
  `case` **pattern**, an array element, an inline `FOO=<(…) cmd`
  prefix, `[[ -e <(…) ]]`, and an unquoted `${Q:-<(…)}` — but NOT a
  here-document body, and NOT the quoted `"${Q:-<(…)}"`.
- `zz_probe_test.go` — per row, count the nodes
  (`syntax.Walk` + a type assertion) and count what the walk graded.
  mvdan/sh reports **no** `ProcSubst` node inside a parameter
  expansion's word or a heredoc body, so those two positions are
  ungradeable however bash behaves, and saying so in a comment beats
  claiming coverage.

A position bash does not run must not be graded (false denial); a
position the parser cannot see cannot be graded at all — say which is
which rather than writing one "known gap" sentence over both.

**How to apply:** before writing an AST-shape claim into a comment or
a test ("the parser puts X on Y"), probe it. Then state the measured
fact in the comment — the whole point of the package's
no-issue-references rule is that a comment must stand on its own, and
"the parser parks this here" is only worth writing if it was checked.
Verify the resulting verdicts against the **rebuilt binary** by piping
synthetic `PreToolUse` JSON events through it, not only via `go test`;
that is what the reviewer measures against. Related:
[[project_make-the-reach-structural-when-enumeration-stalls]].
