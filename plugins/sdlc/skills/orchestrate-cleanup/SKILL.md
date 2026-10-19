---
name: orchestrate-cleanup
description: Remove what sdlc runs leave behind — review state, worktrees, local branches, .claude/tmp/ scratch and, for the whole repo, other sessions' scratchpads — for one merged or closed PR, asking nothing, or for the whole repo after one go-ahead; then bring the default branch up to date. --dry-run lists what would go and removes nothing.
---

# Orchestrate Cleanup

Every `sdlc` run leaves its evidence and its interim work behind: the
review state under the repo's `sdlc` state directory, the worktrees its
teammates ran in, the issue branches, and task scratch. This skill
removes it with the `sdlc-orchestrate-cleanup` script, which decides
what goes by scope and asks nothing. Spell the script as a bare name.

Removal is forced: a worktree goes with its uncommitted and unpushed
work and its lock, and a branch goes whether or not it merged. No scope
touches a branch on `origin`, and none removes the default branch.

## Invocation

```text
/sdlc:orchestrate-cleanup <PR> [--dry-run]
/sdlc:orchestrate-cleanup --all [--dry-run]
```

- `<PR>` — one merged or closed pull request, in any form
  `/github-prs:pr-view` accepts.
- `--all` — the whole repository, for a human clearing up after many
  runs.
- `--dry-run` — list what would be removed, and remove nothing.

Any other token in `$ARGUMENTS`, both `<PR>` and `--all`, or neither,
is not a form this skill knows: say so and stop, rather than guessing
what was meant.

## `<PR>`

Run the script and relay its output as it stands:

```bash
sdlc-orchestrate-cleanup --pr <PR> [--dry-run]
```

An open PR, and a PR in another repository than this
checkout's, are refused with nothing removed. The worktrees it removes
are those of the agents the PR's state records, whatever their HEAD,
and any other under `.claude/worktrees/` holding a branch it deletes.

## `--all`

1. List what would go, passing the scratchpad path the harness gave
   this session, verbatim:

   ```bash
   sdlc-orchestrate-cleanup --all --scratchpad <this session's scratchpad> --dry-run
   ```

2. Show the human the full list as the script printed it. Under the
   skill's own `--dry-run`, stop there.

3. Ask one question: whether to remove everything listed. End the turn
   at it.

4. On a yes, run the same command without `--dry-run`, and relay its
   output. Any other answer removes nothing.

## Output

Each item is one line, `<action> <category> <item>`, its action
prefixed `would-` under `--dry-run`. A `failed` line after an item
quotes why that item's action failed; the rest carried on. A
`keep branch` line names a branch left in place because a worktree
still has it checked out, and is not a failure. A run that removes
switches the primary clone to the default branch before it deletes any
branch, or detaches it off a branch it deletes when another worktree
holds the default branch, and ends by pruning the worktree
registrations, fetching with `--prune`, and fast-forwarding the default
branch; it prints a `failed` line only for a step of those that failed.

On a non-zero exit, relay stderr verbatim beside the output. Exit 1
means an action, a step or a command failed. Exits 2 to 5 removed
nothing: 2 is a usage error, 3 an open PR, 4 a default branch that
could not be resolved, and 5 a PR in another repository.
