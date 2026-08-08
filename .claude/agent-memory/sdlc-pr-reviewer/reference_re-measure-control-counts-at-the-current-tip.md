---
name: re-measure-control-counts-at-the-current-tip
description: A PR-body "N assertions fail under this mutation" figure is falsifiable in one run — and when it does not match tip, re-run it at each intermediate round tip: a figure that reproduces exactly at an earlier commit proves the "re-measured against the current tree" claim false rather than merely wrong.
metadata:
  type: reference
---

Two techniques for grading a negative control, both used on PR #232
round 9.

**1. Prove a control's LIVENESS anchor by mutating it, never by reading
it.** A negative control that swaps a table has two halves: the claim
("restoring the old entry must not restore the old verdict") and a
liveness anchor ("and here is a row that DOES still ride that table").
Reading the anchor tells you nothing — an inert swap helper and a live
one produce identical output whenever the anchor row stopped riding the
table. So make the helper inert and run only that test:

```python
# in a `git archive HEAD` copy of the package
old = "\toriginal := ghRecoverableWriteVerbs\n\t...\n\tt.Cleanup(...)"
new = "\t_ = noun\n\t_ = verbs\n\t// INERT MUTATION: the swap does nothing."
```

On #232 that produced a FAIL on exactly the anchor line
(`gh_publish_files_test.go:805`), which is what "the repair is genuinely
live" means. Do this for any control whose anchor a later round moved.

**2. When a claimed mutation count does not match tip, measure it at the
intermediate round tips too.** A PR body that says "Every mutation below
was re-measured against the current tree" is making a checkable claim
about freshness, not just about the numbers. When a figure misses at
tip, re-run that same mutation against an earlier round's commit via
`git archive`: if it reproduces there EXACTLY, the figure was not
stale-by-drift, it was the previous round's number carried forward under
a sentence saying it was not. That is a much sharper finding than "the
number is wrong", and it costs one extra `git archive` per figure. Only
the figures the later rounds' new tests touch will miss, so say which —
the sentence is false of those and true of the rest.

**Then re-run the ones the fix round did NOT touch.** A fix round
re-measures only the figures the finding named and leaves the others
under the same "re-measured against the current tree" sentence. The
sentence quantifies over all of them, and a fix round has no incentive
to check the ones nobody flagged, so the closing check is all of them at
the new tip, not just the ones that moved.

Mechanics that make this cheap:

```bash
git archive <rev> plugins/guardrails/hooks/permission-gate | tar -x -C "$H"
# patch one construct with python, then:
go -C "$P" test ./... 2>&1 | grep -E '^--- FAIL' | sort -u
go -C "$P" test ./... 2>&1 | grep -cE '^ +[a-z_]+_test\.go:[0-9]+:'
```

The `grep -c` over `^ +<file>_test.go:NN:` is one line per `t.Errorf`,
which is the unit PR bodies in this repo count in. Never mutate the
review worktree itself.

Related: [[negative-control-assertions-via-hybrid-tree]],
[[guardrails-binary-verification]],
[[derive-the-row-cross-from-compiled-tables]].
