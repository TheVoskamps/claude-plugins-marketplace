---
name: worktree-isolation-gate-blocks-compound-bash
description: In a worktree-isolated agent, a Bash call the checker cannot statically resolve — var assignment + redirect, `&&`-chaining, or a `"$PWD"` path argument — is refused as "too complex to verify that it stays inside the worktree" even when every path IS in-bounds; one command per call, literal paths, and scratch files written with the Write tool
metadata:
  type: project
---

In a worktree-isolated agent, a single Bash call of this shape is
refused outright:

```text
R=<worktree-root>
mkdir -p $R/.claude/tmp/<slug>
printf '...' > $R/.claude/agent-memory/probe.md
npx markdownlint-cli2 '...'
```

The refusal reads "this command is too complex to verify that it stays
inside the worktree; break it into plain, separate commands. Refusing to
run it." Every path in that command is inside the worktree — the block
is about *static verifiability*, not an actual boundary violation.

The same gate fires on two further shapes that touch no git and no
variable-borne redirect:

- `mkdir -p X && go -C <dir> build -o ../../<path> . && echo BUILT` —
  plain `&&` chaining.
- `bash .claude/tmp/x/probe.sh .claude/tmp/x/gate "$PWD"` — a shell
  variable used as a *path argument*.

Splitting the `mkdir` into its own call and re-issuing the build with
the same relative `-o` path both succeeded unchanged, so the refusal is
about the command's *form*, not its target. `go -C <abs-dir>
<subcommand>` is fine; only `git -C` is blocked.

**Why:** this is a different gate from the repo-boundary one in
[[repo-boundary-gate-blocks-any-tool-arg-outside-repo]]. That gate
fires when an argument *resolves outside* the repo. This one fires
when the command shape (shell variable holding a path, then a
redirect through it) means the harness cannot statically prove
in-bounds-ness. Same family as the static-argument gate on git in
[[commit-heredoc-gate]] and [[git-command-form-gate-cd-then-bare-git]]:
a path that arrives via `$VAR` defeats static classification.

**How to apply:** in a worktree-isolated agent, do not build scratch
files with shell redirects behind a `$VAR` path. Use the `Write` tool
with a worktree-absolute literal `file_path` (see
[[worktree-path-not-main-clone]]), then run the consuming command as a
separate bare Bash call using a *relative* path — pwd is already the
worktree root, so relative paths are both correct and statically
in-bounds. Pass the worktree root literally rather than as `"$PWD"`.
`rm -f`/`rm -rf` cleanup with literal absolute paths is fine; what is
refused is the unresolvable shape — assignment-plus-redirect,
`&&`-chaining, or a variable in a path argument.
