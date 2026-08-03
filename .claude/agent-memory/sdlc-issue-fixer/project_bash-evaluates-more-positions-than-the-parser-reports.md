---
name: bash-evaluates-more-positions-than-the-parser-reports
description: For "which word positions must I grade", measure BOTH halves per operator — `$(…)` and `<(…)` disagree with each other and with mvdan/sh; the quoted-vs-unquoted heredoc and parameter-expansion rows are where the two classes diverge
metadata:
  type: project
---

"Where does a substitution get evaluated" has a **different answer per
operator**, and the parser agrees with bash in some rows and not others.
Measure both halves for the operator you are actually wiring — a result
carried over from the sibling class is wrong about half the time.

Measured identically on bash 3.2.57 and 5.3.15, against mvdan.cc/sh
v3.13.1 (guardrails #225 / PR #227):

| position | bash runs `$(…)` | node? | bash runs `<(…)` | node? |
| --- | --- | --- | --- | --- |
| single-quoted `'…'` | no | no | — | — |
| here-doc `<<EOF` body | **yes** | **yes** | no | no |
| here-doc `<<'EOF'` body | no | no | no | no |
| `${Q:-…}` unquoted | **yes** | **yes** | **yes** | **no** |
| `${Q:-…}` quoted | **yes** | **yes** | **no** | no |
| everything else (argv, `for`/`select` items, `case` word and pattern, array element, `VAR=… cmd` prefix, decl RHS, `[[ … ]]`, redirect target, `cd` target, backtick) | yes | yes | yes | yes |

Consequences that decided the fix:

- `$(…)` needs **no** quoted/unquoted special-casing anywhere: every row
  where bash declines to expand is also a row the parser reports no node
  for, so a plain `syntax.Walk` grades exactly what bash runs.
- `<(…)` inside a parameter expansion is the one genuinely **unclosable**
  hole: bash runs it, and there is no node to hang a descent off.
- The backtick `` `cmd` `` is the same `*syntax.CmdSubst` node, so it is
  covered for free — but say so in a test row, because nothing else
  reveals it.

**How to measure (both halves, ~5 minutes):** a `probe.sh` that `eval`s
one snippet per position whose inner command `touch`es a marker, then
tests for the marker (add a `sleep` for `<(…)`, which is asynchronous);
and a throwaway in-package `zz_probe_test.go` that parses the same rows
and counts nodes by type with `syntax.Walk`. Pin the parser half in the
shipped test as a zero-count assertion on the non-expanding spellings, so
an upstream change that starts reporting a node fails loudly instead of
silently widening what gets graded.

Related: [[project_probe-the-parser-ast-not-the-grammar]] (the technique),
[[project_make-the-reach-structural-when-enumeration-stalls]] (why the
reach must be a traversal).
