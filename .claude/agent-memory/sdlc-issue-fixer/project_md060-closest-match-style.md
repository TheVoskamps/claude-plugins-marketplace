---
name: md060-closest-match-style
description: MD060 at style `any` scores each table against aligned/compact/tight and reports the closest match, so a narrow table can be judged `aligned` while its siblings are judged `compact`; --fix repairs compact/tight only, never aligned
metadata:
  type: project
---

MD060 (`table-column-style`) with the default `style: any` does not
pick one style per document — it scores **each table** against
`aligned`, `compact`, and `tight` and reports violations for whichever
would produce the *fewest*. A table whose cells happen to be narrow can
come out closest to `aligned` while three structurally identical tables
in the same file come out closest to `compact`.

`markdownlint-cli2 --fix` repairs `compact` and `tight` violations
(they are independent, per-pipe edits) but **never** `aligned` ones —
the rule's own doc says fixing a single aligned violation may require
rewriting the whole table. So a `--fix` pass over a batch of MD060 hits
predictably leaves a residue that looks like a different, harder
problem and is usually the same trivial one.

**Why:** on PR #211, 44 MD060 hits across four files were all the same
defect — a `|---|---|---|` delimiter row under data rows padded
`| x | y |`. `--fix` cleared 41 and left 4, reported as *"Table pipe
does not align with header for style `aligned`"* on a two-line table.
Reading that as an alignment problem invites hand-padding the whole
table; writing the delimiter row as `| --- | --- | --- |` makes
`compact` the zero-violation match and the "aligned" complaints vanish.

**How to apply:** treat any leftover `aligned` complaint after a
`--fix` pass as "this table has no zero-violation style yet", and fix
it toward the style its *data rows* already use (almost always
`compact`: single space inside every pipe). Then re-lint — the reported
style changes as soon as the closest match does. Keep the delimiter
row's dash runs exactly as `--fix` wrote them for the other tables, so
the round's verification (`git diff --word-diff-regex='[^[:space:]]+'`
showing only whitespace moved) stays literally true. Companion:
[[lint-config-control-needs-its-own-directory]], for how MD060 came to
be silently disabled in this repo in the first place.
