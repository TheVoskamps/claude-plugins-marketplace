---
name: delete-the-named-mechanism-to-grade-the-prose
description: to grade a prose sentence that names WHY an example is denied, strip the named mechanism out of the example and re-run; if the verdict flips, the prose named a path the example never takes even though the behavior claim is true
metadata:
  type: project
---

A sentence of the form "X happens **because** the code treats this as
Y" is two claims. Running the example confirms only the first. To grade
the second, **delete Y from the example and re-run**: if the verdict
survives, Y was never load-bearing; if it flips, Y is real.

Worked case (PR #232). The PR body said "A `-` **operand** is gh's
read-from-stdin marker and is replaced by the command's input-redirect
sources, so `gh pr comment 227 -F - < /etc/passwd` earns the same deny
as naming the path." The deny is real. But `gh pr comment`'s spec
carries `filePositionalsFrom = -1`, so its positional walk returns
nothing at all — the `-` reaches the substitution through
`pathFlagValueRefs`, the FLAG half, and only because
`ghPublishedFileRefs` tests `r.path == "-"` on the merged ref set,
origin-agnostic. The discriminator, against the committed binary from a
real scratch-repo cwd:

```text
gh pr comment 227 -F - < /etc/passwd   -> deny   (flag value)
gh pr comment 227 -    < /etc/passwd   -> allow  (operand: not graded)
gh gist create    -    < /etc/passwd   -> deny   (filePositionalsFrom 0)
```

Row 2 is the whole test: drop the `-F` and the deny evaporates, so the
example's `-` was never an operand. Row 3 is the positive control that
keeps row 2 from being read as "the marker is unmodelled".

**Why:** this is the exact failure the agent definition warns about —
behavior correct and test-pinned, stated reason false, no test failing
on it. A reviewer catching it costs a full round trip.

**How to apply:**

- Any prose naming WHICH construct a verdict comes from is falsifiable
  in one extra probe. Budget the probe.
- Always pair the stripped case with a verb/row where the named
  mechanism genuinely IS the path, or an `allow` reads as a gap rather
  than as an answer.
- Before proposing wording, grep the repo for the same sentence. Here
  `plugins/guardrails/hooks/permission-gate/README.md` and
  `plugins/guardrails/rules/scratch-file-location.md` already carried
  the both-origins phrasing, so the proposed PR-body fix was a **sync**
  to already-reviewed prose, not a new claim — much stronger ground to
  report from. See [[shared-predicate-list-is-one-claim]] and
  [[pr-body-is-a-swept-surface]].
