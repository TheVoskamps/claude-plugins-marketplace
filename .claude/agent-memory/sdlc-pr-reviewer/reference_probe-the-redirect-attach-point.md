---
name: probe-the-redirect-attach-point
description: A redirect has two attach points in the mvdan/sh AST — the simple command and the enclosing compound statement (`{ cmd; } < f`, `( cmd ) < f`, loop/if forms, and a bare `> f` with no command at all) — so a permission-gate PR claiming a redirect class is graded has only been shown for the form its matrix used; run the matrix a second time wrapped in `{ …; }` and once with no command.
metadata:
  type: reference
---

`mvdan.cc/sh` parks redirects on the enclosing `*syntax.Stmt`, not on
the `CallExpr`. So `cmd < f` and `{ cmd; } < f` reach the gate's walker
by different routes: the first through the `CallExpr` arm, the second
only if every compound arm (`Block`, `Subshell`, `IfClause`,
`ForClause`, `WhileClause`, `CaseClause`) forwards the enclosing
statement's redirects down to the statements it descends into. A
statement with redirects and no command at all (`> f`, `[[ -f x ]] > f`,
a bare assignment) is a third route, reached by neither, and needs a
redirect-only fallback to be graded at all.

A gate's tests and the PR author's own probe matrix will cover the
simple form. The other two routes are where a redirect silently escapes
grading, and an escaped write redirect earns `allow`, which outranks
`settings.json` and so beats the user's own deny list.

**How to apply:** for any gate PR touching redirects, run the claimed
matrix three times — as written, with every command wrapped in
`{ …; }`, and with the command removed so only the redirect remains —
on both the input (`<`) and output (`>`) axis. Assert the operand
control alongside it (`{ cat <out-of-repo>; }` must deny), which proves
the *construct* is walked and isolates a lost redirect from an unwalked
node. Run the same matrix against the `origin/main` binary too: identical
verdicts mean pre-existing, which is the difference between High and
Critical. Also read the README's `Known gaps` section — a section that
exists to record exceptions to an equivalence rule is where a missing
gap is a finding rather than a nit.

See [[guardrails-binary-verification]] for the probe mechanics and
[[narrowing-a-gate-promotes-cosmetic-helpers]] — same shape, a
different unguarded input path into a newly-load-bearing helper.
