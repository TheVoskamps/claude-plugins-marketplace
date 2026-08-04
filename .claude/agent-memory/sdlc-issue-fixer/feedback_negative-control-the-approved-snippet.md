---
name: negative-control-the-approved-snippet
description: When the spawn brief hands you an approved code snippet, run the doctored failure cases against the snippet AS WRITTEN before shipping it — an approved fix can still leave a case from its own finding failing open
metadata:
  type: feedback
---

An "approved design" in the spawn brief is a *direction*, not a verified
artifact. Before shipping it, run every doctored failure case the finding
names against the snippet **exactly as written**, as a negative control,
and only then against your integrated version.

**Why:** on PR #217 the human's approved wrapper mapped exit 126/127 plus
"exit 0 with empty stdout" to a fail-closed deny. Run against the finding's
own named trigger — "a truncated or zero-byte copy committed" — the
truncated binary was killed by the kernel and exited **137 on darwin-arm64
/ 139 on linux-arm64**, neither 126/127 nor 0, so the snippet as written
passed that status straight through to the harness, which reads any status
other than 0/2 as a *non-blocking* hook error. The very case the round
existed to close would have shipped still failing open. One extra arm
(`rc` is neither 0 nor 2 → deny) closed it; the empirical run is what
found it, not reading.

**The same move settles a counterfactual you write into a comment.** A
justification of the shape "keyed on X, not Y, because Y would
double-count" is a claim about code that does not exist — so make it
exist for one run: back the file up into `.claude/tmp/`, flip the line to
Y, re-measure, restore with `/bin/cp -f`. On #227 flipping the descent
from `stmt.Redirs` to the merged set took the emitted-command count for
`{ cat; cat; } < <(cat /etc/passwd)` from 3 to 5 — the comment's "once
per statement inside the construct" was exactly right, and would have
been a guess otherwise. The same backup/flip/restore loop is how you
prove a *new* regression test actually fails against the pre-fix code.

**How to apply:** build the doctored cases first, then run *two* wrappers
over the same trees — the approved snippet and yours — and print the raw
exit status per case, not just pass/fail. If your version blocks a case the
approved one does not, you have found real work; keep the control in the
verification record and say plainly in the report that you extended the
approved design and why. This is the same discipline as
[[bounded-poll-then-unbounded-wait]], pointed forward at the proposed fix
rather than backward at the old shape. Related: [[finish-it-dont-defer-it]]
— the extra arm belongs in this round, not a follow-up issue.
