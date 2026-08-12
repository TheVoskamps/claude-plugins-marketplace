---
name: cited-heading-spelling-is-checkable
description: A "file → \"Section Name\"" citation asserts the heading's exact text; one grep of the cited file settles it, and the miss propagates by copy-paste
metadata:
  type: project
---

A citation written as `` `rules/git-workflow.md` → "Issue References" `` is a
claim about the *target file's* heading text, not a title you get to capitalize
to taste. `grep -n '^#' <cited-file>` settles it in one call. In this repo the
heading is `### Issue references` (sentence case), and the capital-R spelling had
propagated to hits across `plugins/sdlc/agents/`, `orchestrate/SKILL.md`,
`docs/plugin-authoring-constraints.md` and `plugins/github-prs/` — every one a
copy of the first.

**Why:** the repo's design deliberately replaces restatements of a global rule
with pointers to it (CLAUDE.md → "A rule that already lives in `~/.claude/rules/`
is *cited*"). A pointer whose section name does not exist is the failure mode
that design trades restatement-drift for, so the spelling is load-bearing rather
than cosmetic.

**How to apply:** whenever you write or rewrite an `→ "Section"` citation, grep
the cited file's headings before committing. When one is wrong, sweep every hit
in the files your PR already touches — the misspelling is always a copy class,
never a one-off. Hits in plugins your PR does not touch stay put: sweeping them
drags in another plugin's mandatory version bump. Say so in the PR body rather
than silently leaving them, and see [[pr-body-is-a-swept-surface]].
