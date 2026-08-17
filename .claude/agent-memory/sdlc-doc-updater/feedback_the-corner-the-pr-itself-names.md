---
name: the-corner-the-pr-itself-names
description: When one surface of a round names a corner case ("a digits-only ref would survive"), the round's other surfaces state the same fact as an absolute ("every config aborted") — grep the absolute, the counter-case is already written down.
metadata:
  type: feedback
---

A round that fixes a defect writes the defect's story on several
surfaces at once — a code comment, a test-block comment, a README
paragraph, a `/docs` playbook step. One of them is written carefully
enough to name the corner where the defect does NOT bite; the others
state the same fact as an unqualified absolute, and the absolute is
false exactly in the corner its sibling already spells out.

**Why:** PR #273's bash-3.2 render fix. README said, correctly, that a
digits-only override ref "would be valid arithmetic and would fail
differently" — measured on 3.2.57: `local -A m=(); m["123"]=false`
prints two diagnostics, lives, and reads back `false`. Meanwhile
`lib/config.sh`, `config-test.sh` and
`docs/verification-playbook.md` each said every config carrying a
`claude.plugins.enabled` override aborted (the playbook went further:
"aborting every real launch"). No test can fail on any of it.

**How to apply:** on any round whose prose is repeated across
surfaces, grep the absolute quantifiers — "every", "all", "always",
"never", "any config" — and check each against the most careful
sibling statement of the same fact rather than against the code alone.
The careful one is usually the README or the test comment that had to
justify a fixture choice; the sloppy ones are the code comment and the
playbook. Fix by importing the sibling's qualifier, and say in the
report that the behavior was right and only the scope of the claim was
wrong. Related: [[no-blanket-predicate-over-a-list]],
[[widened-guard-narrow-prose]].
