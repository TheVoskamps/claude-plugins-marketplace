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
