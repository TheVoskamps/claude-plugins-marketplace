---
name: a-parity-fix-moves-verdicts-in-every-direction
description: A fix that makes one spelling inherit another's verdict moves rows in EVERY direction, not just the one the finding named; enumerate them by replaying the same row list through the pre-fix committed binary and the rebuilt one side by side, report the permissive moves loudest, and quote the ROW SET with every count because the number is a property of the row set, not of the fix.
metadata:
  type: project
---

A finding names the direction that alarmed the reporter — "this
respelling reaches an ASK where the canonical spelling DENIES". The fix
makes the respelling inherit the canonical verdict, so it also moves
every OTHER row of the same class, including rows that get *more*
permissive. Those are the ones a reviewer will find if you do not.

**Why:** on issue #229 round 6 the brief predicted `aliases: ask → deny`.
Resolving gh's cobra aliases actually produced three directions at once.
Measured in round 9 over a row set derived from the gate's own tables —
every `gh <noun> <verb>` pair those tables name, 1,295 bare rows with no
operands and no flags — replayed through main's committed `darwin-arm64`
binary and the rebuilt one: **24 rows move**, 21 ask → allow (11 `ls`
reads, the 3 `new` recoverable writes, 7 `gh rs <read verb>` rows
through the noun alias), 2 **deny → allow** (`gh secret ls` and
`gh variable ls`, which had been hitting the secret-noun's blanket
default-deny purely because `ls` is not spelled `list`), and 1 ask →
deny (`gh rs delete`). Each is correct by construction, since the alias
IS the canonical command, but "deny → allow on the secret noun" is not a
sentence to leave out of a report. The sibling publish fix in the same
round moved rows the other way as well, and its permissive set had a
closed form rather than a count: main screened with
`containsToken(args, "--public")`, blind to position, so the ask → allow
rows were exactly the spellings where pflag does not read that token as
a flag — a separated value of each value-taking flag the verb has, in
both spellings (`--desc --public`, `-d --public`, `--filename --public`,
`-f --public`), plus an operand after `--`. Five rows. My first pass
said four, because I listed the spellings by hand and forgot `-f`; the
verb's own `valueFlags` map has four keys and would have said so.

**Round 10 then overturned that permissive set entirely, which is the
second lesson.** The owner ruled every `gh gist create` an ASK — a
secret gist is UNLISTED, not private — so the `--public` screen was
deleted and the verb left `ghRecoverableWriteVerbs`. All five permissive
rows ask again, `gh gist create` itself moves **allow → ask**, and
`gh gist new` stops moving at all (it had been ask → allow only because
`gist create` was a recoverable write). Re-measured over my own
1,089-row reconstruction of the same cross: still **24 rows**, now 20
ask → allow (the `new` group drops to 2), 2 deny → allow, 1 ask → deny,
1 allow → ask. Two consequences worth carrying: the moving SET is
invariant to how wide the cross is (a narrower reconstruction reproduced
24 exactly), and a decomposition sentence rots one tier at a time — the
old "so alias resolution is the only tier that can move a bare row"
parenthetical became false the moment a non-alias tier started
escalating a bare row, while the total stayed 24 and hid it.

**A count is a property of the ROW SET, not of the fix.** That is what
went wrong here, twice, and it is not fixable by counting harder. Round
6 reported 6 ask → allow from its own hand-built list; round 8's
reviewer measured 19 over a 694-row matrix; round 9 measured 21 over the
1,295-row table-derived cross. All three counted honestly and all three
disagree, because each quantified over a different set — the reviewer's
`rs` enumeration named 5 of the 7 rows that noun alias actually reaches
(no `checks`, no `diff`), and round 6's list never crossed the noun
aliases at all. A bare "6 rows moved" is therefore
unfalsifiable prose: nobody can reproduce it, and the next reviewer's
own number reads as a defect. State the row set in the same sentence as
the number, and build that set by CROSSING the code's own tables rather
than by listing the rows you happened to think of.

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
reviewer's memory for the cwd traps).

Related: [[verify-a-predicted-verdict-before-implementing-it]],
[[probe-a-mutating-verb-without-mutating-it]],
[[old-code-claim-hits-a-different-guard]],
[[drive-every-path-a-summary-claims]].
