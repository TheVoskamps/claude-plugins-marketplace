---
name: deleted-line-was-load-bearing
description: on a doc-trim PR, check the DELETED text against the rest of the file — a removed line often was the one reconciling sibling passages, and its removal flips a policy the siblings still state the old way
metadata:
  type: reference
---

A trim PR's risk is not only the prose left behind describing the
trimmed thing (the round-1/2 class). It is also that a **deleted** line
was silently reconciling other passages in the same file.

**Worked case (PR #199, `/repo-config` body trim):** the template line
removed was "Hand-editing is fine for small tweaks, but `/repo-config`
is a full-rewrite tool", replaced with "Never hand-edit this file".
Three other passages in the *same* SKILL.md still told users to
hand-edit that exact file to add a non-standard slot (`effort`). On
main those passages agreed with the old line; after the trim they
contradict the new one. Neither a diff-hunk read nor a
surviving-prose-about-the-template read finds this — the contradiction
lives in passages that are not in the diff and are not *about* the
template.

**How to apply:** for every line a trim PR deletes, ask "was this line
asserting a policy?" If yes, grep the whole file (not just the diff
neighborhood) for other passages that depend on that policy holding.
The cheap probe is a keyword from the deleted line:

```bash
git show origin/main:<path> | grep -n '<policy keyword>'
```

Occurrences on main that are NOT in the diff are the candidates — each
one either agreed with the deleted line (now broken) or was always
independent (fine). Classify each by hand; a count alone proves
nothing. Complements [[re-review-the-whole-diff-fresh]] and the
SWEEP-THE-CLASS principle: the class here is "cross-references to a
policy statement", not "mentions of the trimmed text".

**Also:** `gh pr review --request-changes` fails on your own PR the
same way `--approve` does ("Can not request changes on your own pull
request"). The pr-review-submit skill documents the downgrade only for
approve; apply the same inline-verdict `--comment` fallback. See
[[self-approve-blocked-use-comment]].
