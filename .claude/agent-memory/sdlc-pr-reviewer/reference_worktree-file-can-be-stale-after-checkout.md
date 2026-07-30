---
name: worktree-file-can-be-stale-after-checkout
description: In a review worktree, git checkout <branch> can leave a file's working-tree copy stale (blob != HEAD:path), and the Read tool may be handed the PRIMARY-clone absolute path (different checkout, on main) instead of the worktree path — verify blob identity before reading/reviewing.
metadata:
  type: reference
---

Two distinct worktree hazards bit a real review (PR #174, claude-vm
build-guest-image.sh) and cost several tool calls before the actual
review could start:

1. **`git checkout <branch>` can leave a working-tree file stale.**
   After `git checkout issue-106-...`, `git rev-parse HEAD` was the
   right tip, but `git hash-object <file>` did NOT equal
   `git rev-parse HEAD:<file>` for one changed file — the working copy
   was an older version (shorter, missing the reviewed change). Fix:
   `git checkout HEAD -- <file>` to force-restore it from the tip.

2. **The Read tool may resolve a PRIMARY-clone absolute path, not the
   worktree.** The spawn brief / earlier context handed a
   `/…/claude-plugins-marketplace/plugins/…` path (the primary clone,
   still on `main`) while the Bash cwd resolved to
   `/…/.claude/worktrees/agent-XXX/plugins/…` (the PR branch). Reading
   the primary-clone path showed a 524-line file with none of the
   reviewed changes; the worktree path showed the real 933-line file.
   Same relative path, two different checkouts.

**Why:** a review worktree is a separate checkout from the
orchestrator's primary clone. A partial/stale working copy or a wrong
absolute path makes you review the WRONG bytes — and if you assert "the
change isn't in the file," that is a fabricated finding
(`core-principles.md` §9: verify the territory).

Hazard 2 recurred verbatim on PR #192 (`plugins/issues` docs), so treat
it as the default, not an edge case: a Read of
`/…/claude-plugins-marketplace/plugins/issues/skills/repo-config/SKILL.md`
returned the OLD `/issue-address` wording, while the worktree-anchored
`/…/.claude/worktrees/agent-XXX/plugins/…/SKILL.md` returned the
reviewed `multi-issue orchestrator` text. Had I trusted the first read I
would have filed a false "the rewording was missed here" finding on the
exact line the PR fixes. The Edit tool now blocks the shared-checkout
path outright ("This agent is isolated in the worktree … Edit the
worktree copy instead"), but **Read is not blocked** — it silently
returns the primary clone's bytes.

**How to apply:** before reading or reviewing any changed file in a
worktree, confirm you're on the reviewed bytes. Cheap checks:
`readlink -f <path>` (does it resolve under `.claude/worktrees/`?),
`git hash-object <path>` vs `git rev-parse HEAD:<path>` (equal?), and
`wc -l` sanity against the diff's line numbers. If stale, run
`git checkout HEAD -- <path>`. Prefer the worktree ABSOLUTE path
(from `pwd` in a Bash call) for Read, not a path inherited from the
brief. Relates to [[verify-bash-regex-in-real-bash]] — both are
"review the real artifact, not a convenient proxy."
