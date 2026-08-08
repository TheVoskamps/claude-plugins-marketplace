---
name: a-parity-fix-moves-verdicts-in-every-direction
description: A fix that makes one spelling inherit another's verdict moves rows in EVERY direction, not just the one the finding named; enumerate them by replaying one table-derived row list through the pre-fix committed binary and the rebuilt one side by side, report the permissive moves loudest, and never state a count without the row set it was taken over.
metadata:
  type: project
---

A finding names the direction that alarmed the reporter — "this
respelling reaches an ASK where the canonical spelling DENIES". The fix
makes the respelling inherit the canonical verdict, so it also moves
every OTHER row of the same class, including rows that get *more*
permissive. Those are the ones a reviewer will find if you do not.

Resolving a CLI's own aliases moves rows in three directions at once:
`ask → allow` wherever the alias reaches a read or recoverable-write
verb it previously missed, `deny → allow` wherever a noun's blanket
default-deny was catching a canonical verb under an unspelled alias,
and `ask → deny` wherever the alias reaches an irreparable verb. Each
is correct by construction, since the alias IS the canonical command —
but "deny → allow on the secret noun" is not a sentence to leave out
of a report. Say the permissive ones first.

**A permissive set is worth stating in closed form rather than as a
count.** A screen that tests for a flag by scanning tokens for its
name, blind to position, over-asks exactly where the real parser does
NOT read that token as a flag: after a separated value of any
value-taking flag the verb has, in both spellings, plus an operand
after `--`. That description is checkable against the verb's own
`valueFlags` map; a hand-listed enumeration of the same rows is not,
and drops a member.

**A count is a property of the ROW SET, not of the fix.** This is the
failure that recurs, and it is not fixable by counting harder. Rounds
that each hand-built their own row list, each measured honestly, and
each reported a different number were all quantifying over different
sets — one never crossed the noun aliases at all, another named only
part of the rows a noun alias reaches. A bare "N rows moved" is
unfalsifiable prose: nobody can reproduce it, and the next reviewer's
own number reads as a defect. So:

- State the row set in the same sentence as the number, and build that
  set by CROSSING the code's own tables rather than by listing the rows
  you happened to think of.
- Publish the DERIVATION that generates the row set, not just its
  width, and re-measure at a deliberately wider cross as well. The
  moving SET is invariant to how wide the cross is, so two measurements
  at different widths beat one number with no derivation.
- Do NOT swap a total to your own reconstruction in a round that is not
  re-measuring. Do swap it, with its derivation, in one that is.
- A decomposition sentence rots one tier at a time while the total
  hides it: a parenthetical like "so alias resolution is the only tier
  that can move a bare row" goes false the moment a non-alias tier
  starts escalating a bare row. Re-derive the "can possibly move"
  argument every round, against that round's change.

Expect the owner to overturn a permissive set outright — a tier premise
is often a vendor fact rather than a code fact
([[a-tier-premise-can-be-a-vendor-fact]]) — and when they do, the whole
permissive group folds back to ask and the verb leaves its allow table.

**How to apply:** build ONE row list covering the fix, its mirror
(spellings that must NOT move), and unrelated controls, then replay it
through both binaries in one table — `git show origin/main:<bin-path> >
.claude/tmp/<slug>/gate-main` for the control, the rebuilt one for the
tip, a python driver piping synthetic `PreToolUse` JSON to each, and a
`(moved)` marker computed from the pair. Derive the list from the tables
themselves: copy the package into `.claude/tmp/<slug>/pkg/`, drop a
throwaway `zz_dump_rows_test.go` in the copy that walks the real Go maps
and writes the cross to a file, and drive that file. That single table
is the negative control, the regression evidence and the enumeration of
every direction, and it costs one run. Keep a `cat <same-path>` row in
it: if the probe cwd loses repo context every row reads `ask` and the
table is meaningless (see [[guardrails-binary-verification]] in the
reviewer's memory for the cwd traps). Never settle any of this by
running the publishing verb itself — the root `CLAUDE.md` forbids it,
and the binary replay answers the question anyway.

Related: [[verify-a-predicted-verdict-before-implementing-it]],
[[old-code-claim-hits-a-different-guard]],
[[drive-every-path-a-summary-claims]].
