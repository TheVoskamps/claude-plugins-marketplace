---
name: issue-spec-vs-repo-statement-conflict
description: When an issue's literal spec contradicts a statement already in the repo, first test whether that statement is true — delete a false capability claim, carve an exception only out of genuine policy — but never silently pick one side
metadata:
  type: feedback
---

An issue can specify something a repo document already forbids. Never
ship one half silently: implement the issue AND settle the contradicted
statement in the same PR.

**Why:** ship the issue's version alone and the repo asserts the
opposite in a file a future agent reads as policy; ship the repo's
version alone and the acceptance criterion is unmet with no
explanation.

**How to apply:** grade the contradicted statement before deciding how
to settle it, because the two grades take opposite repairs.

- A **capability** claim — what the harness can or cannot do — is
  verifiable. If it is false, the repair is to delete it, not to carve
  an exception out of it. An exception would preserve a false claim as
  the general rule.
- A **policy** claim — a choice this repo made, where the harness
  permits both — is not falsifiable, so the issue can carve a named
  exception out of it, with the reason the two differ stated inline.

Prescriptive wording ("may only", "never") does not settle the grade;
it is exactly how a false capability claim reads. On #249 an issue
required `theorem-disprover` to declare a default the pipeline routes
below per spawn, while `plugins/sdlc/skills/orchestrate/SKILL.md` said
a per-call `model` override "may only **raise** an agent above its
declared frontmatter default, never lower it — the frontmatter is the
floor." That reads as policy, and the first round shipped it as one: a
carve-out naming the disprover as the exception. It was a capability
claim, and false — the `Agent` tool's `model` parameter takes a lower,
higher or equal model on any spawn — so a later round removed the
raise-only statement outright, and the carve-outs it had needed went
with it. The carve-out was the wrong repair for that statement, not
merely a weaker one.

Either way, sweep every restatement rather than the one the issue
names: the raise-only rule sat in `orchestrate/SKILL.md`'s frontmatter
paragraph, its escalate-a-hard-issue sentence, its disprover paragraph
and its "Token Efficiency" bullet, and again in
`pr-review-pipeline/SKILL.md` and `CLAUDE.md`. Say in the PR body's
design notes which grade you gave the statement, so the reviewer grades
that judgment rather than re-finding the contradiction.

This is not an escalation: the issue answered the design question, so
the only open question was what the repo statement was worth.
