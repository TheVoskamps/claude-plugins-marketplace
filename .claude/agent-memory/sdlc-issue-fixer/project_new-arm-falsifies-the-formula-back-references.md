---
name: new-arm-falsifies-the-formula-back-references
description: Adding a case/arm to a resolution rule (e.g. a `B` empty fallback) silently falsifies every later sentence that used the old formula as a label — grep the formula symbol, not the new arm's keywords — and CLAUDE.md's restatement list fires for any rule those files share, not only the parsing rule it names
metadata:
  type: project
---

Two things go wrong when a fix round adds a **new arm** to a rule that
several files restate.

**The formula becomes a label, and labels rot silently.** PR #224 round
2 added a `B` empty arm to `pr-reviewer.md` step 2 (branch name off
convention → no branch set to bound with → review against `C`). Two
sentences elsewhere in the same file carried the old formula as an
apposition — step 3's "every issue in `C ∩ B`, the set you review
against" and "Every member of the set you review against — `C ∩ B` from
step 2 —". Both read as harmless restatements and both became false the
moment the arm existed. They are *not* reachable by grepping the arm's
own vocabulary (`empty`, `convention`, `B`): the review that found the
missing arm reported `grep -n 'convention\|empty'` as matching nothing
relevant, which is exactly why the formula sites survived. Grep the
**formula symbol itself** (`C ∩ B`, `∩`, the variable names) and
replace each apposition with a pointer at the step that owns the
resolution ("as step 2 resolved it") rather than restating the amended
rule — one owner, no second site to keep in sync.

**A checked-in list of consumers fires for any shared rule, not just
the one it names.** When `CLAUDE.md` enumerates the files that restate
a rule, the trigger reads as "a PR that changes the rule" — and an arm
*around* the rule does not read as the rule, so a round that adds a
case to the two named consumers skips the third. Read such a list as
covering every rule those files hold in common — the parsing rule, the
maximum-not-equality rule, the empty-set arms — and walk all of it.
When the duplication is behavior rather than policy, the deeper fix is
to extract the mechanism into a skill and delete the list, per
`docs/plugin-authoring-constraints.md` → "Sharing behavior (a parse, a
lookup, a derivation)".

**Why:** the missed consumer is often a *third* one in a *different*
plugin, so neither the sibling-agent family sweep
([[sweep-sibling-agent-guards]]) nor a same-directory grep finds it;
only a checked-in list, or the extraction that removes the copies,
does. And the cost of the silent half is a whole extra round on prose
that no build or lint checks.

Sibling shapes: [[shared-predicate-list-is-one-claim]] (one blanket
claim over N files), [[count-tally-class-includes-back-references]]
(the tally and its downstream back-references are one claim).
