---
name: staleness-check-both-ends-same-source
description: a "did it move since?" check must read the recorded value and the later re-read from the same authoritative surface; a finding that names only the re-read site still obliges you to fix the record site
metadata:
  type: project
---

PR #211 (issue #207) round 1 flagged the orchestrate skill's
"did the branch move since `agent-memory-scrubber` ran" check: it
recorded and re-read `git rev-parse origin/<branch-name>`, a
remote-tracking ref that is only this clone's cached copy and advances
only when this clone fetches. It therefore caught every push made
through the orchestrate flow and missed one made from another clone or
the GitHub web UI — exactly the out-of-band work such a check exists
to notice. The fix reads the live head via
`gh pr view <PR> --json headRefOid --jq .headRefOid` (verified: emits a
bare SHA, equal to the ref when they agree, and needs no fetch, so it
never blocks on an SSH-credential prompt).

The finding named only the `/pr-ready` re-read site. Fixing only that
site would have left the *record* site on the cached ref, so the
comparison would be a cached value against a live one — an asymmetry
that reports "moved" whenever the recording clone was merely behind.
Both ends moved to the API read.

**Why:** a staleness check is a comparison, and a comparison is only
as sound as its weakest end. Hardening the read the reviewer happened
to point at, while leaving the other end on a different surface, looks
like compliance and produces a check whose failures are noise. It is
the global "verify the territory, not the map" rule
(`~/.claude/rules/label-uncertainty.md`) applied to a runbook someone
else will execute rather than to your own next assertion.

**How to apply:** when a finding says "this check reads a stale/cached
surface," locate every read that feeds the same comparison — the
record, the re-read, and any third site that reports it — and move all
of them to the authoritative surface in one edit. Then actually run
the replacement command once and paste its real output into your
reasoning; a runbook step that was never executed is a guess about
flag spelling as much as about semantics. Related:
[[scope-guarantee-claims-to-actual-caller]] (a claim true of one
caller's habits is not true of the mechanism).
