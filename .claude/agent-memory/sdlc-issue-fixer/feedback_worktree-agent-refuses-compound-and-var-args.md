---
name: worktree-agent-refuses-compound-and-var-args
description: In a worktree-isolated agent the harness refuses any Bash command it cannot statically prove stays in the worktree — `mkdir -p X && go build -o Y .` and `bash s.sh bin "$PWD"` were both rejected as "too complex to verify"; use one command per call with literal absolute paths
metadata:
  type: feedback
---

Two commands were refused with *"This agent is isolated in the worktree
…, but this command is too complex to verify that it stays inside the
worktree; break it into plain, separate commands"*:

- `mkdir -p .claude/tmp/x && go -C <dir> build -o ../../.claude/... . && echo BUILT`
- `bash .claude/tmp/x/probe.sh .claude/tmp/x/gate "$PWD"`

Neither touches git, so this is a **different gate** from the
CVE-2025-59536 one in
[[git-command-form-gate-cd-then-bare-git]]. It fires on `&&`-chained
commands and on a **shell variable used as a path argument** (`"$PWD"`)
— the checker cannot resolve either statically, so it refuses rather
than guessing.

**How to apply:** in a worktree-isolated subagent, issue one command per
Bash call and spell every path as a literal — an absolute worktree path,
or a plain relative path with no chaining. Pass the worktree root
literally instead of `"$PWD"`. Splitting `mkdir` out into its own call
and re-issuing the build with the same relative `-o` path both
succeeded unchanged, so the refusal is about the *form*, not the target.
`go -C <abs-dir> <subcommand>` is fine (only `git -C` is blocked).
