---
name: fan-out-doc-surfaces
description: A round that adds a caller-did-this parameter to a fan-out brief (--fetched/--head-sha) documents both ends of the brief and misses docs/plugin-authoring-constraints.md's fan-out section, whose shared-ref-store invariant covers checkout but not fetch contention
metadata:
  type: project
---

A round that tunes a **parallel fan-out** — the pipeline fetches once
and passes `--head-sha` / `--fetched yes` so k disprovers skip their
own fetch — updates both ends of the brief (the pipeline's fan-out
step, the agent's Inputs list and its step 1) and stops there.

The surface it leaves is
**`docs/plugin-authoring-constraints.md` → "Fanning out parallel
agents"**. That section carries the shared-ref-store consequence for
*checkout* (detach or die at exit 128) and nothing about contention on
`git fetch`, which is the same invariant with a second consequence — a
future fan-out author reads the section, not the sdlc pipeline.
Generalize it as: the spawning session fetches, and the receiving
agent must still work when the assertion parameter is absent.

CLAUDE.md's sdlc sweep section is not that surface: it already states
the brief as a two-sided contract, so a double-dash parameter added,
removed or redefined lands in the pipeline's brief block, the
receiving agent's Inputs list, and any step that reads it. Read that
paragraph rather than re-deriving the rule, and grep the parameter
name across `plugins/sdlc/` — the contract is prose on both sides and
greppable no other way.

A mechanical repoint made in the same round (dropping a dangling
pointer mid-paragraph) leaves two-line stubs in the files it edits.
Same class as [[issue-ref-sweep-artifacts]]: read the reflowed
paragraph, not the changed line.

**Why:** the fix round's author is looking at the two files that
implement the behavior; the constraint doc is where the *next* author
looks.

A round that adds a whole new **stage** to the pipeline (a second
fan-out, a new spawned agent) leaves a wider set stale, and the
developer reliably updates only the files that name the pipeline:
`plugins/github-prs/skills/pr-diff/SKILL.md` (its own consumer list,
separate from the two lists in that plugin's README),
`plugins/sdlc/agents/agent-memory-scrubber.md`'s "You persist no
memory of your own" section (which names the review agents that
declare none), and
`plugins/sdlc/agents/doc-updater.md`'s end-of-run cleanup paragraph
(which names the review agents that detach and claim nothing). Grep
the *old* agent names across the repo, not the new one.

**How to apply:** on any sdlc fan-out or brief-parameter change, open
`docs/plugin-authoring-constraints.md`'s fan-out section and CLAUDE.md's
review-exception paragraph before deciding the round has no doc
impact. See [[checkout-contract-doc-surfaces]].
