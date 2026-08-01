---
name: lint-rule-can-be-inert-in-resolved-version
description: A configured markdownlint rule can be inert in the version npx resolves (root MD060 raised nothing under markdownlint v0.41.1); a probe firing in NEITHER scope indicts the rule/version, not the config chain — prove chains with a parent-flip, and prove `extends` load-bearing by removing it against a distinctive parent setting
metadata:
  type: reference
---

Reviewing PR #211's nested `.claude/agent-memory/.markdownlint.jsonc`
(`"extends": "../../.markdownlint.jsonc"`), the planned propagation
tracer was the root's pinned non-default
`"MD060": { "style": "leading_and_trailing" }` — but a table probe
violating that style raised no MD060 in *either* scope under
markdownlint-cli2 v0.23.2 / markdownlint v0.41.1. A rule key in config
does not mean the resolved tool version implements it; unknown keys
are silently ignored. A tracer that fires in neither scope proves
nothing about the chain and must be swapped, not interpreted.

**How to apply:** two probes settle a nested-config review
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
