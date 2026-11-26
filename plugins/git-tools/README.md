# git-tools

Git-side helpers for the issue-branch lifecycle — create the branch an
issue set is worked on, recover that set from a finished branch's
name, read a branch's range on `origin` before trusting what was read
from it, run the fixed git steps around work on a branch that already
exists, and name the repo's default branch for a caller that must
never remove it — plus `test-generate`, a general dev utility that
lives here and is not a git operation.

## Why you would want it

A branch name is where this flow records which issues a piece of work
delivers, and in what order. A session that spells that convention by
hand gets it subtly wrong in ways that surface only later: a branch
rooted at whatever commit the worktree happened to be on, a slug that
begins with a digit so the issue numbers can no longer be told from
it, several issue titles mashed into one unreadable slug. And every
caller that later needs the issue set back parses the name its own
way.

`/git-branch-create` owns the write and `/git-issues-from-branch` owns
the read, and both go through one script, `git-issue-branch`, so the
convention is applied by code rather than paraphrased on each call,
validated before anything is created, and round-trips: the issues a
branch was created for are the issues its name returns, in the order
they were given. A caller holding its own list of issues can hand it
over and get back the reconciliation — which of them the branch
actually bounds — instead of re-deriving that rule.

A reader of a branch needs to know, before it trusts what it read,
whether the branch has moved since it took the head, where the branch
leaves its base, and which commits are new since the head it read last
time, and no single git command answers all of that. Spelled by hand,
the last goes wrong after a rebase that advances the base: every commit
the base gained is reachable from the new head and not from the
previous one, so a plain `<prev-head>...<head>` reads them as the
branch's own. `/git-range` owns the one fetch, the head check, and a
range bounded by the base and filtered by patch equivalence, and it
exits distinctly when the head has moved so a caller re-reads instead
of reviewing a tree that is gone.

Work committed to a shared branch is wrapped in the same git steps
every time: check the branch out, rebase it onto its base, finish or
abort a rebase that stopped, push, confirm the push landed, and let go
of the branch at the end. Spelled by hand, each goes wrong in a way
that looks like success — a `rebase --continue` that opens an editor
nobody is there to close, a push confirmed by a local log that reads
clean for a commit that never left the machine, a lease taken on the
tip a fetch inside the push just saw, which is the tip a concurrent
writer moved and so refuses nothing. `/git-branch-sync` owns those
steps as one script with one exit-status contract. Its `checkout`
records the `origin/<branch>` tip it saw, and `push` decides against
that record and never a fresh fetch, so a commit another writer pushed
after the checkout is refused rather than replaced. Ancestry against
the record alone picks the push form — a lease when the record is no
longer an ancestor of HEAD, a plain push otherwise — so nothing has to
remember whether a rebase ran. The step that is judgment stays with
the caller: resolving a conflict, after which the resolved paths are
handed back and the rebase walks on.

Git lets one worktree at a time hold a branch, so a run that dies
between `checkout` and `release` leaves a claim that fails its
successor at the first git step. `checkout` reports a held branch with
a status of its own, naming the worktree that holds it, and `reclaim`
releases that claim — but only when releasing it discards nothing and
nothing says the holder is still at work.

## What it needs first

- **A git working tree with an `origin` remote.** `/git-branch-create`
  fetches the source branch from it and roots the new branch at that
  tip; `/git-range` fetches it once and reads `origin/*` and nothing
  else; `/git-branch-sync` fetches from it and pushes to it, and
  touches no other remote.
- **`.issues/repo-config.md`, written by the `issues` plugin's
  `/repo-config`.** `/git-branch-create` reads
  `default-issue-source-branch` from it and aborts pointing back at
  `/repo-config` when the file is missing. Nothing else here opens it:
  the branch prefix reaches `git-issue-branch` through the `issues`
  plugin's `issue-branch-prefix`, and `/git-issues-from-branch` reads
  no config at all.
- **An authenticated `gh`, and the `issues` plugin.** Creating a
  branch asks the `issues` plugin for the prefix and for each issue's
  state and title, so this plugin declares `issues` as a dependency.

`/git-range` and `/git-branch-sync` need only the working tree and its
`origin`: each takes every ref it needs as an argument and never asks
GitHub. `git-default-branch` needs either an authenticated `gh` or an
`origin` whose `HEAD` symref is set, so a checkout that has only one
of them still gets an answer. `test-generate` needs none of these: it
works on the code in front of it.

The scripts run under the bash 3.2 macOS ships.

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

Working on a branch that already exists on `origin` runs between a
`checkout` and a `release`:

```text
/git-tools:git-branch-sync checkout issue-206-space-indent
/git-tools:git-branch-sync rebase main
/git-tools:git-branch-sync push
/git-tools:git-branch-sync release issue-206-space-indent
```

## Skills

| Skill | Purpose |
| ------- | --------- |
| `/git-branch-create <issue>… [<slug>]` | Create the issue branch — one issue or a batch — off the configured source branch, named per the repo's convention |
| `/git-issues-from-branch <branch> [<claimed-issue>…]` | Recover the ordered issue set and slug a branch name encodes; reconcile a claimed list against it when one is given |
| `/git-range --base <base-ref> --head-ref <head-ref> --head <sha> [--prev-head <sha>]` | Fetch `origin` once, confirm `origin/<head-ref>` is still `<sha>`, and print that head's merge base with `origin/<base-ref>` and its own commits since a previous head — never a commit the base gained |
| `/git-branch-sync <subcommand> [<argument>…]` | Check an existing branch out fast-forward only and record the remote tip it saw, rebase it onto `origin/<base>`, finish or abort a rebase stopped on conflicts, push it against that recorded tip and verify the push landed, release the local branch and its record at the end of a run, or reclaim a branch another worktree still holds after its run ended, refusing while that work is unfinished or the holder's lock names a running process |
| `/test-generate` | Generate unit tests for the code at hand — a general dev utility, not a git operation |

## Executables

Enabling the plugin puts these scripts on `PATH`:

- **`git-issue-branch`** — the branch name in both directions.
  `encode <issue>… [--slug <slug>]` prints the name;
  `decode <branch-name> [<claimed-issue>…]` prints `outcome`, `issues`
  and `slug`, one `key: value` line each, and with a claim also
  `resolved`, `claimed-outside` and `unclaimed`.
- **`git-range`** — the read behind `/git-range`. It depends on `git`
  alone.
- **`git-branch-sync`** — the steps behind `/git-branch-sync`. It
  never opens an editor, and it gives each condition it can identify
  an exit status of its own, so a held branch, a stopped rebase and a
  refused push can each be told from a broken checkout.
- **`git-default-branch`** — prints the name of the repository's
  default branch on one line, and takes no argument. It has no skill
  in front of it. The GitHub repository setting wins, through `gh`;
  when `gh` fails or names nothing, the branch `origin`'s `HEAD`
  symref points at is used instead. The setting is first because it is
  the live answer, where the symref is a local copy that a rename on
  GitHub does not update. The symref is the fallback because it is
  what a checkout with no `gh`, an unauthenticated one, or a
  non-GitHub remote still has. When neither names a branch, or a
  command fails, it exits non-zero and prints no name. It exists so
  that a script removing branches can name the one it must keep: a
  hardcoded `main` deletes the wrong branch on the first repo whose
  default is something else.

## The branch name

A convention branch name is

```text
[<segment>/]issue-<N1>-<N2>-…-<Nk>-<slug>
```

The `<segment>/` is the prefix the `issues` plugin resolves from the
repo's prefix mode: the configured initials or name under `initials`
or `name`, and nothing at all under `none`. After the `issue-` marker,
the leading run of all-numeric hyphen-separated tokens is the issue
set, in implementation order; everything from the first non-numeric
token onward is the slug, and a slug is always present. The order is a
record for humans — the order the issues are meant to be worked, which
for a batch carrying a dependency edge is the order that edge forces —
and every comparison against the set is a set comparison, so it never
changes a decision.

The number/slug boundary is what keeps the set recoverable, which is
why a slug may not begin with a digit: `2-space-indent` against issue
206 would read back as the set `{206, 2}` with slug `space-indent`.

### What `encode` rejects

`encode` refuses anything that would leave a name it could not read
back, or a branch for work that cannot be done. An issue is named by
its number in the current repository, with or without a leading `#`;
any other way of naming one is refused. A slug must be lowercase
kebab-case starting with a letter, and a batch must bring its own. The
whole name has a length limit, and every issue must exist and be open.
Each refusal names the offending value and comes before anything is
created.

### Reconciling a claimed list

A branch's issue set is a maximum rather than an equality: a PR may
close a subset of it and never a superset, and where a claimed list
and the branch name disagree the branch name is the higher-fidelity
source. `decode` applies that rule to a claimed list:

- **The claim overlaps the branch's set** — the resolved set is the
  members of the branch's set the claim names. The claim selects, the
  branch bounds.
- **No overlap, and the name carries one issue number** — the resolved
  set is that issue. Standing it in guesses at nothing.
- **No overlap, and the name carries several issue numbers** — no
  resolved set. Standing the whole branch set in could resolve to
  members left out on purpose, and nothing says which to pick. The
  numbers in the name are what is counted, so a name that repeats one
  number, such as `issue-5-5-<slug>`, resolves to none as well.
- **Not a convention branch** — there is no branch set to bound
  anything with, so the resolved set is the claim, unchanged.

Alongside the resolved set come the claimed issues outside the branch
set and the branch members not claimed, which is every member when
nothing resolved. Both are reported and never acted on: whether an
unclaimed branch member is a sanctioned deferral or a silent
under-delivery, and what a claim outside the branch set warrants, are
the caller's decisions.

`decode` accepts a name with or without a `<segment>/` of any value,
whatever the repo's prefix mode, so a branch created under another
user's prefix or before the prefix was configured still decodes.

## What it deliberately does not do

- **No pull-request or issue-tracker operations.** These skills touch
  branches; opening a PR, linking issues to one, listing a branch's
  PRs, or changing an issue is not theirs. That is also why no
  end-of-lifecycle cleanup lives here: deciding what a merged PR
  leaves behind means asking GitHub about the PR. What such a cleanup
  needs from git alone — the one branch it must never remove — is what
  `git-default-branch` supplies.
- **`/git-issues-from-branch` reports and never decides.** It names
  the resolved set and what fell outside it; what a mismatch means, and
  what to do about it, is the caller's call. It also runs no git
  command, so the branch need not exist anywhere.
- **`/git-branch-create` never invents a compound slug.** Several
  issues with no slug is a question back to the caller, not a guess.
- **`/git-branch-create` never asks for the prefix value.** The
  `issues` plugin resolves it from its own config; a repo whose prefix
  mode needs a value the user has not configured fails there, with
  that plugin's message relayed.
- **`/git-range` reports and never remedies.** A moved head is an exit
  status, not a re-read; the fetch is its only effect on the checkout,
  and it never checks out, rebases or removes anything.
- **`/git-branch-sync` never resolves a conflict and never forces.** A
  stopped rebase is an exit status with the conflicted paths on stdout;
  the caller edits them and hands them back. Its push leases against
  the tip its own `checkout` recorded, never `--force` or `--mirror`,
  and no exit of `push` moves the local branch, so no failed push
  removes a local commit. `release` is the one subcommand that discards
  anything, and it discards whatever the local branch still holds.
  `reclaim` deletes a local branch too, but only one whose every commit
  is on `origin`, held by a worktree with no rebase under way and
  nothing uncommitted outside the paths the caller excluded, and it
  leaves those files where they are. Nothing overrides that refusal.
- **`reclaim` never decides that a holder's run has ended.** It reads
  a worktree lock naming a running process as evidence of life and
  never of death, and takes `--holder-ended` as the caller's assertion
  that the run is over. It removes no worktree and no lock.
