---
name: an-owner-scope-cut-leaves-its-advocacy-prose-behind
description: When an owner decision drops half of what a PR added, deleting the entry is the small part — the rationale comment, README enumeration, tests, PR title/body and any agent-memory note were all written to ARGUE FOR the dropped thing; convert them into a documented exclusion with its reason rather than just removing the mention.
metadata:
  type: project
---

An owner ruling that cuts a PR's scope ("keep X, drop Y") reads like a
one-line revert. It is not: every surface the PR touched was authored to
*justify* Y, so a sweep that only deletes Y's mentions leaves the change
looking like an oversight and invites the next agent to re-add it.

**The class to sweep, on PR #257 (`updateIssue` dropped from the
guardrails GraphQL mutation allowlist):**

- the data entry itself (one map line);
- its **rationale comment**, which spent a paragraph arguing Y met the
  list's criterion;
- the **README enumeration**, which restated that argument in the
  classifier prose;
- the **tests**, whose ALLOW rows for Y flip to ASK pins — and the
  sibling test that bundled Y with an allow-listed field to pin
  all-fields-must-pass now needs a *still-allowed* member as its
  allow-listed half, or it stops testing that property at all;
- the **PR title and body** ([[pr-body-is-a-swept-surface]]);
- **`.claude/agent-memory/`** — another agent's note may record the old
  verdict as measured fact ("probing an `agentAssignment`-carrying
  document confirms **allow**"). Correct the outcome, keep the durable
  lesson, and say the owner overturned it; do not delete the entry.

**Write the exclusion as a decision with its reason, in the code
comment and the doc both.** "`updateIssue` is deliberately NOT on the
list, and putting it there is the tempting change to resist — because
`UpdateIssueInput` carries an `agentAssignment` arm …, and the gate
keys on the field NAME only, so it cannot tell that arm from a title
edit" is what stops the re-add. Pair it with where the need actually
goes (the narrow verb `updateIssueIssueType`), so the exclusion is not
read as a capability gap. Keep any *separate* reason a neighbour is
absent distinct — `updateIssueIssueFieldValue` is off the list because
GitHub has no such field, which is not a policy call at all, and
flattening the two into one paragraph loses both.

**How to apply:** run the both-directions negative control
([[negative-control-the-approved-snippet]]) — re-add the dropped entry
and confirm the new ASK rows fail, remove the kept entry and confirm
its ALLOW rows fail — then replay one row list through the pre-fix and
rebuilt binaries ([[a-parity-fix-moves-verdicts-in-every-direction]])
to show exactly the dropped verb's rows moved and nothing else did.
Related: [[baseline-rebuild-before-editing-a-go-comment]].
