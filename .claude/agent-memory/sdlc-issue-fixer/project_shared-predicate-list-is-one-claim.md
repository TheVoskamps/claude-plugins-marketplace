---
name: shared-predicate-list-is-one-claim
description: a blanket predicate over a list of files ("these name X only as a list", "not stale-prone") is one full-coverage claim; a finding naming one member obliges re-reading every member, because the wrong grade hides in the members nobody opened
metadata:
  type: project
---

A sentence of the form "*A, B, and C* all have property P" is not
several claims that can be settled one per round — it is one claim
whose truth needs P checked against every member.

**Why:** a fixer handed "member B is wrong" naturally opens B, fixes B,
and pushes; A and C were never re-read, so a wrong grade on either
survives to the next review round looking exactly like a fresh defect.
The reviewer is no backstop — a review round will grade the unnamed
members accurate off a `grep -n` hit list whose lines it never read.
The blanket-negative form ("never", "only", "not stale-prone") is the
worst case, because per `~/.claude/rules/label-uncertainty.md` a
negative can only be substantiated by full coverage in the first place.

**How to apply:** when a finding names one item in a list that shares a
predicate, open every item in the list before committing — the cost is
one Read per member. Then prefer rewriting the sentence so each member
carries its own verified description instead of a blanket grade; a
per-member sentence can go stale singly, but it can't hide a wrong
member behind a right one. Keep whatever practical guidance the grade
encoded (which surfaces to check last, and under what trigger) — the
defect is the reason given, not the priority ordering.

**The completeness half.** When the list is scoped by a *quoted
phrase* — "the apt paragraphs' `hard-secure all-baked config`
(`a`, `b`, `c`)" — it asserts two things: that the predicate holds for
each named file, and that the named files are *all* the files carrying
that phrase. The second half is the one that rots, and it is settled by
one `grep -rn` for the phrase, not by re-reading the members. On #226
round 5 the four-file list was missing three real hits and named a
fourth path that did not exist. Grep the phrase, diff the hit set
against the list, then read each new hit to confirm the predicate
before adding it — a near-miss hit may belong to a *different* class
(there, a sibling spelled "all-**bake-declared**" belonged to the
opposite bullet), so name that exclusion in the prose rather than
silently dropping it.

**The two-noun form is the easiest to miss.** The list need not be
bulleted or parenthesized — a conjoined subject inside one sentence is
the same claim: "the `mounts` **and** `env` name checks run over the
MERGED global+repo set, so a per-repo entry can collide with a global
one" (claude-vm's per-repo config wizard, #135). True of `mounts`,
which really does abort on a duplicate tag across the merged list;
false of `env.set`, where the merge is repo-over-global per key and no
cross-layer check exists at all. Nothing in the sentence's shape flags
that a gate was borrowed from the neighbour it was conjoined with, and
the borrowed half tells an operator to expect an abort that never
comes. When a new key is documented next to an older one, re-read the
older key's gate in the code and give each its own clause — including
the explicit negative ("there is no cross-layer check here"), so the
next writer cannot re-borrow.

**"The suite pins these" is a claim about the fixture, not about the
code.** The predicate can be *coverage*: "config-test.sh pins the four
surviving spellings through the real merge" (#135 round 5) was written
beside a correct, measured list of four — `mode: ro`, `""`, `[]`,
valueless — while the fixture carried three; `[]` had been measured by
hand and never turned into a row. Behavior was right, the coverage
sentence was not, and no test failed on it. Settle it by counting the
fixture rows and the expected-output fields, not by re-reading the code
the sentence is about. And when the count is short, add the missing
case rather than softening the sentence to match — a claim shrunk to
fit thin coverage is the same defect in the other direction. Adding one
also means measuring the *deliberately excluded* neighbour (`mode: {}`,
pruned and tracked on #233) locally, so you know the new row is
discriminating rather than passing because everything in that shape
aborts.

Sibling shapes: [[count-tally-class-includes-back-references]] (the
tally and its downstream back-references are one claim too),
[[staleness-check-both-ends-same-source]] (record site and re-read
site are one claim), [[sweep-sibling-agent-guards]] (where a sweep
stops — inside the change's own hunks).
