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
(That gap, and the item-list/`case`/assignment ones found after it, were
closed later in the same PR — the descent now takes a NODE and finds
substitutions with `syntax.Walk`, applied per statement — so the lesson
is the method, not the verdict.)
The same probe settled which `gh -f/-F` field spellings the new
shielding actually admits, which I then wrote into a skill as a
prescription — never prescribe a gate-permitted spelling you have not
run.

To say whether a verdict you measured is a WIDENING or pre-existing,
probe the merge base the same way: from the worktree root,
`git archive <base> plugins/guardrails/hooks/permission-gate | tar -x -C
zzbase`, copy the probe file in, `go test` there, `rm -rf zzbase`. Guess
and you will call a pre-existing allow a regression (or miss one) — in
issue #225 the `for`-header substitution ALLOWed at base too, while only the
`"$f"`-using body actually flipped.

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
