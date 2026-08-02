---
name: lint-rule-can-be-inert-in-resolved-version
description: A configured markdownlint rule can be inert — root MD060 raised nothing because `leading_and_trailing` is not in its option vocabulary at all; a probe firing in NEITHER scope indicts the rule/option, not the config chain — prove chains with a parent-flip, and prove `extends` load-bearing by removing it against a distinctive parent setting
metadata:
  type: reference
---

A probe that fires in *neither* scope indicts the rule or its option
value, not the config chain — so never read that silence as evidence
about inheritance.

**Why:** on PR #211's nested `.claude/agent-memory/.markdownlint.jsonc`
(`"extends": "../../.markdownlint.jsonc"`), the planned propagation
tracer was the root's pinned non-default
`"MD060": { "style": "leading_and_trailing" }` — but a table probe
violating that style raised no MD060 in either scope under
markdownlint-cli2 v0.23.2 / markdownlint v0.41.1. The cause was **not**
version skew: MD060 is `table-column-style`, and its `style` accepts
only `aligned`/`any`/`compact`/`tight`. `leading_and_trailing` belongs
to MD055 `table-pipe-style` — so the pinned value was out of MD060's
vocabulary, which silently disabled the rule outright rather than
falling back to its default. A later round of the same PR corrected
the key to `MD055`, at which point the probe fired in both scopes and
became the propagation tracer this entry was hunting for.

So a key that *looks* pinned can be inert for several reasons — a rule
the resolved version does not implement, a wrong rule ID, or an
out-of-vocabulary option value — and none of them warn. Check the
rule's own `doc/mdNNN.md` at the resolved version's tag for its real
name and option vocabulary before trusting it as a tracer. A silent
tracer must be swapped, not interpreted.

**How to apply:** these probes settle a nested-config review
conclusively, and neither needs the happy path:

1. **Chain live:** flip a distinctive setting in the PARENT (e.g.
   `"MD040": false` at root) and watch the child-scope probe's hit
   disappear. Implicit `default: true` would otherwise fire it, so
   only inheritance explains the silence.
2. **`extends` load-bearing vs decorative:** remove the `extends`
   line while the parent carries a distinctive disable (e.g.
   `"MD009": false`); if the child-scope probe now fires that rule,
   the closest config wins outright and `extends` is what carries the
   parent in. Restore and watch it go silent again.

Revert every flip and confirm `git status --porcelain` empty plus
`git hash-object` == `git rev-parse HEAD:<path>` before writing the
review. Related: [[baseline-lint-before-flagging]] (version skew also
means a rule the reviewer expects may not fire at origin/main
either).

Also from the same session: the worktree gate refuses `$'\xc2\xad'`
ANSI-C quoting inline (too-complex classification) — put byte-level
greps in a `.sh` under `.claude/tmp/` like any other multi-step
experiment; see [[git-sandbox-via-script-file]].
