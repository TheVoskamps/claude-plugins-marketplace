---
name: no-invented-policy-in-agent-defs
description: never assert a rule inside an agent .md that isn't backed by an actual rules file; a fixer's own prior-round addition can itself be the defect the next round removes
metadata:
  type: feedback
---

Round 2 of PR #185 (issue #184) added `--no-verify`/`--no-gpg-sign
(forbidden regardless)` prose to `agent-memory-scrubber.md` on the
fixer's own initiative, to explain what "the commit itself failed"
should not be papered over with. Round 3 (human instruction) required
deleting it outright — not softening it, not citing a different rule,
not adding it to a rules file. Two reasons given: (1) `grep` across
`~/.claude/rules/`, `~/.claude/CLAUDE.md`, `.claude/rules/`, and repo
`CLAUDE.md` found no rule backing "forbidden regardless" — an agent
definition is read as instruction by the next agent that runs it, so
an invented "forbidden" becomes policy nothing actually backs; (2)
commit-signing/force policy is generic commit mechanics that is not a
specific agent's business to assert — sibling agents say nothing like
it and shouldn't have to.

**Why:** an agent `.md` file is instruction-as-code for whoever runs
it next. Prose that sounds like a citation ("forbidden regardless")
but has no source is worse than no prose — it reads as settled policy
to the next reader.

**How to apply:** when writing or fixing agent/skill prose that
touches commit/push mechanics, only assert what's needed for *this
agent's own guard logic* (e.g. "don't delete the branch if the push
failed"). Don't reach for a categorical prohibition on adjacent tools
(`--no-verify`, `--no-gpg-sign`, `--force`, etc.) unless it's grepped
and confirmed to exist in an actual rules file. If in doubt, state the
narrower fact only ("the commit itself failed — stop") and let the
reader's own judgment or an actual rule govern the rest.

See also [[sweep-sibling-agent-guards]] for the same PR's round-3
"sweep the class" instance — propagating a verified-necessary guard
(not an invented one) across sibling files with consistent wording.
