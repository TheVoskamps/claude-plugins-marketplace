---
name: gate-argv-metadata-is-per-token
description: permission-gate simpleCommand now carries per-argument metadata (argMeta.exact / argMeta.staticPrefix) alongside the whole-command hasUnknownExpansion bool; readers MUST length-check it against args because hand-built simpleCommands in tests carry none.
metadata:
  type: project
---

`simpleCommand` carries `argMeta []argMeta` parallel to `args`, added
by issue 225 so the credentialed-tool precondition can ask WHICH token
was dynamic rather than only whether anything was. Two fields:

- `exact` — did this token expand to a static literal.
- `staticPrefix` — the literal text of the word's LEADING fully-static
  parts, stopping at the first part the gate cannot pin. This is what
  distinguishes a dynamic field VALUE (`itemId=$ID` -> `"itemId="`)
  from a dynamic field NAME (`"$K"=v` -> `""`), which matters because
  an inexact word's unresolvable parts expand to `""`, so the expanded
  token alone cannot tell you where the dynamism sat.

**Why it needs care:** `argMeta` is EMPTY on any `simpleCommand` not
built by `reduceCallExpr` — the synthetic redirect-only command, and
every hand-built `simpleCommand{args: …}` in the tests. Every reader
must `len(sc.argMeta) != len(sc.args)` and fall back to
`hasUnknownExpansion`, or a test-built command silently reads index 0's
zero value as "not exact" for every token.

**How to apply:** `stripEnvWrapper` only ever removes LEADING tokens, so
`reduceCallExpr` keeps alignment by trimming the same count off the
front of `argMeta`. Any future front-trim of `args` must do the same.
`hasUnknownExpansion` is still set by a dynamic REDIRECT word, which
occupies no argv slot — so the two signals are not redundant and a
command can have a dynamic redirect with every `argMeta.exact` true.

Related: [[permission-gate-self-hosting]],
[[permission-gate-tests-can-pass-vacuously]].
