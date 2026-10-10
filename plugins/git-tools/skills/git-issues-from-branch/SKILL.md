---
name: git-issues-from-branch
description: Recover the ordered issue set and slug an issue branch's name encodes (issue-<N1>-<N2>-...-<slug>), and optionally reconcile a caller's claimed issue list against it. The inverse of git-branch-create.
---

# Git Issues From Branch

Recover the issues a branch name carries — the **ordered issue set**
plus the slug — or report that the branch does not follow the
convention at all. Handed a caller's **claimed** issue list as well,
report how the claim reconciles against the branch.

This is the inverse of `git-tools:git-branch-create`: given a branch
that skill created, this one returns the issue numbers it was given,
in the order it was given them, and the slug it used.

Consumers in other plugins invoke this skill rather than parsing a
branch name or reconciling a claim themselves. Each keeps its own
**action** per outcome; none re-derives the outcome itself.

The skill parses strings. It runs no git command and reads no config,
so the branch need not exist locally or on the remote.

## Invocation

```text
/git-tools:git-issues-from-branch <branch-name> [<claimed-issue>…]
```

- `<branch-name>` (required, first): the branch name to parse, with
  any prefix segment still attached — e.g. a PR's `headRefName`, or the
  branch a caller is about to open a PR from.
- `<claimed-issue>…` (optional): the issues the caller believes this
  branch delivers, each an issue in this repository as `N` or `#N`,
  space-separated. Supply them to get the reconciliation; omit them and
  this skill parses the name and stops.

## Execution

Run `decode` from the `git-issue-branch` script, which this plugin
puts on `PATH`. It applies the branch-name grammar and the
reconciliation outcomes:

```bash
git-issue-branch decode <branch-name> [<claimed-issue>…]
```

It exits 0 on both outcomes. On a non-zero exit — a usage error, such
as a claimed issue that is not `N` or `#N` — relay its stderr verbatim
and stop.

## Output

Relay the script's stdout as it stands, and nothing else. It prints
one `key: value` line each, in this order:

```text
outcome: <convention|not-a-convention-branch>
issues: <N1> <N2> …
slug: <slug>
```

With a claim, three more lines follow:

```text
resolved: <N> … | (none)
claimed-outside: <N> …
unclaimed: <N> …
```

A list is space-separated, and empty when it has no members.

- **`outcome`** — `convention` when the name follows the grammar;
  `not-a-convention-branch` otherwise, with `issues` and `slug` empty.
- **`issues`** — the branch's issue set, in the order the name carries
  it, which is the implementation order `git-branch-create`'s caller
  chose. It is a record for humans: every comparison against the set is
  a set comparison.
- **`resolved`** — the set the claim resolves to, or `(none)` when
  there is **no safe resolution**.
- **`claimed-outside`** — the claimed issues **outside the branch
  set**.
- **`unclaimed`** — the **branch members not claimed**: those the
  resolved set does not carry.

Report the lists; do not act on them, and do not judge them. Whether
an unclaimed branch member is a sanctioned deferral or a silent
under-delivery, what a claim outside the branch set warrants, and what
to do with no resolved set are consumer decisions.
