# git-tools changelog

## 0.11.0 — 2026-10-18

Adds the `git-default-branch` executable, which prints the repo's default
branch for a script that must never remove it. It asks GitHub's setting
through `gh` first and falls back to the `origin/HEAD` symref, exiting
non-zero when neither names a branch. It has no skill of its own.

## 0.10.0 — 2026-10-12

Adds `/git-branch-sync`, the fixed git steps around work on an existing
branch, with one exit-status contract. The sequences arrive from `sdlc`'s
agents, which spelled them out for the model to run.

- `checkout` is fast-forward only and records the remote tip it saw. A
  diverged local branch is refused with nothing reset.
- `rebase`, `continue` and `abort` handle a rebase without ever opening
  an editor. A stop exits with the conflicted paths on stdout, and
  resolving them stays with the caller. `continue` keeps the commit's
  message and author, and skips a commit the resolution leaves empty.
- `push` decides against the recorded tip, so a commit another writer
  pushed after the checkout is refused rather than replaced. It refuses
  a branch behind that tip, or one with no tip recorded. It confirms the
  push against the remote and checks the tree is clean, skipping paths
  given with `--exclude`. It never uses `--force`.
- `release` drops the local branch and its record, discarding whatever
  the branch still holds.

## 0.9.0 — 2026-10-11

The branch-name grammar and the claimed-list reconciliation now live in
one tested script, `git-issue-branch`, behind `/git-branch-create` and
`/git-issues-from-branch`. `encode` prints a branch's name and `decode`
reads its issues and slug back. This plugin is now the grammar's only
statement: `sdlc`, `github-prs` and `issues` stop restating it.

- Issue arguments are `N` or `#N`, space-separated. A comma-separated
  list, a cross-repository reference and an issue URL are rejected.
- Creating a branch requires every issue to exist and be open.
- The branch prefix comes from the `issues` plugin's
  `issue-branch-prefix`, and the skill no longer asks for its value.
- Reading a branch back needs no config and accepts any leading prefix
  segment, so a branch with another user's prefix still decodes.

## 0.8.0 — 2026-10-08

Adds `/git-range`, which fetches `origin`, confirms a branch still
points at the head you read, and prints that head's merge base and its
own commits since a previous head. A commit the base gained is never
reported as the branch's own, even after a rebase, and a moved head
exits distinctly so the caller can re-read. It takes over the git
sequence `sdlc`'s reviewer spelled out by hand.

## 0.7.0 — 2026-09-28

`/git-branch-create` reads an issue's title through `/issues:issue-view`
rather than its own `gh` call, so the plugin now depends on the `issues`
plugin.

## 0.6.0 — 2026-09-27

`/git-cleanup-branches-and-worktrees` is gone: it moved to the `sdlc`
plugin as `/sdlc:cleanup-interim-work`, which also covers scratch
directories and session scratchpads and asks before removing anything.
This plugin no longer makes any pull-request call.

## 0.5.2 — 2026-09-19

Documentation only: the plugin gains a README.

## 0.5.1 — 2026-09-11

Internal only: skill text no longer cites documents outside the plugin.

## 0.5.0 — 2026-09-04

`/git-cleanup-branches-and-worktrees` also removes worktrees directly
under `.claude/worktrees/` left at a detached HEAD, which is how an
agent leaves its worktree behind, so a run's worktrees are now
reclaimed. One counts as pushed only when its commit is reachable from a
remote-tracking ref, and the existing gates on uncommitted changes and
locks still apply. Nested worktrees stay for a human to inspect.

## 0.4.0 — 2026-08-24

The branch skills read `.issues/repo-config.md` instead of
`.claude/rules/repo-config.md`. There is no fallback: a repo that has not
moved its file gets the abort naming `/repo-config`.

## 0.3.2 — 2026-08-20

Internal only: skill text names the renamed PR reviewer.

## 0.3.1 — 2026-08-11

Internal only: skill text names the new review pipeline and drops a
reference to a rules file outside the plugin.

## 0.3.0 — 2026-08-03

Adds batches: several issues worked on one branch and delivered as one
PR.

- `/git-branch-create` takes several issues in implementation order and
  names the branch `issue-<N1>-<N2>-…-<slug>`. A batch supplies its own
  slug. A single issue behaves as before.
- It rejects a slug that starts with a digit or is not kebab-case, and a
  branch name over 100 characters.
- New `/git-issues-from-branch` recovers the ordered issue set and slug
  from a branch name. Given a claimed issue list, it reports what
  resolves, what falls outside the branch's set and what went unclaimed.

## 0.2.0 — 2026-07-16

`/git-branch-create` arrives from the retired `gh` plugin, where it was
`branch-create`; invoke it as `/git-tools:git-branch-create`.

It creates the branch for an issue, named `issue-<N>-<slug>` with the
slug derived from the issue title and an optional configured prefix. It
reads the source branch and prefix mode from the repo-config, and roots
the branch explicitly at the fetched source branch rather than wherever
the worktree happens to be.

## 0.1.0 — 2026-06-22

The plugin at the start of this history:

- `/git-cleanup-branches-and-worktrees` cleans up merged branches and
  stale worktrees.
- `/test-generate` generates unit tests.
