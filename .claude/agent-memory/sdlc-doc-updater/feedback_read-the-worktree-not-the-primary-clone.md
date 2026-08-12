---
name: read-the-worktree-not-the-primary-clone
description: Build every absolute path from the worktree root, not the repo path in CLAUDE.md's context; a primary-clone Read succeeds and returns plausible pre-PR prose
metadata:
  type: feedback
---

Build every absolute path from the worktree root (the cwd the harness
gives you, `git rev-parse --show-toplevel`), never from the
`/Users/.../claude-plugins-marketplace/` path that appears throughout
the injected CLAUDE.md and memory context.

**Why:** that repo path is the *primary clone*, which sits on `main`.
`Read` against it succeeds and returns real, plausible, pre-PR prose —
so a claim you "verified" is verified against the wrong branch. It is
silent: no error, no branch warning. The tell is a **line-number
mismatch between `grep -n` (run from cwd, i.e. the worktree) and a
`Read` window** — if `grep -n` says the phrase is on line 530 and your
Read of 505-560 shows something else there, you are reading two
different files, not misremembering.

The **injected CLAUDE.md in your system context is that same stale
copy**, and it runs whole sections behind the worktree's — sections
the branch's own base already rewrote, naming agents and rules that
have since been renamed away. So never sweep against the CLAUDE.md you
were handed; Read the worktree's before deciding what a repo rule
says.

**How to apply:** set `R=$(git rev-parse --show-toplevel)` in the first
Bash call and prefix every Read/Edit/grep path with it. Related:
[[no-blanket-predicate-over-a-list]], since a wrong-file read is the
other way a checked claim turns out unchecked.
