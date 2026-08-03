---
name: gate-blocks-for-loops-and-zsh-eats-eq-echo
description: The worktree gate refuses `for`-loop compound commands ("too complex to verify") and `git -C <path>` outright; run multi-suite sweeps as sequential bare `bash <suite>.sh` calls chained with `;`. Separately, zsh treats a bare `echo ====` separator as =-expansion and errors — quote separators or use a word like "SEP".
metadata:
  type: reference
---

Two one-cycle traps from PR #228 round 4, both in the Bash tool under a
worktree agent:

- **`for t in a b c; do bash test/$t.sh; done` is gate-refused** with
  "too complex to verify that it stays inside the worktree" — same
  refusal class as compound `cd && git`. A plain `;`-chained sequence of
  bare `bash plugins/.../test/<suite>.sh` calls passes, and two parallel
  Bash calls of 3–4 suites each cover a nine-suite sweep in one turn.
  `git -C <abs-path> <cmd>` is refused by name; but the harness already
  starts this agent with cwd at the worktree root, so bare `git <cmd>`
  works without any `cd`.
- **`echo ====` errors under zsh** (`=== not found`): a word starting
  with `=` triggers zsh's `=cmd` PATH expansion. Use `echo "SEP"` (or
  quote it) when interleaving multi-file `sed -n` dumps in one call.

Related: [[git-sandbox-via-script-file]] (script-file escape hatch for
genuinely multi-step experiments).
