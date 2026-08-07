---
name: verify-bash-regex-in-real-bash
description: Bash tool's shell reports empty $BASH_VERSION and mis-evaluates [[ =~ ]] / [^]] char classes; invoke `bash` explicitly when exercising bash-specific code
metadata:
  type: reference
---

When exercising bash-specific constructs (`[[ =~ ]]` regexes, `[^]]`
character classes, `BASH_REMATCH`) via the Bash tool, the default
shell reports an empty `$BASH_VERSION` and does NOT evaluate these the
way GNU bash does.

**Why:** during PR #161 review I hand-reproduced a `render_apt_source`
regex in a bare Bash-tool call and got a wrong result (regex failed to
match, appeared to show a double-`[options]`-block bug). Re-running the
exact same logic under an explicit `bash script.sh` (GNU bash 5.3 via
`/opt/homebrew/bin/bash`) showed the regex matched correctly and there
was no bug. The provisioner code runs inside a Debian build container
(GNU bash), so real-bash is the correct evaluation environment.

**How to apply:** when a finding hinges on `[[ =~ ]]` / bracket
char-class / `BASH_REMATCH` behavior, do NOT trust a bare Bash-tool
one-liner. Write a small script and run it with `bash script.sh` (or
confirm `bash --version`) before asserting a regex-matching bug exists.
The project's own test suites already do this (they `source` the
extracted function and run under `bash`), so running the committed
tests is the reliable path. See [[guardrails-binary-verification]] for
the analogous "exercise the real artifact" principle.

**Both interpreters are on this machine, and a version-dependent-construct
claim needs three runs, not one.** `/bin/bash` is 3.2.57,
`/opt/homebrew/bin/bash` is 5.3.15. To settle a "this construct behaves
differently on old bash" claim (PR #231: bash >= 4.3 unescapes `\/` in the
REPLACEMENT half of `${var//pat/rep}` and 3.2 does not; 3.2 errors
`a[@]: unbound variable` on a bare `"${a[@]}"` over an EMPTY array under
`set -u` where 5.3 does not, and `${a[@]+"${a[@]}"}` works on both while still
preserving spaces inside elements), run:

1. the **committed** function under both — outputs must be identical;
2. the **avoided spelling** under both — the control that proves the hazard is
   real rather than folklore;
3. the **pre-fix file** (`git show <old-commit>:<path>`) under the old bash,
   driving the real validator — this is what turns "theoretical" into a
   demonstrated live bypass, and it is the sentence the review needs. On #231
   the pre-fix code ACCEPTED `path: //etc` under 3.2 and REJECTED it under 5.3.

Read the consequence precisely though: the mangled string usually breaks the
*downstream* action too, so a fail-open guard is not automatically a
successful attack — say which it was.
