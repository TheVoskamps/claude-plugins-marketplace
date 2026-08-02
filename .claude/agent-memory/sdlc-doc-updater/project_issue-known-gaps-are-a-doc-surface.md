---
name: issue-known-gaps-are-a-doc-surface
description: An issue's "Known gaps left in place" section is the one part the developer reliably does NOT carry into the README — check it every time
metadata:
  type: project
---

When an issue body carries a **"Known gaps left in place"** (or
equivalent "deliberately not fixed") section, treat it as an unmet doc
requirement until proven otherwise. On PR #208 the developer had
already written the README's design prose, verdict table and
mechanism paragraphs — all accurate — but neither of issue #193's two
recorded gaps appeared anywhere in the README.

**Why:** the developer documents what the change *does*; the gaps are
what it deliberately does *not* do, which reads as nothing to write
down. But a gap is exactly the thing a future agent run cannot recover
from the code — the absence of a check looks like an oversight to fix
rather than a decision to respect.

**How to apply:** grep the README for each gap's mechanism name before
concluding it is covered, and check whether any nearby prose now reads
as a completeness claim it cannot support. On #208 the README said the
`.git/`-tree deny "survives independently for reads too —
`cat <primary-clone>/.git/config` still denies", which is true but
reads as covering every spelling while the in-repo spelling allows.
Scoping that sentence and adding a named "Gaps left in place
deliberately" paragraph was the run's main content addition.

Related: [[project_guardrails-permgate-docs-locality]] (the general
"expect the developer's prose to already be current" pattern this is
the standing exception to).
