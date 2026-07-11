---
name: issue-113-graphql-scanner-hardening
description: gh-api graphql scanner classes of bug found in PR review — scan-all-tokens vs first-match, and paren-depth skip before brace search
metadata:
  type: project
---

PR #114 (issue #113, permission-gate `gh_api_gate.go`) review found two
classes of scanner bug worth remembering if similar argv/document scanners
get built elsewhere in this repo:

1. **First-match extraction is a security hole even when a walk "looks"
   exhaustive.** `graphqlQueryDoc` returned on the first `-f query=` token
   instead of scanning all of them, so `-f query=A -f query=B` classified
   only A. Fix: collect every match, fail closed (deny) unless exactly one
   is present. Verified live (human, not the sandboxed reviewer) that `gh`
   itself rejects a duplicate `-f query=` with "unexpected override existing
   field under \"query\"" — so this specific case wasn't exploitable through
   today's `gh`, but the gate must not pin its security boundary to an
   undocumented CLI behavior that could change across versions.

2. **A naive "find the next brace" desyncs on GraphQL default values.**
   `query Foo($x: Input = {a: 1}) { ... }` — the variable-definitions list
   can itself contain `{...}`/`[...]` default-value literals. The old
   `indexOfBraceBeforeNextBrace` found the default-value brace, not the
   selection-set brace, and false-denied legitimate read-only GraphQL. Fix:
   `selectionSetBraceIndex` tracks paren depth and only accepts a `{` when
   `parenDepth == 0`, correctly skipping variable-definition and
   directive-argument parens. Applies to both operations and fragment
   definitions (fragments can carry `@directive(x: {a:1})` too).

**Why this matters for future review-fix loops**: both bugs are instances
of the general lesson "when scanning tokens/documents for a security
decision, stopping at the first match (or a naive brace/depth scan) is
wrong — enumerate exhaustively and fail closed on anything ambiguous."
See [[verify-territory-not-relay]] for the related discipline of not
trusting a subagent's/reviewer's claim about live tool behavior without
independent verification (the human verified the `gh` duplicate-field
rejection live; the reviewer explicitly could not from inside the sandbox).
