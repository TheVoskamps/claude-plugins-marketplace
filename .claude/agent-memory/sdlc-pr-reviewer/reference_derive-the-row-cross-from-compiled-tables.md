---
name: derive-the-row-cross-from-compiled-tables
description: To re-derive a PR's "N rows move" figure, generate the noun x verb cross from the gate's OWN compiled maps with a throwaway dump test in a git-archive copy, then replay every row through both binaries with a thread pool — order 1,000 rows x 2 binaries runs in a couple of minutes and reproduces the composition rather than the bare total.
metadata:
  type: reference
---

A guardrails PR that changes `classifyGh` reports "M rows move" over a
row set. Never adopt the figure and never hand-list the set: derive it
from the compiled maps.

**Dump the cross from the package itself.** `git archive HEAD` the
package into `.claude/tmp/`, drop in a `zz_dump_test.go` that unions the
nouns and verbs out of every table the classifier dispatches on
(`ghRecoverableWriteVerbs`, `ghFileSpecs`, `ghNounAliases`,
`ghVerbAliases`, the irreparable-deny verbs) and writes
`gh <noun> <verb>` lines to `$CROSS_OUT`. Two things make it honest:
`isGhReadOnly`'s `readVerbs`/`knownNouns` are FUNCTION-LOCAL literals, so
they have to be restated — assert every restated member back through
`isGhReadOnly()` in the same test, plus a non-member, or you are grading
your own transcription. Report the cross as `<nouns> x <verbs>` with the
union that produced each side, so a reader can re-run it; a bare product
is not reproducible and will not survive the next table edit.

**Replay with a thread pool, not a loop.** A `ThreadPoolExecutor(8)`
over `subprocess.run([binary], input=json.dumps(event))` does an
order-1,000-row cross x 2 binaries in a couple of minutes; the gate
forks `git rev-parse` per
row, so serial is painful. Extract the OLD binary by redirecting
`git show origin/main:plugins/guardrails/hooks/bin/darwin-arm64/permission-gate`
to a file and `chmod +x` it. Report the composition as a `Counter` of
`"<old> -> <new>"`, which is what the PR body states and what a
disagreement shows up in.

**The moving SET is invariant to the cross's width; the count is not a
property of the fix.** Re-running a deliberately wider cross (add the
`auth`/`api` nouns and the auth verbs) returns the same moving set. So a
PR that states a width AND its composition is reproducible, and one that
states only a bare count is not — and a wider-cross figure whose added
verbs are not enumerated is weaker evidence than a narrow one whose
derivation is exact. Grade the derivation, not the total: this PR class
has produced several mutually inconsistent totals, each honest over its
own row set, and chasing which is right is wasted effort.

**Three more replays worth doing in the same rig, all cheap once it
exists:**

- **last-reviewed tip -> current tip**, to bound what the rounds since
  the last review changed. The rows that move should be exactly the
  owner-directed change and its aliases; anything else is the finding.
- **the same cross with operand suffixes**, for regression direction.
  Cross the file-spec nouns x verbs x a suffix set (escaping positional,
  each path flag escaping, `--`, `-` with a redirect, bare redirect,
  contained counterparts, unmodelled flag, `-h`). **Zero** `deny -> ask`
  or `deny -> allow` is the finding that "containment still outranks the
  new arm" — much stronger than a hand-picked probe list.
- **alias parity**: for every row whose noun/verb is an alias, assert
  `tip(alias) == tip(canonical)`. Zero violations settles "the
  resolution grants exactly the canonical verdict and nothing wider".

Related: [[guardrails-binary-verification]],
[[bound-a-respelling-fix-by-equivalence]],
[[re-measure-control-counts-at-the-current-tip]],
[[gate-blocks-for-loops-and-zsh-eats-eq-echo]].
