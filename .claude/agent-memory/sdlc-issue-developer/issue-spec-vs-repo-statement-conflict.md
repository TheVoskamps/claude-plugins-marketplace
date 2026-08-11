---
name: issue-spec-vs-repo-statement-conflict
description: When an issue's literal spec contradicts a statement already in the repo, implement the issue AND name the exception in the contradicted statement — do not silently pick one side
metadata:
  type: feedback
---

An issue can specify something a repo document already forbids.
On #249 the issue required `theorem-disprover` to default to sonnet with
the pipeline routing haiku per spawn, while
`plugins/sdlc/skills/orchestrate/SKILL.md` stated that a per-call
`model` override "may only **raise** an agent above its declared
frontmatter default, never lower it — the frontmatter is the floor."

**Why:** silently doing either half leaves a live contradiction. Ship
the issue's version alone and the repo asserts the opposite in a file
a future agent reads as policy; ship the repo's version alone and the
acceptance criterion is unmet with no explanation.

**How to apply:** first decide whether the repo statement is a
*harness capability* claim or a *policy* claim — "may only" reads
prescriptive, so it is policy and the issue can carve an exception out
of it. Then implement the issue literally, and in the SAME PR widen
the contradicted statement to name the new exception and say why the
two differ (there, the raise-only rule protects teammates doing
feature work from being under-resourced; the disprover's default is a
ceiling for a class the design has already decided is cheap). Sweep
every restatement — `orchestrate/SKILL.md` carried it in both the
frontmatter paragraph and "Token Efficiency". Say so in the PR body's
design notes so the reviewer grades the carve-out rather than
re-finding the contradiction.

This is not an escalation: the issue answered the design question, so
the only open question was where to record the exception.
