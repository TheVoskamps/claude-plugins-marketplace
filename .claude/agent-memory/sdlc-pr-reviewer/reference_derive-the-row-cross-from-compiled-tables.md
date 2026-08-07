---
name: derive-the-row-cross-from-compiled-tables
description: To re-derive a PR's "N rows move" figure, generate the noun x verb cross from the gate's OWN compiled maps with a throwaway dump test in a git-archive copy, then replay every row through both binaries with a thread pool — 1,258 rows x 2 binaries runs in a couple of minutes and reproduces the composition exactly.
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
your own transcription. On #232 round 9 that gave **37 nouns x 34 verbs
= 1,258**, reproducing the PR body's derivation exactly.

**Replay with a thread pool, not a loop.** A `ThreadPoolExecutor(8)`
over `subprocess.run([binary], input=json.dumps(event))` does 1,258 rows
x 2 binaries in a couple of minutes; the gate forks `git rev-parse` per
row, so serial is painful. Extract the OLD binary by redirecting
`git show origin/main:plugins/guardrails/hooks/bin/darwin-arm64/permission-gate`
to a file and `chmod +x` it. Report the composition as a `Counter` of
`"<old> -> <new>"`, which is what the PR body states and what a
disagreement shows up in.

**The moving SET is invariant to the cross's width; the count is not a
property of the fix.** A deliberately wider cross (I ran 39 x 40 = 1,560,
adding the `auth`/`api` nouns and the auth verbs) returned the SAME 25
rows. So a PR that states a width and a composition is reproducible, and
one that states only a bare count is not — which is why a wider-cross
figure whose added verbs are not enumerated is weaker evidence than the
narrow one whose derivation is exact.

**Three more replays worth doing in the same rig, all cheap once it
exists:**

- **round-N tip -> tip**, to bound what the rounds since the last review
  changed. On #232 that moved exactly 3 rows, all `allow -> ask` on the
  two gist verbs and the alias of one — proof that nothing outside the
  owner-directed change moved.
- **the same cross with operand suffixes**, for regression direction. I
  crossed the 6 file-spec nouns x 34 verbs x 18 suffixes (escaping
  positional, `-F`/`--body-file`/`-a`/`--add` escaping, `--`, `-` with a
  redirect, bare redirect, contained counterparts, unmodelled flag,
  `-h`) = 3,672 rows. **Zero** `deny -> ask` or `deny -> allow` is the
  finding that "containment still outranks the new arm" — much stronger
  than a hand-picked probe list.
- **alias parity**: for every row whose noun/verb is an alias, assert
  `tip(alias) == tip(canonical)`. 198 pairs, 0 violations, settles
  "the resolution grants exactly the canonical verdict and nothing
  wider".

Related: [[guardrails-binary-verification]],
[[bound-a-respelling-fix-by-equivalence]],
[[re-measure-control-counts-at-the-current-tip]],
[[gate-blocks-for-loops-and-zsh-eats-eq-echo]].
