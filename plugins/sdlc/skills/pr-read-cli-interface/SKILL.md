---
name: pr-read-cli-interface
description: The contract for sdlc's PR-read CLIs — sdlc-pr-round, sdlc-pr-adjustments, sdlc-fixer-brief and sdlc-records-chain — their arguments, exit codes and output grammar. Preloaded into sdlc:theorem-based-pr-reviewer, sdlc:issue-fixer, sdlc:docs-writer and sdlc:pr-finalizer via their skills frontmatter; not invoked from the user's slash menu.
user-invocable: false
---

# PR Read CLI Interface

Four scripts read what an sdlc run needs off a PR's reviews and
comments: the round under way, the comments posted since the last
round, the fixer brief, and the chain of review-detail chunks. Each
reads and cuts; none of them decides what a comment means — whether an
adjustment is a rejection, an override, a scope drop or a missed defect
stays the caller's judgment. The markers they recognize a comment by
are spelled in the scripts, so a caller that reads through them spells
no marker of its own.

## Invocation

```text
sdlc-pr-round <PR_REF>
sdlc-pr-adjustments --pr <PR_REF> --round <n>
sdlc-fixer-brief [--all] <PR_REF>
sdlc-records-chain <PR_REF>
```

Spell each as a bare name, never by path. `<PR_REF>` is the PR's
canonical reference, `<host>/<owner>/<repo>#<n>`, as
`/github-prs:pr-view <PR> --ref` prints it. Any other form — a bare
number, a reference without its host, a URL — is a usage error.

## Exit status

Every script shares these:

| Exit | Meaning |
| --- | --- |
| 0 | the script did what it says |
| 1 | a command the script ran failed, such as the `gh` read, and its own error is on stderr above the script's line |
| 2 | a usage error; nothing was read |
| 3 | the script's own negative outcome, named under the script below |

## The scripts

`sdlc-pr-round` and `sdlc-pr-adjustments` read only a PR's **pipeline
reviews**, the ones review rounds posted; a code-scanning review or a
human review is never one. A review is a pipeline review when a line of
its body, any line, is the stamp `<!-- sdlc:review-round <n> -->` that
`sdlc-agent-result-persist --mode summary` writes, naming round `<n>`.
A review with no stamp is a pipeline review only when its body has both
a line exactly `## Verdicts` and a line exactly `## Review method`, as
a review posted before the stamp existed does.

### `sdlc-pr-round <PR_REF>`

Prints one line: the number of the review round under way, from the
PR's pipeline reviews and its rounds' state. It first finds `base`, the
round of the newest posted review:

1. When any review is stamped, `base` is the highest stamped round.
2. Otherwise, with `P` the number of pipeline reviews, `base` is the
   `P`th round holding a review file, or `0` when `P` is `0`. A round
   holding a review file is one `sdlc-agent-result-persist --mode
   rounds` prints whose `--mode print-review` succeeds, so a round with
   a log and no review file, such as a placeholder round 1, never
   becomes `base`. When fewer than `P` rounds hold one, as on a machine
   without this PR's state, the script prints `P + 1` and stops.

It then prints the lowest round with a log above `base`, or `base + 1`
when there is none, so a round begun and not yet posted keeps its
number. A PR with no review and no state is round `1`. A failed state
read exits 1. Never exits 3.

### `sdlc-pr-adjustments --pr <PR_REF> --round <n>`

Prints the comments posted since the previous round, each verbatim,
oldest first, each preceded by a line of its own:

```text
--- comment <createdAt> ---
<the comment's body>
```

`--round` is the round under way, from `1`. A comment is printed when
its `createdAt` is later than the **cut instant**, which is the first of
these that exists:

1. the newest `submittedAt` among the PR's pipeline reviews;
2. with no pipeline review, the newest instant on any line
   `sdlc-agent-result-persist --mode print` prints for round `<n>-1`,
   when that is round 1 or later — the script reads that round's log
   through that call and through nothing else, and never reads round
   0's, which holds the seed generator's `spawn` record and no review;
3. the PR's `createdAt`, when there is no pipeline review and that log
   is empty, absent or round 0's.

Any other review never sets the cut, so a comment posted before a
code-scanning or human review still reaches the next round.

A comment whose first line is a fixer-brief marker or a
theorem-records chunk marker, in either form `sdlc-records-chain`
reads, is never printed: each is sdlc's own output, not an adjustment.
Nothing printed means no comment was posted since the cut. Never exits
3.

### `sdlc-fixer-brief [--all] <PR_REF>`

Without `--all`, reads the PR's **most recent** comment. When its first
line is the fixer-brief marker, prints its body verbatim and exits 0.
Otherwise it prints nothing on stdout and **exits 3**, with stderr
quoting that comment's first line — or saying the PR has no comment at
all.

With `--all`, prints every comment whose first line is the fixer-brief
marker, oldest first, each preceded by a `--- comment <createdAt> ---`
line, and exits 0 — with nothing printed when the PR carries no brief.

A marker line ending in a carriage return, as a body posted from
GitHub's web form carries, still counts.

### `sdlc-records-chain <PR_REF>`

Reads the first line of every comment for the theorem-records chunk
marker:

```text
<!-- sdlc:theorem-records <first>-<last> <i>/<N> -->
```

`<first>` and `<last>` are the lowest and highest round the chain
holds of those `sdlc-agent-result-persist --mode rounds` lists, and
`<i>/<N>` the chunk's 1-based position and the chain's total. With no
round log there is no listed round, and a records file the chain holds
names the range by its own round, listed or not: the seed's records
alone post as `0-0`. A round
number inside the range that has no log and that the chain holds no
records for was never run. The old form,
`<!-- sdlc:theorem-records <i>/<N> -->`, names no rounds.

A chain is the chunks sharing one range and one total, so chunks of two
chains with the same total never combine; old-form chunks share the
range `-`. When at least one chain's markers cover every position `1`
through `N`, it prints one line per such chain, ordered by its newest
chunk, oldest first, and exits 0:

```text
complete\t<first>-<last>\t<N>
complete\t-\t<N>
```

`\t` is a tab, and the second shape is a complete old-form chain.
Otherwise it prints one `partial\t<range>\t<i>/<N>` line per marker
found, oldest first, `<range>` being `<first>-<last>` or `-`, and
**exits 3**; with no marker on the PR at all it prints nothing on
stdout and exits 3.
