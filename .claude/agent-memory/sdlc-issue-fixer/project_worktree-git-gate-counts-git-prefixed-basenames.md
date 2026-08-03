---
name: worktree-git-gate-counts-git-prefixed-basenames
description: In a worktree-isolated agent, a git command is refused as "names git more than once" when an argument's FINAL path component starts with `git` plus a word boundary (plugins/git-tools, .../git-branch-create) — deepen the path or use the parent directory
metadata:
  type: project
---

In a worktree-isolated agent, these are refused with "this command
names git more than once in a single command, which cannot be verified
to stay inside the worktree":

- `git add CLAUDE.md README.md plugins/git-tools plugins/github-prs …`
- `git status --porcelain plugins/git-tools`
- `git status --porcelain plugins/git-tools/skills/git-branch-create`

while these run fine:

- `git add CLAUDE.md README.md plugins`
- `git status --porcelain plugins/git-tools/skills`
- `git status --porcelain plugins/git-tools/skills/git-branch-create/SKILL.md`
- `git status --porcelain plugins/github-prs`

**Why:** the deciding factor is the **final path component** of an
argument, not how many times `git` appears in the command. A basename
of `git-tools` or `git-branch-create` — `git` followed by a word
boundary — reads to the gate as a second `git` token; `github-prs`
(no boundary after `git`) and any deeper component (`skills`,
`SKILL.md`) do not. Five probes, all deterministic on re-run; the
message text is not in this repo's `plugins/guardrails` source, so
this is a harness-side gate and the rule above is observed behavior,
not read off an implementation.

**How to apply:** this repo is full of `plugins/git-*` paths, so it
fires often. Either pass the parent (`git add plugins`), or extend the
pathspec to a file (`…/git-branch-create/SKILL.md`), or drop the
pathspec entirely. Staging a whole tree is usually fine here because
`.claude/tmp/` is gitignored — but never widen an
`.claude/agent-memory/`-only commit this way. Same family as
[[git-command-form-gate-cd-then-bare-git]] and
[[worktree-isolation-gate-blocks-compound-bash]]: the gate classifies
command *shape* statically, so the workaround is always a re-spelling,
never a `--force`-ish escape.
