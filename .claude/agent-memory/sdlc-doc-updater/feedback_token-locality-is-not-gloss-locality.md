---
name: token-locality-is-not-gloss-locality
description: A "the tokens live in N files" locality claim is settled by grepping the token; the DEFINITIONS of those tokens are often restated elsewhere against a different vocabulary and the grep never reaches them.
metadata:
  type: feedback
---

When a rule says a vocabulary "lives in these N files", grep the token
AND grep a distinctive phrase from its gloss. The two answers differ
whenever some consumer restates the definitions against its own names.

**Why:** CLAUDE.md's consequence-class paragraph asserted the defining
glosses "live in the two agent files only; the pipeline carries the
bare tokens in its class-to-severity table and nothing more". True of
the tokens, false of the glosses: the same PR added
`pr-review-pipeline/SKILL.md` → "The findings that carry no class",
which restates every class definition keyed to the **severity** names
(Critical/High/Medium/Low) and says outright they are "the same ones
the classes name". A token grep returns zero hits there, so the
locality claim reads as verified while the surface that silently keeps
an old meaning is exactly that section.

**How to apply:** on any "X is spelled in exactly these files" claim,
pick one content word from the definition itself ("opens a security
hole", "genuinely optional") and grep that too. A translation layer —
tokens to severities, classes to labels, codes to messages — is where
the restatement hides. Related: [[no-blanket-predicate-over-a-list]],
[[fan-out-doc-surfaces]].
