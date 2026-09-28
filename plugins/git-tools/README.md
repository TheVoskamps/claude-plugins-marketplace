# git-tools

Git-side helpers for the issue-branch lifecycle — create the branch an
issue set is worked on and recover that set from a finished branch's
name — plus `test-generate`, a general dev utility that lives here
and is not a git operation.

## Why you would want it

A branch name is where this flow records which issues a piece of work
delivers, and in what order. A session that spells that convention by
hand gets it subtly wrong in ways that surface only later: a branch
rooted at whatever commit the worktree happened to be on, a slug that
begins with a digit so the issue numbers can no longer be told from
it, two issue titles mashed into one unreadable slug. And every caller
that later needs the issue set back parses the name its own way.

`/git-branch-create` owns the write and `/git-issues-from-branch` owns
the read, so the convention is stated once, validated before anything
is created, and round-trips: the issues a branch was created for are
the issues its name returns, in the order they were given. A caller
holding its own list of issues can hand it over and get back the
reconciliation — which of them the branch actually bounds — instead
of re-deriving that rule.

## What it needs first

- **A git working tree with an `origin` remote.** `/git-branch-create`
  fetches the source branch from it and roots the new branch at that
  tip.
- **`.issues/repo-config.md`, written by the `issues` plugin's
  `/repo-config`.** `/git-branch-create` reads
  `default-issue-source-branch` and `issue-branch-naming-prefix` from
  it, and `/git-issues-from-branch` reads the prefix, so the two halves
  of the round trip strip and add the same thing. Either skill aborts
  pointing back at `/repo-config` when the file is missing.
  `test-generate` does not read it.
- **An authenticated `gh`.** `/git-branch-create` derives a
  single-issue slug from the issue's title through it.

`test-generate` needs none of these: it works on the code in front of
it.

## Getting started

The entry point is `/git-branch-create`. A typical run starts a
single issue, which needs only the number — the slug comes from the
issue title:

```text
/git-tools:git-branch-create 206
```

A batch worked on one branch lists its issues in implementation order
and supplies the compound slug itself, because a mechanical merge of
several titles is not one:

```text
/git-tools:git-branch-create 206 196 201 guardrails-gate-sweep
```

Either form reports the branch created, the issue set its name
encodes, and the source branch it was rooted at.

Reading a branch back is one line, with a claimed list optional:

```text
/git-tools:git-issues-from-branch issue-206-196-201-guardrails-gate-sweep 206 196
```

## Skills

| Skill | Purpose |
| ------- | --------- |
| `/git-branch-create <issue>… [<slug>]` | Create the issue branch — one issue or a batch — off the configured source branch, named per the repo's convention |
| `/git-issues-from-branch <branch> [<claimed-issue>…]` | Recover the ordered issue set and slug a branch name encodes; reconcile a claimed list against it when one is given |
| `/test-generate` | Generate unit tests for the code at hand — a general dev utility, not a git operation |

Each skill defines its own behaviour — its arguments, validation,
outcomes, and report shape — and this README does not restate them.

## What it deliberately does not do

- **No pull-request or issue-tracker operations.** These skills touch
  branches; opening a PR, linking issues to one, listing a branch's
  PRs, or changing an issue is not theirs. That is also why no
  end-of-lifecycle cleanup lives here: deciding whether a merged branch
  can go means asking GitHub about its PR, and the sweep over what an
  orchestrated run leaves behind belongs with the flow that leaves it.
- **`/git-issues-from-branch` reports and never decides.** It names
  the resolved set and what fell outside it; what a mismatch means, and
  what to do about it, is the caller's call. It also runs no git
  command, so the branch need not exist anywhere.
- **`/git-branch-create` never invents a compound slug.** Two or more
  issues with no slug is a question back to the caller, not a guess.

## Editing this plugin

`/git-branch-create` encodes the issue set in the branch name and
`/git-issues-from-branch` is its inverse, so a change to either edits
both, and `github-prs` and `sdlc` depend on that encoding. The
branch-name grammar is stated once, in `git-branch-create` → "Branch
name"; `git-issues-from-branch` is the only parser of it and the only
place the issue-to-branch reconciliation rule is applied. Nothing
downstream restates either — consumers invoke the skill — so a change
to the grammar or the rule is made in this plugin and nowhere else,
and the round trip is the contract to re-check.

Both branch skills read `.issues/repo-config.md` through a
lightweight inline parse of the lines they need rather than the
`issues` plugin's full reader contract, because plugins are
file-sandboxed and that contract is not reachable from here. The
inline read is the same in both, which is what keeps the two halves
of the round trip agreeing; change it in one and the other follows.
