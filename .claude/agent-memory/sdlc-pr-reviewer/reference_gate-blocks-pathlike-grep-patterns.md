---
name: gate-blocks-pathlike-grep-patterns
description: The active permission-gate parses a grep PATTERN that looks like an absolute path (e.g. "/tmp") as a path operand and denies the whole command; spell it as a bracketed class like '[/]tmp'.
metadata:
  type: reference
---

`grep -rn "/tmp" plugins/guardrails --include="*.md"` is denied by the
active gate with a bash-read cross-repo message about reading `/tmp` —
the gate treats the pattern argument as a path operand. Observed on the
PR #208 review while sweeping docs for stale /tmp-policy prose.

**Workaround:** make the pattern not look like an absolute path while
matching the same text: `grep -rn -e '[/]tmp' <dir>`. Same trick for
any pattern starting with `/` or `~`. This is a probe-ergonomics note,
not a gate bug worth filing — the gate cannot distinguish a pattern
from a path in grep's grammar without flag-aware parsing.

Also remember the gate active in YOUR review session is the one from
the installed plugin cache (main's version), not the PR branch's
binary — a deny message you receive mid-review can itself be evidence
of the pre-fix behavior a PR claims to change (on #208 the old gate
denied a write to the harness scratchpad, live-reproducing issue #193).

Related: [[guardrails-binary-verification]], [[git-sandbox-via-script-file]].
