---
name: probe-the-gate-binary-not-the-walk
description: Settle a permission-gate structural claim ("descends into every X", "always routed through Y") by running the classifier on the shape, via a throwaway _test.go in the package — reading the walk misses the call-site scoping that makes such claims false.
metadata:
  type: feedback
---

For a claim about the permission-gate's *reach* — "the walk descends
into every process substitution", "every operand funnels through this
choke point", "all three tracks" — write a throwaway
`zz_docprobe_test.go` in `hooks/permission-gate/`, `t.Logf` the
`classifyBash` verdict for each shape, run `go test -run … -v .`, and
delete the file before staging.

**Why:** the helper usually does do what its own doc comment says. The
falsehood is in the *call sites*: mid-#225 `descendProcSubsts` genuinely
descended into every process substitution of the word it was handed, but
its single caller was the `CallExpr` argv branch, so `cat < <(cat
../sibling-repo/.env)` ALLOWed while `comm -3 <(cat …) x` DENIEd. Reading
the function bottom-up confirms the claim; only running it refutes it.
(That gap was closed later in the same PR — a second caller now covers
redirect words — so the lesson is the method, not the verdict.)
The same probe settled which `gh -f/-F` field spellings the new
shielding actually admits, which I then wrote into a skill as a
prescription — never prescribe a gate-permitted spelling you have not
run.

**How to apply:** grep the helper's callers first
(`grep -n 'helperName(' *.go | grep -v _test`) — a single call site is
the tell that a "for every X" claim is scoped. Then probe. Test helpers
to copy: `gitInit(t, dir)`, `canonicalize`, `bashEvIn(t, root, "agent")`,
`classifyBash(cmd, ev)`. Note the verdict you get is the PR's source,
not the gate adjudicating your own calls — that one is the installed
plugin cache's binary
([[feedback_gh-pr-diff-and-active-gate]]).

Related: [[project_guardrails-permgate-docs-locality]],
[[feedback_no-blanket-predicate-over-a-list]].
