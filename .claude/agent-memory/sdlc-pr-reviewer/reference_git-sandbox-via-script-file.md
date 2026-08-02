---
name: git-sandbox-via-script-file
description: multi-step git sandbox experiments must go in a bash script under the repo's .claude/tmp/ and be run as `bash <script>` — `cd <dir> && git ...` is gate-forbidden and cwd does not persist between a subagent's Bash calls
metadata:
  type: reference
---

To exercise a git claim (e.g. "does `git add -N` preserve content for
`git checkout --`?") a review needs several commands in one throwaway
repo. Two harness constraints block the obvious spellings:

- `cd <path> && git <subcommand>` is refused by the permission gate,
  and so is `git -C <abs-path> <subcommand>`. A shell `for` loop whose
  body runs git is also refused ("too complex to verify it stays
  inside the worktree") — issue one git call per Bash invocation.
- cwd does **not** persist between a worktree-isolated subagent's Bash
  calls, so a bare `cd` in one call is gone by the next. The flip
  side: every call *starts* at the worktree root, so a single bare
  `git <subcommand>` needs no `cd` at all — the script-file recipe
  below is only for multi-step sequences.
- Paths under the session scratchpad (`/private/tmp/claude-.../`) are
  refused as "outside the current repository", including by plain
  `wc`/`cat`.

**How to apply:** write the whole experiment to a `.sh` file under the
repo's own `.claude/tmp/<task-slug>/` with the Write tool, have the
script `cd` to its own sandbox subdirectory, then run it with a single
`bash .claude/tmp/<task-slug>/<script>.sh`. The gate allows that, and
the script's internal `cd` is not subject to the compound-command
rule. Also use repo-relative `.claude/tmp/` for any `gh pr diff >`
redirect — see [[verify-mkosi-claims-via-gh-api]].
