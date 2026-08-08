---
name: two-mutations-one-number-means-one-site
description: When a mutation driver reports identical failing-assertion counts for two mutations that should differ, suspect the marker matched the same site twice — an indented needle is a substring of a more-indented sibling, so `str.index()` silently patches the wrong block.
metadata:
  type: reference
---

A PR body that decomposes one mutation into two ("removing the `=` stop
fails 3 assertions in the positional walk and 11 in the unmodelled-flag
screen") is checked by patching each site separately. On #232 round 10
both sub-mutations came back **3 / same 3 tests**, which reads like the
decomposition is bogus. It was the driver, not the claim.

**Why:** the two `=`-stop blocks in `classify_gh_files.go` are the same
statement at different nesting depths —
`\t\t\t\tif a[j] == '=' && j > 1 {` in `ghFilePositionalRefs`,
`\t\t\tif a[j] == '=' && j > 1 {` in `ghUnmodelledFlagAsk`. The 3-tab
needle is a **substring** of the 4-tab line (offset 1), so
`src.index(needle)` found the positional-walk block for *both*
mutations. Patching the same site twice produces identical numbers, and
the identity is the only tell.

**How to apply:**

- Treat "two mutations, one number" as a driver bug until disproved,
  not as evidence about the code. Re-run one of them with `rindex`, or
  anchor the needle on the block's own following comment line
  (`// pflag's \`-p=false\`` vs `// pflag ends the token`), which is
  unique where the indentation is not.
- With the collision fixed the decomposition reproduced exactly: 3
  (positional walk) + 11 (unmodelled screen), and removing BOTH stops
  in one run gives 14 — the sum, so the two sets do not overlap.
  Running the both-at-once variant as well is a free cross-check that
  costs one more `go test` and catches the collision on its own.
- The same trap waits for any Go mutation whose target statement
  appears at two nesting depths — a repeated `break` guard, a repeated
  `continue`, a per-arm `=` handler.

**A "wider cross" figure is falsifiable without replaying the cross.**
`39 × 39 = 1,521` is a product of two set sizes, so the whole check is
`len(nouns) × len(verbs)` in a throwaway dump test over a
`git archive` copy — no binary replay, no row list. On #232 the stated
derivation ("the `auth`/`api` nouns and the verbs the non-table arms
name") gave 39 × 37 = 1,443 at most, because `status` and `edit` are
already in the narrow 34-verb set and only `switch`/`login`(/`token`)
are new. The construction that DOES reach 39 was written down in the
doc-updater's own memory ("plus `auth`/`api` and the five auth verbs")
and never made it into the README sentence — so grep the agent-memory
tree for the figure before concluding the number itself is wrong.

Related: [[re-measure-control-counts-at-the-current-tip]],
[[derive-the-row-cross-from-compiled-tables]],
[[guardrails-binary-verification]].
