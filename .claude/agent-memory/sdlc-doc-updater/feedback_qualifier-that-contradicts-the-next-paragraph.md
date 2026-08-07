---
name: qualifier-that-contradicts-the-next-paragraph
description: When a PR carves an exception out of a "every X does Y" statement, check the hedge the developer added actually excludes the new case — the vague qualifier ("every teammate you spawn by name") usually still includes it
metadata:
  type: feedback
---

When a PR introduces the first exception to a blanket statement, the
developer typically patches the statement with a vague qualifier and
then writes the real exception in the *next* paragraph. Read the two
together: the qualifier usually fails to exclude the new case, so the
paragraph pair contradicts itself.

Concrete: PR #242 added `pr-reviewer-high` / `pr-reviewer-xhigh` and
rewrote `plugins/sdlc/skills/orchestrate/SKILL.md` from "The fleet's
declared effort is `medium` on every teammate" to "on every teammate
**you spawn by name**" — but the orchestrator spawns `pr-reviewer-high`
by name too, so the sentence stayed false while reading as fixed. The
same hedge had been copied into the "Token Efficiency" bullet. The
repair is to name the exception in the statement itself ("every
teammate but the higher reviewer tiers"), which is also what the
repo's `CLAUDE.md` sweep section already claims both statements do.

**Why:** the exception paragraph is what the reader trusts, so a
qualifier that silently readmits the exception is a live contradiction
no test catches, and it survives because the diff *looks* like the fix.

**How to apply:** on any diff that adds a variant/exception, grep the
blanket statement's vocabulary (here `effort`), read each hit *with*
the paragraph after it, and ask whether the qualifier's own words
exclude the new member. See [[no-blanket-predicate-over-a-list]] and
[[widened-enumeration-trailing-clause]] — same family, different tell.
