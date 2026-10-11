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

## What it needs first

- **A git working tree with an `origin` remote.** `/git-branch-create`
  fetches the source branch from it and roots the new branch at that
  tip; `/git-range` fetches it once and reads `origin/*` and nothing
  else.
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

Two skills here are backed by scripts under `bin/`, on `PATH` once the
plugin is enabled; `test-generate` is a procedure the model runs. Both
scripts run under the bash 3.2 macOS ships, and in both a command the
script does not handle that fails exits 1 with a line naming the
command, never with the tool's own status, so a caller branching on
the exit sees only the statuses the skill documents.

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
- **`/git-branch-create` never asks for the prefix value.** The
  `issues` plugin resolves it from its own config; a repo whose prefix
  mode needs a value the user has not configured fails there, with
  that plugin's message relayed.
- **`/git-range` reports and never remedies.** A moved head is an exit
  status, not a re-read; the fetch is its only effect on the checkout,
  and it never checks out, rebases or removes anything.

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
