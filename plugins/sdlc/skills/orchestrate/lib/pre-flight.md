# Pre-flight

Three steps run before any analysis, in this order: the primary-clone
check, the per-repo config read, then the sdlc config resolution.

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

## Resolve the sdlc config

Read `skills/lib/sdlc-config.md` and resolve its three tiers per its
"Reading" section, once, here. An abort it calls for stops the run
before any issue is read.

Print every key's resolved value beside the tier it came from, one
line per key, before the readiness gate:

```text
sdlc config:
  seed-review: ask (default)
  merge-wait: monitor (default)
  merge-poll-interval-seconds: 300 (repo user)
  merge-max-unchanged-polls: 15 (default)
```

Throughout the rest of the run, each key's name means its resolved
value. Nothing re-reads a config file after this point.
