# git-tools

Git-side helpers for the issue-branch lifecycle — create the branch an
issue set is worked on, recover that set from a finished branch's
name, and read a branch's range on `origin` before trusting what was
read from it — plus `test-generate`, a general dev utility that lives
here and is not a git operation.

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

A reader of a branch asks three questions before it trusts what it
read — has the branch moved since I took its head, where does it leave
its base, and which of its commits are new since the head I read last
time — and no single git command answers them. Spelled by hand, the
third goes wrong after a rebase that advances the base: every commit
the base gained is reachable from the new head and not from the
previous one, so a plain `<prev-head>...<head>` reads them as the
branch's own. `/git-range` owns the one fetch, the head check, and a
range bounded by the base and filtered by patch equivalence, and it
exits distinctly when the head has moved so a caller re-reads instead
of reviewing a tree that is gone.

## What it needs first

- **A git working tree with an `origin` remote.** `/git-branch-create`
  fetches the source branch from it and roots the new branch at that
  tip; `/git-range` fetches it once and reads `origin/*` and nothing
  else.
- **`.issues/repo-config.md`, written by the `issues` plugin's
  `/repo-config`.** `/git-branch-create` reads
  `default-issue-source-branch` and `issue-branch-naming-prefix` from
  it, and `/git-issues-from-branch` reads the prefix, so the two halves
  of the round trip strip and add the same thing. Either skill aborts
  pointing back at `/repo-config` when the file is missing.
  `/git-range` and `test-generate` do not read it.
- **An authenticated `gh`, and the `issues` plugin.**
  `/git-branch-create` derives a single-issue slug from the issue's
  title, which it reads through `/issues:issue-view` rather than a
  `gh issue view` of its own, so this plugin declares `issues` as a
  dependency.

`/git-range` needs only the first: it takes every ref and SHA as an
argument and never asks GitHub. `test-generate` needs none of these: it
works on the code in front of it.

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
| `/git-range --base <base-ref> --head-ref <head-ref> --head <sha> [--prev-head <sha>]` | Fetch `origin` once, confirm `origin/<head-ref>` is still `<sha>`, and print that head's merge base with `origin/<base-ref>` and its own commits since a previous head — never a commit the base gained |
| `/test-generate` | Generate unit tests for the code at hand — a general dev utility, not a git operation |

Each skill defines its own behaviour — its arguments, validation,
outcomes, and report shape — and this README does not restate them.

## The one executable

`/git-range` is the only skill here backed by a script, `bin/git-range`,
on `PATH` once the plugin is enabled; the branch skills and
`test-generate` are procedures the model runs. The read is a script
because its steps — a fetch, a ref check against a SHA, a merge base,
and a `rev-list` whose `--cherry-pick`, `--right-only` and
`^origin/<base>` terms each guard a different wrong answer — came out
differently each time a model spelled them, and dropping any one term
yields a plausible, wrong range. The script runs under the bash 3.2
macOS ships and depends on `git` alone. A command it does not handle
that fails exits 1 with a line naming the command, never with git's
own status, so a caller branching on the exit sees only the statuses
the skill documents.

`test/git-range-test.sh` drives the script against a local bare
`origin` it creates and reaches no network: a whole-branch read, a head
pushed after the clone, a moved head, a rebase that advances the base
and rewrites one commit's patch while keeping another's — so only the
changed commit is reported and no upstream commit is — and a clean
rebase, which is an empty range.

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
- **`/git-range` reports and never remedies.** A moved head is an exit
  status, not a re-read; the fetch is its only effect on the checkout,
  and it never checks out, rebases or removes anything.

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
