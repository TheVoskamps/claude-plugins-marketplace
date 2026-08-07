---
name: cache-lag-self-referential-acceptance
description: A PR-body claim that "this PR's own review round" exercises a new/changed agent definition is self-falsifying — reviewers spawn from the installed plugin cache, which lags the branch; verify against your own observed spawn state (memory dir name, inline vs preloaded protocol, brief vocabulary)
metadata:
  type: reference
---

A PR that adds or rewrites an sdlc agent definition cannot have that
definition exercised by its own review round: the reviewer is spawned
from the installed plugin cache (e.g. `sdlc 0.12.0`), which carries
the pre-PR definition until the plugin is reinstalled — normally after
merge. So a PR-body verification claim of the shape "the acceptance
bullet that a real variant spawn shows X is exercised by this PR's own
review round, which is spawned as `<new-agent>`" is falsifiable from
inside the review itself.

How to check, without any tool call: read your own spawn state.

- Your agent-memory path (`.claude/agent-memory/<agent-name>/`) names
  the definition you actually are.
- Whether your operating instructions arrived inline (old monolith) or
  as a preloaded skill.
- The spawn brief's vocabulary (old prose template vs the new
  parameter shape the PR introduces).

Seen on PR #242 (issue #239, reviewer-tier variants): the body claimed
the review round was a `pr-reviewer-high` spawn proving preload; the
actual round ran as base `pr-reviewer` under the old monolithic
definition from cache 0.12.0. Graded as an unmet acceptance criterion
(High) because the claim is a load-bearing developer claim observed
false — the criterion needs a real spawn under the branch's plugin
build, or an explicit human-owned deferral with the body corrected.

**How to apply:** on any PR touching `plugins/sdlc/agents/*` or a
skill an agent preloads, treat "verified by this very review" claims
as suspect first, and check your own spawn state before accepting.
