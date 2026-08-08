---
name: one-mechanism-many-routes-grade-each-member
description: A "the merge eats this key" style defect usually has more than one route, and the routes reach different members of the key set — measure every (member × spelling) cell through the real pipeline instead of generalising from the member the finding named
metadata:
  type: project
---

When a finding says "mechanism M destroys the thing this gate tests",
resist reasoning from M to the whole key set. **M is usually one of
several routes, and each route reaches a different subset.** Build the
(member × input-spelling) matrix and *run* it.

**Measured on claude-vm PR #243 (issue #135).**
`claude_vm_check_plugin_key_placement` asked
`(.claude.plugins.<key> != null)` of the merged documents. The finding
named the `CLAUDE_VM_LIST_KEYS` prune (pass 1). Running all 5 sub-keys
× 4 empty spellings through the real `claude_vm_merge_config` found
**three** routes, and only the first was the one named:

- pass 1 (empty list key) — hits `bake` / `install_at_boot` in the
  valueless, `[]` and `""` spellings;
- pass 2 (`del(.. | select(tag == "!!map" and length == 0))`) — hits
  **every** sub-key written `{}`, list key or not;
- no prune at all — a valueless key is a genuine null, and
  `!= null` reads null as absent.

14 of 20 cells launched pre-fix. Had I graded from `bake` alone I would
have called the three non-list keys "already fine".

**The layer position is part of the input.** The same valueless key
answered `!= null` → **false** as the repo layer and **true** as the
global layer with no repo file, because step 1's
`select(fileIndex==0) * select(fileIndex==1)` deep-merges the null
against the `{}` stand-in document and coerces it to `''`. My first
matrix ran the fixture as the *global* layer only and mis-graded three
keys as caught. Vary the layer, not just the value — a merged-document
gate can give one config two verdicts.

**How to apply.** Write the matrix as a loop in a throwaway script that
sources the real library and calls the real merge; print
member/spelling/verdict per row. Then extract the **pre-fix** function
verbatim (`git show <sha>:<file>`) and print pre/post side by side —
that table is the negative control and it goes in the PR body. Better
still, extract the pre-fix *launcher load block* with `git archive
<sha>` into a scratch tree and drive it: "the shipped launcher prints
LAUNCH-PROCEEDS" beats "the helper returns 0". Related:
[[verify-a-predicted-verdict-before-implementing-it]],
[[missing-key-and-explicit-empty-differ]],
[[the-class-is-the-set-of-uses-not-values]].
