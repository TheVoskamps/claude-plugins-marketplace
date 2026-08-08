---
name: enumerate-completely-derive-from-the-structure
description: when a finding says a prose enumeration dropped a member, never just append that member — dump the authoritative data structure and mechanically diff EVERY surface carrying the list, with the checker run pre-edit as its own negative control
metadata:
  type: feedback
---

An enumeration that silently drops members is the defect, so closing
one named omission is not the fix. Edwin, on #229 / PR #232 round 5:
*"If you're going to bother to enumerate flags get them all and get it
right."*

**Why:** the review's Low named one missing flag (`-T`/`--template`) in
one file. Deriving the list from `ghFileSpecs` instead showed the same
sentence's *operand* half had also dropped `gh release edit`, and that
the identical enumeration lived in two further surfaces (the gate
README and the PR body), each dropping the same members. Appending the
one named flag would have shipped three sibling defects and bought a
round 6. Two earlier sweeps on that PR had already closed only the
sites they were handed.

**How to apply:**

1. **Derive, don't transcribe.** Write a throwaway in-package
   `zz_tmp_*_test.go` that dumps the real structure (there:
   `pathValueFlags`, `filePositionalsFrom`, `defaultsToStdin` per
   noun/verb) to a TSV under `.claude/tmp/<slug>/`, and delete it
   before committing — a committed source-lint test is forbidden, see
   [[no-source-lint-meta-tests]]. A test file is not compiled into
   `go build` output, so it triggers no binary rebuild.
2. **Grade every surface against that dump with a script**, not by eye:
   exact per-flag set equality where the prose is structured enough to
   parse (bullets shaped `` `flag` on `verbs` ``), member-presence
   where it is running prose. Cut each bullet at its first em dash so a
   deliberate *negative* clause ("and only there, because `gh issue
   create`'s `-T` …") does not read as a claimed member.
3. **Run the checker BEFORE editing.** It must fail on exactly the
   dropped members; that failure is what makes its later "ok" mean
   something.
4. **The surfaces are wider than the repo.** The PR body carried the
   same list — fix it with `gh pr edit <N> --body-file <scratch>` and
   `diff -u` before/after (see [[pr-body-is-a-swept-surface]]) — and so
   did another agent's memory file, which is fair game when the PR's
   own diff added it.
5. **Restructure rather than truncate.** If the complete set no longer
   reads as a parenthetical, make it a bullet list.
6. **Not every hedged list is in the class.** `Some X needed …:` with
   a cross-reference to where the remaining member is documented is
   scoped, not truncated — but say so in the report, and prefer naming
   the sibling inline ("`gist edit`'s `-a`/`--add` needed one as well,
   at its own entry below") over leaving the reader to notice.

Related: [[shared-predicate-list-is-one-claim]],
[[count-tally-class-includes-back-references]],
[[drive-every-path-a-summary-claims]].
