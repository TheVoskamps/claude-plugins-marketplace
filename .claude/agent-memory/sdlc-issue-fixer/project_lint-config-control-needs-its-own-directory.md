---
name: lint-config-control-needs-its-own-directory
description: markdownlint-cli2's --config is overridden by directory-discovered config, so a before/after control built with --config silently measures the new config; build controls as scratch dirs each holding their own .markdownlint.jsonc, and check the OLD rule ID for violations the change un-suppresses
metadata:
  type: project
---

Two traps when verifying a change to a lint config, both hit while
fixing PR #211's root `.markdownlint.jsonc`.

**`--config` does not win.** markdownlint-cli2 v0.23.2 treats
`--config <file>` as the *base* configuration; a `.markdownlint.jsonc`
discovered by walking up from the linted file's directory overrides
it. So the obvious negative control — "lint the probe with
`--config <old-config>` and confirm the old behavior" — silently
measures the **new** config instead, and reports the post-fix result
as if it were the pre-fix baseline. It looks like a passing control.

**Renaming an inert key un-suppresses the old rule.** An option value
outside a rule's own vocabulary disables that rule outright rather
than falling back to its default: root
`"MD060": { "style": "leading_and_trailing" }` (a MD055 value on
MD060) kept MD060 silent repo-wide. Correcting the key to `MD055`
therefore did two things, not one — it enabled MD055 *and* restored
MD060 to its default `any`, surfacing 44 latent MD060 hits across four
previously-clean-looking files.

**Why:** both failure modes are silent and both flatter the fix. The
contaminated control produces the answer you wanted, and the
un-suppressed old rule doesn't show up unless you lint beyond the
files you touched.

**How to apply:**

1. Build each arm of a before/after control as its **own scratch
   directory** under `.claude/tmp/<task-slug>/` holding a
   `.markdownlint.jsonc` with that arm's content plus a copy of the
   probe (and, better, a copy of a real repo file that exhibits the
   behavior). Closest config wins outright, so each directory is
   hermetic. Lint both and diff the violation sets.
2. After changing or removing a rule key, lint the repo's whole
   tracked Markdown surface (`git ls-files '*.md'`, excluding
   `.claude/worktrees/`) and tabulate hits **by rule ID** — grep for
   the OLD id as well as the new one. Report hits in files the PR does
   not touch rather than fixing them.
3. Confirm an option value against the rule's own `doc/mdNNN.md` at
   the resolved version's git tag before trusting the key at all; the
   installed version being current rules out version skew as the
   explanation for a silent rule.

See [[prove-config-inheritance-chain-live]] for the companion problem
(proving a nested `extends` actually resolved) — a rule that is inert
for the reason above is useless as that entry's propagation tracer,
which is exactly how this was found.
