---
name: shared-predicate-list-is-one-claim
description: a blanket predicate over a list of files ("these name X only as a list", "not stale-prone") is one full-coverage claim; a finding naming one item obliges re-reading every item, or the survivors cost a round each
metadata:
  type: project
---

PR #220 (issue #210) spent three fix rounds on a single sentence in
`.claude/agent-memory/sdlc-doc-updater/project_sdlc-docs-locality.md`.
The sentence graded three surfaces at once — root `README.md`,
`plugins/github-prs/README.md`, `plugins/issues/skills/**` — with one
shared predicate: "these name the agents only as a list, never their
behavior." Rounds 1 and 2 each corrected the one member the reviewer
had named; round 3 found `plugins/github-prs/README.md` still
misgraded (its opening paragraph attributes a PR verb per agent, and
its `/pr-diff` section repeats the diff-consumer list).

**Why:** a sentence of the form "*A, B, and C* all have property P" is
not three claims that can be settled one per round — it is one claim
whose truth needs P checked against every member. A fixer handed
"member B is wrong" naturally opens B, fixes B, and pushes; A and C
were never re-read, so a wrong grade on either survives to the next
review round looking exactly like a fresh defect. The blanket-negative
form ("never", "only", "not stale-prone") is the worst case, because
per `~/.claude/rules/label-uncertainty.md` a negative can only be
substantiated by full coverage in the first place.

**How to apply:** when a finding names one item in a list that shares
a predicate, open every item in the list before committing — the cost
is one Read per member. Then prefer rewriting the sentence so each
member carries its own verified description instead of a blanket
grade; a per-member sentence can go stale singly, but it can't hide a
wrong member behind a right one. Keep whatever practical guidance the
grade encoded (here: check these surfaces last, and only when the PR
changes which skill an agent calls) — the defect was the reason
given, not the priority ordering.

Sibling shapes: [[count-tally-class-includes-back-references]] (the
tally and its downstream back-references are one claim too),
[[staleness-check-both-ends-same-source]] (record site and re-read
site are one claim), [[sweep-sibling-agent-guards]] (where a sweep
stops — inside the change's own hunks).
