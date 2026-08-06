---
name: bash32-cannot-parse-case-in-cmdsub
description: bash 3.2 ends a $( ) at a case pattern's `)`, so a `case` inside command substitution FAILs with a fragment of its own source — separate that harness artifact from shipped behavior by running the real code under both shells, and baseline the suite at origin/main
metadata:
  type: reference
---

`/bin/bash` 3.2.57 (stock macOS) terminates a `$( … )` at the closing paren of
a **case pattern**, so an assertion written as
`"$(case "$x" in "$p"/*) echo inside ;; *) echo outside ;; esac)"` evaluates to
the literal tail of its own source:

```text
expected: [outside]
actual:   [ echo inside ;; *) echo outside ;; esac)]
```

bash 5.3 parses it fine. The identical classification written **outside** a
command substitution (a function, or `[ "${x#$p/}" != "$x" ]`) returns the
right answer on both. So the failure indicts the harness, never the code under
test — but the FAIL *label* is the test's own sentence, which on PR #231 read
"the shared wrap dir is OUTSIDE the rw repo share", i.e. exactly as if the
PR's security fix were broken.

**How to tell them apart, and what to grade:**

1. **Baseline the suite at `origin/main`** — `git archive origin/main
   <payload-path> | tar -x -C .claude/tmp/…` and run it there under *both*
   interpreters. On #231 that gave `294 passed, 0 failed` (bash 5) and
   `278 passed, 15 failed` (3.2), which proved the 15 `render:` failures
   pre-exist and are out of scope, and that the 2 remaining ones are the PR's
   own.
2. **Run the shipped code, not the assertion.** Slice the real loop out by
   line range (see [[slice-the-real-launcher-loop-to-probe-emissions]]) and run
   the slice under `/bin/bash` and `bash` explicitly. Note the suite's own
   `bash "$SLICE"` resolves through PATH, so a suite running under 3.2 still
   runs its slices under 5 — only an explicit interpreter probes the floor.
3. **Grade it Low**, not High: nothing shipped differs, and a suite that
   already fails N assertions on 3.2 is not made unrunnable by two more. The
   harm is the false FAIL text, so the recommendation is to move the
   classification out of the substitution.

**The rule covers the suite too — corrected in #231 round 7.** This entry used
to close by saying `plugins/claude-vm`'s CLAUDE.md rule "write the config-load
guards for bash 3.2" was about the *guards*, so a 3.2 failure in a test file
was not a violation of it. That is false as of #231: root `CLAUDE.md` and
`payload/README.md` now both say `test/config-test.sh` carries the same
shebang and is under the same rule, and both carry the severity clause — a
3.2-only construct in an assertion costs a reader's trust with a false FAIL,
where the same construct in a guard ships a hole. So such a failure IS a
violation, of the cheaper kind, and "say which side of that line the failure
sits on" is now the rule's own wording rather than a caveat against invoking
it. Grading it Low (point 3) still holds — that is what "the cheaper kind"
means.

**The mechanism is narrower than "counting parens".** Measured on 3.2.57 vs
5.3.15: a `)` inside a quoted string (`$(echo "a)b")`, single or double) and a
nested `( … )` subshell both parse correctly on 3.2 — only an **unbalanced**
`)`, which in practice means a `case` pattern's, ends the substitution early.
So the remedy applies to `case`, not to every parenthesis; the shipped docs'
"counting parens" phrasing over-includes rather than under-includes, which
costs churn and never a hole.

To sweep the class, don't grep — the two ends sit on different lines. A
quote-aware paren walker over every `git ls-files` shell file (shebang or
`.sh`/`.bash`) that flags a `$( )` body containing `case` runs in seconds;
negative-control it against the pre-fix commit's own file (`git show
<pre-fix>:<path>`), which must report the known instances.

Related: [[verify-bash-regex-in-real-bash]] (the Bash tool's own shell lies
too), [[baseline-suite-totals-via-git-archive]],
[[baseline-lint-before-flagging]] (same "measure the baseline first" shape).
