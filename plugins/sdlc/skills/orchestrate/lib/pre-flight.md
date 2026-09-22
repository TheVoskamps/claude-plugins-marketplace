# Pre-flight

Two checks run before any analysis, in this order: the primary-clone
check, then the per-repo config read.

## The orchestrator must run from the primary clone

Verify you are running in the primary clone, not in a worktree. If
`git rev-parse --git-dir` returns anything other than `.git` (i.e.,
an absolute path under `.git/worktrees/`), abort with an error
explaining `/sdlc:orchestrate` must be run from the main repo root.
Run this first, before any config work. It guards against
[Anthropic issue #47548](https://github.com/anthropics/claude-code/issues/47548),
where spawning `isolation: worktree` subagents from inside a worktree
silently nests the subagent's worktree under the orchestrator's.

```bash
git rev-parse --git-dir
# expected: .git
# if anything else: ABORT with error
```

## Read the per-repo config

Once the primary-clone check passes, read `.issues/repo-config.md`
with a lightweight **inline** parse of just the fields below — the
`issues` plugin's reader contract is not reachable across the plugin
sandbox, and the orchestrator needs only:

- `issue-link-prefix` (string, e.g. `"#"` for GitHub or `"SET-"` for
  Jira) — used in spawn-prompt templates (`<link-prefix>101`) and the
  final-report tables.
- The optional `github-project:` block (GitHub) or the Jira `status`
  slot — read only for the status-slot gate every issue-status
  transition applies; both degrade to warn-and-skip when absent.

If `.issues/repo-config.md` is missing, abort with: "This repo has
no `.issues/repo-config.md`. Run `/repo-config` to create one."

Throughout the rest of the run, `<link-prefix>` means the resolved
value above.
