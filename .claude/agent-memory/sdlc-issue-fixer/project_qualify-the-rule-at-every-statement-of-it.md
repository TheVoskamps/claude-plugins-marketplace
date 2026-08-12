---
name: qualify-the-rule-at-every-statement-of-it
description: A finding that one statement of a rule is over-broad is a finding about every statement of it — the test, the Do-NOT list, and the Hard Constraint all need the same qualifier
metadata:
  type: project
---

`orchestrate/SKILL.md` states its spawn-prompt rule three times over: the
keep/cut test at the top of the section, a "Do NOT pass" bullet in the middle,
and a Hard Constraint hundreds of lines later. A review found only the Hard
Constraint ("no named finding, no location") contradicting the pass-list. The
qualifier — *your own* findings, as opposed to a reviewer's findings handed to a
fixer — was missing from all three.

**Why:** a normative document restates its own rule at the altitude each reader
arrives at. Fixing the instance a reviewer happened to quote leaves the other
statements as a second, unqualified source of truth, and the next agent reads
whichever it hits first.

**How to apply:** on a finding of the form "this sentence bans X too broadly",
grep the file for the *rule*, not the reviewer's quoted words — here, the words
`finding` and `location`, which surfaced the two unquoted sites. Grade each hit
and qualify it, then re-read the section joined rather than hunk-by-hunk (see
[[audit-a-prose-sweep-by-added-words]]) — an inserted clause routinely leaves the
surrounding line badly wrapped.
