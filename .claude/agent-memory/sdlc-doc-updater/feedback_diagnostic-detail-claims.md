---
name: diagnostic-detail-claims
description: Prose saying an abort/error "names X" is a claim to check against the literal message strings — a validator with two branches often names X in only one of them, and the same sentence is copied to several doc surfaces.
metadata:
  type: feedback
---

When docs say a check aborts "with the mount path named" / "naming the tier,
the entry number and the url", read the actual `echo`/`log` lines of every
branch of that validator before letting the sentence stand.

**Why:** issue #226's `claude_vm_check_mounts` has two branches — the tagless
one interpolates `'$src'`, the sourceless one cannot (there is no path). Four
doc surfaces (payload/README.md twice, config-boot.example.yml,
skills/claude-vm/SKILL.md) all said the path is named for *either* mistake,
because the sentence was written once and copied. Every test passed: the
behavior is right, only the description of the diagnostic is wrong, and
nothing but reading the strings catches it.

**How to apply:** for each abort/warning a doc describes, grep the function
and count its emitting branches; the doc must describe the WEAKEST branch, or
say which detail belongs to which case. Then sweep the other surfaces — this
kind of sentence is never in only one file. Related:
[[no-blanket-predicate-over-a-list]].
