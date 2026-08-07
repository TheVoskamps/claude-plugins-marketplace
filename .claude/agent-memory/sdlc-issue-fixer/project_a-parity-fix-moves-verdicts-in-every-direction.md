---
name: a-parity-fix-moves-verdicts-in-every-direction
description: A fix that makes one spelling inherit another's verdict moves rows in EVERY direction, not just the one the finding named; enumerate them by replaying the same row list through the pre-fix committed binary and the rebuilt one side by side, and report the permissive moves loudest.
metadata:
  type: project
---

A finding names the direction that alarmed the reporter — "this
respelling reaches an ASK where the canonical spelling DENIES". The fix
makes the respelling inherit the canonical verdict, so it also moves
every OTHER row of the same class, including rows that get *more*
permissive. Those are the ones a reviewer will find if you do not.

**Why:** on #229 round 6 the brief predicted `aliases: ask → deny`.
Resolving gh's cobra aliases actually produced three directions at once:
5 rows ask → deny (containment), 6 rows ask → allow (`gh issue ls` is
`gh issue list`, a read), and 2 rows **deny → allow** — `gh secret ls`
and `gh variable ls` had been hitting the secret-noun's blanket
default-deny purely because `ls` is not spelled `list`. Each is correct
by construction, since the alias IS the canonical command, but
"deny → allow on the secret noun" is not a sentence to leave out of a
report. The sibling fix in the same round moved 9 rows allow → ask and
touched nothing else.

**How to apply:** build ONE row list covering the fix, its mirror
(spellings that must NOT move), and unrelated controls, then replay it
through both binaries in one table — `git show HEAD:<bin-path> >
.claude/tmp/<slug>/pre-fix-<bin>` for the control, the rebuilt one for
the tip, a python driver piping synthetic `PreToolUse` JSON to each, and
a `(moved)` marker computed from the pair. That single table is the
negative control, the regression evidence and the enumeration of every
direction, and it costs one run. Keep a `cat <same-path>` row in it:
if the probe cwd loses repo context every row reads `ask` and the table
is meaningless (see [[guardrails-binary-verification]] in the reviewer's
memory for the cwd traps).

Related: [[verify-a-predicted-verdict-before-implementing-it]],
[[probe-a-mutating-verb-without-mutating-it]],
[[old-code-claim-hits-a-different-guard]].
