---
name: removing-an-enumeration-widens-your-own-claim
description: Deleting a consumer/reader enumeration tempts an absolute replacement ("names no X at all"); grep the whole tree first and narrow to the axis you actually cleared, naming the survivors
metadata:
  type: project
---

When a round deletes an enumeration (who consumes this field, which
readers parse it), the natural replacement sentence is an absolute:
"`plugins/issues/skills/**` names no `sdlc` reader at all". That is a
NEW claim about the whole tree, not a restatement of the deletion, and
it is usually false — the same tree named the orchestrator twice for
unrelated reasons (`skills/lib/issue.md` saying it is *not* part of
the namespace, `skills/issue-create/SKILL.md` sizing an issue off the
"Files affected" section its analysis produces).

**Why:** the deletion clears one axis (who reads repo-config); the
absolute quantifies over every axis. A grep for the consumer names —
not for the field name — is what separates the two, and it costs one
call.

**How to apply:** after removing an enumeration, grep the whole
directory for each name you removed, then write the replacement
scoped to the axis you cleared ("names no `sdlc` reader **of
repo-config**") and name the surviving mentions with what they are
for, so the next reader can check the claim instead of re-deriving it.
Same move as [[the-absolute-half-of-a-standing-claim]]: swap the
over-broad verb, name the counterexample, say why it is not one.
