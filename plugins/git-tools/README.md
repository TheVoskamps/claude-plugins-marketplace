# git-tools

Git-side helpers for the issue-branch lifecycle — create the branch an
issue set is worked on, recover that set from a finished branch's
name, read a branch's range on `origin` before trusting what was read
from it, run the fixed git steps around an agent's own work on a
branch that already exists, and name the repo's default branch for a
caller that must never remove it — plus `test-generate`, a general dev
utility that lives here and is not a git operation.

## Why you would want it

A branch name is where this flow records which issues a piece of work
delivers, and in what order. A session that spells that convention by
hand gets it subtly wrong in ways that surface only later: a branch
rooted at whatever commit the worktree happened to be on, a slug that
begins with a digit so the issue numbers can no longer be told from
it, two issue titles mashed into one unreadable slug. And every caller
that later needs the issue set back parses the name its own way.

`/git-branch-create` owns the write and `/git-issues-from-branch` owns
the read, and both go through one script, `bin/git-issue-branch`, so
the convention is applied by code rather than paraphrased on each
call, validated before anything is created, and round-trips: the
issues a branch was created for are the issues its name returns, in
the order they were given. A caller holding its own list of issues can
hand it over and get back the reconciliation — which of them the
branch actually bounds — instead of re-deriving that rule.

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

An agent that commits to a branch it shares runs the same git steps
every time around the work itself: check the branch out, rebase it onto
its base, finish or abort a rebase that stopped, push, confirm the push
landed, and let go of the branch at the end. Spelled by hand, each copy
drifts in a way that looks like success — a `rebase --continue` that
opens an editor nobody is there to close, a push confirmed by a local
log that reads clean for a commit that never left the machine, a lease
taken on the tip a fetch inside the push just saw, which is the tip a
concurrent writer moved and so refuses nothing. `/git-branch-sync` owns
those steps as one script with one exit-status contract. Its `checkout`
records the `origin/<branch>` tip it saw, and `push` decides against
that record and never a fresh fetch, so a commit another writer pushed
after the checkout is refused rather than replaced. Ancestry against the
record alone picks the push form — a lease when the record is no longer
an ancestor of HEAD, a plain push otherwise — so nothing has to remember
whether a rebase ran. The one step that is judgment stays with the
caller: resolving a conflict, after which the resolved paths are handed
back and the rebase walks on.

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
- **An authenticated `gh`, and the `issues` plugin.** `git-issue-branch
  encode` runs `issue-branch-prefix` for the prefix and `issue-view`
  for each issue's state, both executables the `issues` plugin puts on
  `PATH`, and `/git-branch-create` derives a single-issue slug from the
  title `/issues:issue-view` prints, so this plugin declares `issues`
  as a dependency.

`/git-range` and `/git-branch-sync` need only the first: each takes
every ref it needs as an argument and never asks GitHub.
`git-default-branch` needs either an authenticated `gh` or an `origin`
whose `HEAD` symref is set: it asks `gh` first and falls back to the
symref, so a checkout that has only one of the two still gets an
answer. `test-generate` needs none of these: it works on the code in
front of it.

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
| `/git-branch-sync <subcommand> [<argument>…]` | Check an existing branch out fast-forward only and record the remote tip it saw, rebase it onto `origin/<base>`, finish or abort a rebase stopped on conflicts, push it against that recorded tip and verify the push landed, or release the local branch and its record at the end of a run |
| `/test-generate` | Generate unit tests for the code at hand — a general dev utility, not a git operation |

Each skill defines its own procedure — how it drives its script, what
it asks the caller, and the report it hands back — and this README
does not restate those. What it does state is the contract of the
branch-name script the two branch skills share, because the script's
usage text carries only its synopsis and output keys.

## The branch name

A convention branch name is

```text
[<segment>/]issue-<N1>-<N2>-…-<Nk>-<slug>
```

The `<segment>/` is the prefix `issue-branch-prefix` resolves from the
repo's prefix mode: the configured initials or name under `initials`
or `name`, and nothing at all under `none`. After the `issue-` marker,
the leading run of all-numeric hyphen-separated tokens is the issue
set, in implementation order; everything from the first non-numeric
token onward is the slug, and a slug is always present. The order is a
record for humans — the order the caller intends to work the issues,
which for a batch carrying a dependency edge is the order that edge
forces — and every comparison against the set is a set comparison, so
it never changes a decision.

The number/slug boundary is what keeps the set recoverable, which is
why a slug may not begin with a digit: `2-space-indent` against issue
206 would read back as the set `{206, 2}` with slug `space-indent`.

### Issue arguments

Every issue argument — to `encode`, to `decode` as a claimed issue, and
to both branch skills — names an issue in the repository of the current
working tree, as `N` or `#N`, where `N` is a positive decimal integer
with no leading zero. Arguments are space-separated. A comma-separated
list, a cross-repository reference (`repo#N`, `owner/repo#N`,
`host/owner/repo#N`) and an issue URL are each rejected, naming the
offending token. Output always carries the bare `N`.

### Validation

`encode` checks its arguments before it runs anything, and the
assembled name's length before it looks any issue up; every failure
names the offending value. The validation errors:

- an issue argument that is not `N` or `#N`;
- one issue and no slug — a fixed message asking for one, which is the
  case `/git-branch-create` answers by deriving the slug from the
  title;
- two or more issues and no slug — a compound slug is the caller's to
  supply, never merged from the titles;
- a slug beginning with a digit;
- a slug that is not kebab-case: lowercase letters, digits and single
  hyphens only, starting with a lowercase letter and not ending with a
  hyphen;
- a branch name longer than 100 characters, prefix included;
- an issue `issue-view` cannot find, with `issue-view`'s own error
  relayed above the script's line;
- an issue whose state is not `OPEN`.

A failure of `issue-branch-prefix` itself is relayed the same way, its
stderr first and the script's line after.

### Reconciling a claimed list

How a PR's issues relate to its branch's name is one rule for every
caller: the branch's set is a maximum rather than an equality, a PR
may close a subset of it and never a superset, and where a claim and
the branch name disagree the branch name is the higher-fidelity source.
`decode` applies that rule, so no consumer re-derives it.

With branch set `B` and claimed list `C`, compared as sets:

- **Overlap** — the resolved set is `B ∩ C`. The claim selects, the
  branch bounds.
- **No overlap, `B` has one member** — the resolved set is `B`. The
  branch names exactly one issue, so standing it in guesses at nothing.
- **No overlap, `B` has several members** — no resolved set. Standing
  the whole of `B` in would resolve to members the caller may have
  deliberately left out, and picking among them is a decision the
  script has no information to make.
- **Not a convention branch** — there is no `B` to bound anything
  with, so the resolved set is `C`, unchanged.

Alongside the resolved set come two lists: the claimed issues outside
the branch set — members of `C` not in `B`, computed against `C` as
passed, so a one-member stand-in never hides one — and the branch
members not claimed — members of `B` the resolved set does not carry,
which is all of `B` when nothing resolved. Both are empty on the
not-a-convention-branch outcome. They are reported, never acted on:
whether an unclaimed branch member is a sanctioned deferral or a silent
under-delivery, and what a claim outside the branch set warrants, are
the caller's decisions.

## The executables

Every skill here but `test-generate`, which is a procedure the model
runs, is backed by a script under `bin/`, on `PATH` once the plugin is
enabled, and one script, `git-default-branch`, has no skill in front
of it: it exists for other scripts to call by name. Each script runs
under the bash 3.2 macOS ships, and in each a command the script does
not handle that fails exits 1 with a line naming the command, never
with the tool's own status, so a caller branching on the exit sees
only the statuses the skill, or the script's own header, documents.

### `git-issue-branch`

`encode <issue>… [--slug <slug>]` prints the branch name;
`decode <branch-name> [<claimed-issue>…]` prints `outcome`, `issues`
and `slug`, one `key: value` line each, and with a claim also
`resolved`, `claimed-outside` and `unclaimed`. The branch name is a
pure string function in both directions, and before the script existed
the model carried it out, paraphrasing the grammar at each call with
nothing checking that encode and decode were inverses. The script is
what makes the round trip a tested contract.

`encode` runs `issue-branch-prefix` once and `issue-view` once per
issue, both called by bare name; it opens no file under `.issues/` or
`$XDG_CONFIG_HOME/issues/` itself, and has no prefix or mode flag.
`decode` runs neither: it strips one optional leading `<segment>/` of
any value, whatever the repo's prefix mode, so a branch created under
another user's prefix or before the prefix was configured still
decodes, and a name that still carries a `/` after that strip, has no
issue number after `issue-`, or has no slug is `not-a-convention-branch`.
It exits 0 on both outcomes.

The script exits 2 on a usage error, having run nothing; 3 or above on
each failure it diagnoses, with a status of its own per failure; and 1
only on a failure it cannot attribute.

`test/git-issue-branch-test.sh` drives the script with stub
`issue-branch-prefix` and `issue-view` executables first on `PATH`,
reaching no network and reading no config: the round trip under each
prefix mode, with and without trailing whitespace on the stub's
values; `N` and `#N` producing the same name and resolving the same
claim; each rejected argument form and each validation error with its
exit status; the relay of a failing `issue-branch-prefix`; `decode`
succeeding while that stub fails and calling neither stub; and every
reconciliation outcome with both side lists.

### `git-range`

The read is a script because its steps — a fetch, a ref check against
a SHA, a merge base, and a `rev-list` whose `--cherry-pick`,
`--right-only` and `^origin/<base>` terms each guard a different wrong
answer — came out differently each time a model spelled them, and
dropping any one term yields a plausible, wrong range. It depends on
`git` alone.

`test/git-range-test.sh` drives its script against a local bare
`origin` it creates and reaches no network: a whole-branch read, a head
pushed after the clone, a moved head, a rebase that advances the base
and rewrites one commit's patch while keeping another's — so only the
changed commit is reported and no upstream commit is — and a clean
rebase, which is an empty range.

### `git-branch-sync`

The branch steps are a script because the hand-spelled form of each
goes wrong in a way that looks like success, and a script pins the form
that does not. It disables the editor for every git command it runs —
`GIT_EDITOR` and `GIT_SEQUENCE_EDITOR` are no-ops — and `continue`
commits the stopped commit under `REBASE_HEAD`'s message and author, so
a resumed rebase never waits on a prompt and never rewrites the
commit's provenance.
The tip `checkout` saw is kept in the ref `refs/git-branch-sync/<branch>`
in the clone itself, so it survives between invocations with no state
file and goes when `release` deletes it, and `push`'s lease is
`--force-with-lease=refs/heads/<branch>:<that tip>`: git refuses it
when the remote holds anything else, which is what a lease on a freshly
fetched tip cannot do. A push git reports `[rejected]` — stale info,
fetch first, non-fast-forward — is that refusal and exits 8; one it
reports `[remote rejected]` is a hook or a rule, and stays an
unclassified 1. The push is then confirmed against the remote rather
than the local log: a fetch, `origin/<branch>` compared with local
HEAD, and `status --porcelain` run from the top level so an untracked
file in another directory is not missed. It depends on `git` alone.

`test/git-branch-sync-test.sh` drives its script against a bare
`origin`, a seed checkout that plays the other writer, and a clone,
all under `mktemp -d`. A logging `git` wrapper on `PATH` records each
push's arguments, so the test asserts which push form was picked and
that no `--force` or `--mirror` ever was. It covers each subcommand on
its own path and the exits that separate them — a diverged checkout
refused, a stopped rebase finished through `continue` and one aborted,
a resolution that empties the stopped commit, a conflicted path git
would quote, a stop reached from a subdirectory — and the push's
refusals: a second writer who pushed after the checkout, with and
without a rebase in between, a `post-receive` hook that moves the branch
so the verification fails, and a `pre-receive` hook that refuses, which
stays an unclassified failure.

### `git-default-branch`

Prints the name of the current repository's default branch, on one
line, and takes no argument. The GitHub repository setting wins,
through `gh repo view`; when `gh` fails or names nothing, the branch
`refs/remotes/origin/HEAD` points at is used instead. The setting is
first because it is the live answer: the symref is a snapshot the
clone took, which a rename on GitHub does not update and which a
remote added by hand and fetched never gets. The symref is the fallback
because it is what a checkout with no `gh`, an unauthenticated one, or
a non-GitHub remote still has, which is why `gh`'s own error is
dropped rather than relayed — a failing `gh` is the case the fallback
exists for, not a failure of the script. It exits 1, with a line
naming both sources, when neither names a branch, and 2 on any
argument, having run nothing.

A caller removing branches resolves the default branch through this
script before it deletes anything, and treats a non-zero exit as "no
protected branch is known" and stops; a sweep that hardcodes `main`
deletes the wrong branch on the first repo whose default is something
else.

`test/git-default-branch-test.sh` drives it with a stub `gh` first on
`PATH` and a clone of a local bare `origin`, reaching no network: the
setting winning over the symref, the fallback when `gh` fails and when
it names nothing, neither source naming a branch, the usage error, and
a failing command the script does not handle.

## What it deliberately does not do

- **No pull-request or issue-tracker operations.** These skills touch
  branches; opening a PR, linking issues to one, listing a branch's
  PRs, or changing an issue is not theirs. That is also why no
  end-of-lifecycle cleanup lives here: deciding what a merged PR
  leaves behind means asking GitHub about the PR, and the sweep over
  what an orchestrated run leaves belongs with the flow that leaves
  it. What such a sweep needs from git alone — the one branch it must
  never remove — is what `git-default-branch` supplies.
- **`/git-issues-from-branch` reports and never decides.** It names
  the resolved set and what fell outside it; what a mismatch means, and
  what to do about it, is the caller's call. It also runs no git
  command, so the branch need not exist anywhere.
- **`/git-branch-create` never invents a compound slug.** Two or more
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

## Editing this plugin

`/git-branch-create` encodes the issue set in the branch name and
`/git-issues-from-branch` is its inverse, both through
`bin/git-issue-branch`, and `github-prs` and `sdlc` depend on that
encoding. The grammar, the issue-argument forms, the validation errors
and the reconciliation outcomes are applied by the script and stated
in this README; the script's usage text carries its synopsis and
output keys only, and neither SKILL.md restates them. Nothing
downstream restates them either — consumers invoke the skills — so a
change to the grammar or the rule is made in the script, with its test
and this README, and nowhere else, and the round trip is the contract
to re-check.

`/git-branch-create` reads `default-issue-source-branch` from
`.issues/repo-config.md` through a lightweight inline parse of that one
line rather than the `issues` plugin's full reader contract, because
plugins are file-sandboxed and that contract is not reachable from
here. It is the only config read in this plugin.

`/git-branch-sync`'s exit statuses are a contract callers branch on,
so each status keeps the one condition it names: a new condition the
script can detect for certain gets a code of its own, and a failure it
cannot classify stays 1. The subcommands share one invariant — `push`
decides against the tip `checkout` recorded, `rebase` and `continue`
leave that record alone, and nothing else records whether a rebase ran
— so a change that lets `push` fetch before it decides, or lets a
rebase touch the record, changes what the lease refuses, and the
other-writer cases in the test are what re-check it.

`git-default-branch`'s non-zero exit is what a caller reads as "no
protected branch is known", so a new source for the name goes in ahead
of that failure, in the order the sources are trusted, rather than as
a new exit status; and a source that can be wrong about the live
default — anything read off the clone rather than the host — goes
after the GitHub setting, never before it.
