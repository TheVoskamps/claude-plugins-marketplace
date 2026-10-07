---
name: pr-read-cli-interface
description: The contract for sdlc's PR-read CLIs — sdlc-pr-round, sdlc-pr-adjustments, sdlc-fixer-brief and sdlc-records-chain — their arguments, exit codes and output grammar. Preloaded into sdlc:theorem-based-pr-reviewer, sdlc:issue-fixer and sdlc:pr-finalizer via their skills frontmatter; not invoked from the user's slash menu.
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

### `sdlc-pr-round <PR_REF>`

Prints one line: the number of the PR's reviews plus one — the number
of the review round under way, since a round's review lands only when
the round posts. A PR with no review is round `1`. Never exits 3.

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

1. the newest `submittedAt` among the PR's reviews;
2. with no review, the newest instant on any line
   `sdlc-agent-result-persist --mode print` prints for round `<n>-1` —
   the script reads that round's log through that call and through
   nothing else;
3. the PR's `createdAt`, when there is no review and that log is empty
   or absent, as it always is below round 1.

A comment whose first line is a fixer-brief marker or a
theorem-records chunk marker is never printed: each is sdlc's own
output, not an adjustment. Nothing printed means no comment was posted
since the cut. Never exits 3.

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
marker, `<i>/<N>` being a chunk's 1-based position and the chain's
total. When the markers for one total `N` cover every position `1`
through `N`, prints one line and exits 0:

```text
complete\t<N>
```

`\t` is a tab. When more than one total is complete, `N` is the one
whose newest chunk is newest. Otherwise it prints one
`partial\t<i>/<N>` line per marker found, oldest first, and **exits
3**; with no marker on the PR at all it prints nothing on stdout and
exits 3.
