---
name: de-specify-rather-than-widen-the-exception
description: When a finding offers "de-specify the restatement OR widen the exception", de-specifying is the repair that needs no sweep contract — and the sweep then runs over every file spelling the value, the PR body included
metadata:
  type: project
---

A finding of the shape "these lines restate value V, contradicting the
file's own claim that it restates nothing of that kind" usually offers
two repairs: drop V from the prose, or widen the claim to name the
exception. Prefer dropping it whenever the sentence survives without
V.

**Why:** widening buys a permanent obligation — every future change to
V has to find and update the exempted sites — where de-specifying ends
the obligation. On PR 250, `orchestrate/SKILL.md` spelled
`theorem-disprover`'s `model: sonnet` twice while claiming to restate
no per-agent model; the routing prose reads identically as "its
frontmatter `model:` is the default the pipeline uses", so the claim
became true again with no exception at all.

**How to apply:** the value's OWNER keeps spelling it — the agent
frontmatter, the config file, the one function that passes it — and
every describer points there. Then grep the literal repo-wide and
expect exactly the owner to come back. The reviewer named two sites;
the grep found four more (a sibling skill twice, `CLAUDE.md`'s own
paragraph, and the PR body's What-changed line), and leaving any of
them would have preserved the very class the finding opened. The
sibling sites matter even when no standing claim covers them: nothing
sweeps them either. Finish by stating the invariant where the claim
lives ("no file outside that frontmatter spells the value, here
included"), so the next writer knows de-specification was a decision
rather than an omission — and re-read the PR body, whose absolute
("only the frontmatter spells it") the body's own earlier section can
contradict. See [[pr-body-is-a-swept-surface]] and
[[the-class-is-the-set-of-uses-not-values]].
