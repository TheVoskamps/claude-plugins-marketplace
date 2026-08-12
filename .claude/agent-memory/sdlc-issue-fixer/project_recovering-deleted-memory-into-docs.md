---
name: recovering-deleted-memory-into-docs
description: A directive to recover memory entries a curation pass deleted is served by `git show origin/main:<path>` — the branch has the directory gone, and the recovered doc becomes a NEW surface that falsifies "no other file describes X" claims in CLAUDE.md
metadata:
  type: project
---

When a fix round is told to recover technique from memory entries a
curation pass deleted, read them with `git show origin/main:<path>` one
at a time — the branch's own tree no longer has the directory, so a
`Read` of the worktree path fails.

**Why:** the deletion is the diff under review; only the base still
carries the blobs. `git diff --stat origin/main...HEAD` names every
deleted file, so the recovery list is derivable rather than guessed.

**How to apply:** a recovered doc is a new statement of behavior, so
grep the repo for exclusivity claims it now falsifies. On PR #250,
`CLAUDE.md` said gate classifier behavior "lives in
`permission-gate/README.md`, and no other plugin or `/docs` markdown
describes it" — the new `docs/guardrails-verification-playbook.md`
describes verdicts as probe controls, so that sentence needed
narrowing in the same commit, plus a sweep trigger that keeps the
playbook's control rows honest. Same for the claude-vm
read-only-mounts surface list, which the new playbook joins as the
place the measurement lives. See
[[new-arm-falsifies-the-formula-back-references]] for the same shape in
the other direction.

Nothing indexes `/docs` in this repo (no `docs/README.md`, and the root
`README.md` lists plugins only), so `CLAUDE.md` is where a new doc
becomes discoverable. Related: [[pr-body-is-a-swept-surface]].
