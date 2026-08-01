---
name: probe-the-redirect-attach-point
description: A permission-gate PR that claims a redirect class is "contained like operands" has only been verified for SIMPLE commands — probe the compound-command attach point (`{ cmd; } < f`, `( cmd ) < f`, loop/if forms), which mvdan/sh parks on the enclosing Stmt and the walker drops.
metadata:
  type: reference
---

When a `guardrails` PR says redirects are now graded/contained, the
tests and the author's own probe matrix will cover `cmd < f`. That is
one of two places a redirect can attach in the AST, and the other one
is unguarded.

`mvdan.cc/sh` parks redirects on the enclosing `*syntax.Stmt`, not on
the `CallExpr`. `extractSimpleCommands`' `walkCmd(cmd, redirs)` passes
`redirs` to `reduceCallExpr` **only** in its `case *syntax.CallExpr:`
arm; `Block`, `Subshell`, `IfClause`, `ForClause`, `WhileClause` and
`CaseClause` all recurse via `walkStmt`, which supplies each *inner*
statement's own `stmt.Redirs` and silently discards the outer ones. So
the redirect on a compound command is never recorded on any
`simpleCommand`, on either the input or the output axis.

**Worked instance (#193, PR #208 round 5):** `cat < /etc/passwd`
correctly denied, while `{ cat; } < /etc/passwd`, `( cat ) < …`,
`if true; then cat; fi < …` and `for i in 1; do cat; done < …` all
returned **`allow`** — including `< ~/.ssh/id_rsa` and
`< ~/.aws/credentials`. Same root cause on the write side:
`echo x > <out-of-repo>` deferred but `{ echo x; } > <out-of-repo>`
allowed. `allow` outranks `settings.json`, so it beats the user's own
deny list. Verdicts were identical on the `origin/main` binary, so it
was pre-existing, not a regression — which is the difference between
High and Critical.

**How to apply:** for any gate PR touching redirects, run the claimed
matrix twice — once as written, once with every command wrapped in
`{ …; }` — and separately assert the operand control
(`{ cat /etc/passwd; }` denies, proving the *construct* is walked and
only the redirect is lost). Also check the `Known gaps` / README gaps
section: a section that exists to record exceptions to an equivalence
rule is where a missing third gap is a finding rather than a nit.

See [[guardrails-binary-verification]] for the probe mechanics and
[[narrowing-a-gate-promotes-cosmetic-helpers]] — same shape, a
different unguarded input path into a newly-load-bearing helper.
