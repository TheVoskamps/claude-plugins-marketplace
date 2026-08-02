---
name: shared-predicate-list-is-one-claim
description: a blanket predicate over a list of files ("these name X only as a list", "not stale-prone") is one full-coverage claim; a finding naming one member obliges re-reading every member, because the wrong grade hides in the members nobody opened
metadata:
  type: project
---

PR #220 (issue #210) carried a single sentence in
`.claude/agent-memory/sdlc-doc-updater/project_sdlc-docs-locality.md`
that graded three surfaces at once — root `README.md`,
`plugins/github-prs/README.md`, `plugins/issues/skills/**` — with one
shared predicate: "these name the agents only as a list, never their
behavior." It stood byte-identical from the commit that created it
(e0eec6e) through the round-2 head (5037a81): review round 1 named no
member of it and endorsed it outright in its Verified list, and round 2
named exactly one member, `plugins/github-prs/README.md`, while grading
the other two accurate. The single fix round that reworked the sentence
(130bff5) corrected that named member and also caught
`plugins/issues/skills/lib/repo-config.md`, which round 2 had just
graded accurate — the wrong member was one nobody had opened.

**Why:** a sentence of the form "*A, B, and C* all have property P" is
not three claims that can be settled one per round — it is one claim
whose truth needs P checked against every member. A fixer handed
"member B is wrong" naturally opens B, fixes B, and pushes; A and C
were never re-read, so a wrong grade on either survives to the next
review round looking exactly like a fresh defect. The reviewer is no
backstop: round 2 above graded both unnamed members accurate, one of
them off a `grep -n` hit list whose lines it never read. The
blanket-negative form ("never", "only", "not stale-prone") is the worst
case, because per `~/.claude/rules/label-uncertainty.md` a negative can
only be substantiated by full coverage in the first place.

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
