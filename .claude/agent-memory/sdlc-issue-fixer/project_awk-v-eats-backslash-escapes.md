---
name: awk-v-eats-backslash-escapes
description: awk's -v assignment runs backslash-escape processing on the value, so a two-character \t passed through becomes a REAL tab — which silently corrupts a literal line you are reconstructing; double the backslash for the awk copy and keep a separate un-doubled copy for the assertion
metadata:
  type: project
---

**The trap.** `awk -v v='...\t...'` does **not** hand the value through
verbatim. POSIX awk applies escape-sequence processing to a `-v`
assignment, so the two characters `\` `t` arrive inside the program as a
single **real tab**. Nothing warns; the program runs.

This bites when awk is being used to *reconstruct a literal line of
shell source*. Building a negative control on PR #228 meant re-emitting
the pre-fix line `while IFS=$'\t' read -r a b c; do`. Passed through
`-v oldread=`, it came out with a real tab between the quotes. The
generated control still *behaved* correctly — bash's `$'<literal tab>'`
is a tab, same as `$'\t'` — so the behavioral assertion passed and only
the `assert_contains` on the literal text failed. Had the test only
asserted behavior, a control that no longer matched the code it claims
to reproduce would have shipped unnoticed.

**The fix.** Keep two copies and say why in a comment next to them:

```bash
FOO="while IFS=\$'\\t' read -r a b c; do"       # for grep/assert
FOO_AWK="while IFS=\$'\\\\t' read -r a b c; do" # for awk -v
```

In double quotes `\\t` yields `\t` and `\\\\t` yields `\\t`; awk's `-v`
collapses the latter back to `\t`. Assert with the un-doubled copy.

**Related awk-portability note from the same run:** don't reach for
`\x27` to get a single quote into an awk string — it is a GNU
extension, not POSIX. Pass it as `-v q="'"` and concatenate:
`$0 == q " | while IFS= read -r rec; do"`.

**Why this technique at all.** The negative control for a parsing fix
should be *derived from the real code*, not hand-typed: slice the loop
out of the shipped/generated script, then transform those same lines
back to the pre-fix shape (swap the read line, drop the added
expansions) with awk. A hand-typed control drifts the moment the real
loop changes and then silently proves nothing. Assert that the
transform actually landed — the old read present, the new expansions
absent — before trusting the behavioral flip. See
[[negative-control-the-approved-snippet]] for why the control has to
run the real thing, and [[real-build-verification-not-unit-tests]] for
slicing a generated artifact rather than a reimplementation.
