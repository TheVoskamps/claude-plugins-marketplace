---
name: agent-memory-inbox-cleanup
description: "Curate the session's per-branch agent-memory inbox in one acting pass. Grades every captured entry transfer-or-delete, writes the durable ones into the repo's own documentation as present-tense constraints, commits and pushes them on the given branch, and empties the inbox. Takes the branch name."
argument-hint: <branch>
user-invocable: false
---

You are running the `/cc-tools:agent-memory-inbox-cleanup` skill. Turn
this run's captured memory entries into durable repo documentation, and
throw away the rest.

The entries were written by agents in throwaway worktrees and copied
into the inbox by `/cc-tools:agent-memory-inbox-capture`. Nothing reads
the inbox back. You are the only reader it will ever have, so an entry
you neither transfer nor delete is simply lost — grade every one.

Read `skills/lib/agent-memory-inbox.md` for the inbox path and its
`<plugin>-<agent>/` layout, and `skills/lib/agent-memory-grading.md`
for the grading rubric: what counts as durable, the evidence a delete
must produce, how a transfer is phrased, which file it lands in, and
the standard that file is held to once you have written into it — which
includes deleting what no longer earns its place, whoever wrote it.
This skill restates neither.

## Invocation

```text
/cc-tools:agent-memory-inbox-cleanup <branch>
```

- `<branch>` (required) — the branch whose inbox is curated, and the
  branch the transfers are committed and pushed onto.

## Verdicts

Two, and no more:

| Verdict | What happens |
| --- | --- |
| **transfer** | the constraint is written into a `plugins/**/README.md`, a `docs/*.md`, or `CLAUDE.md`, and the inbox entry is deleted |
| **delete** | the inbox entry is deleted and nothing is written |

There is no third verdict that keeps an entry where it is — nothing
reads the inbox back, so keeping an entry there discards it at the end
of the session with extra steps. Two consequences the rubric leaves to
each calling skill follow:

- An entry the rubric grades under "Entries with no code home"
  transfers to the narrowest destination that fits it, having nowhere
  here to be kept.
- The verdict turns on the surviving bar, not the delete bar.
  `transfer` iff the entry states a present-tense constraint this repo
  should carry — the rubric's "What counts as durable" or the class
  beside it. Everything else is `delete`, including an entry you cannot
  pin to a delete case: the rubric's fallback for that is a
  keep-in-place verdict this skill does not have, and publishing into
  the one file every agent reads is the wrong way to resolve a doubt.
  The delete cases remain the shapes to look for, and their evidence
  bar remains what you produce in the report when you cite one.

## Execution

### Check the preconditions

These exist so the skill curates the right memories onto the right
branch and cannot clash with another checkout. Run both before reading
anything:

```bash
git ls-remote --exit-code --heads origin <branch>
git branch --show-current
```

- `<branch>` must exist on `origin`.
- `git branch --show-current` must equal `<branch>`.

On either failure, abort: name the branch you were given and what you
found instead, and change nothing — no edit, no delete, no commit. The
caller checks the branch out; this skill never does.

### Read the inbox

Enumerate this branch's inbox entries:

```bash
find <inbox path for this branch> -type f -name '*.md'
```

An inbox directory that is **absent or empty is not a failure**: it
means no agent wrote a memory this run, or none survived capture's
session-scope filter. Report that there was nothing to grade and stop.

Otherwise read every entry in full, plus the surfaces the rubric grades
against.

### Grade and apply

Give every entry exactly one verdict per the rubric, then:

1. Write each transfer into its destination file first — before any
   deletion, so a failure mid-pass cannot lose a constraint.
2. Delete every graded entry file from the inbox, transfers and deletes
   alike.
3. Remove each now-empty `<plugin>-<agent>/` directory, and the
   branch's inbox directory itself. The inbox is empty when you are
   done.

Deletions are not confirmed with anyone. The inbox is not a repository
and holds no undo, which is why a delete that cites a rubric case has
to produce that case's evidence, and a delete that cites none has to
say so in the report: an unexamined delete is the one thing this pass
cannot take back.

### Land the transfers

Stage by explicit path — `CLAUDE.md`, each `docs/*.md`, and each
`plugins/**/README.md` you changed, whether you wrote a constraint
into it or cut one out of it, plus any
`plugins/<name>/.claude-plugin/plugin.json` whose `version` the repo's
own rules obliged you to bump. Never `git add -A`, and never a
directory-wide add. Nothing under `.claude/agent-memory/` is ever
staged: the memory tree is not part of this flow.

```bash
git add <each path you changed>
git diff --cached --name-only
```

If that output is empty, there is nothing to commit: do not run
`git commit`, and do not report a commit SHA. The previous tip of the
branch is not your commit, and claiming it would misattribute someone
else's work as this run's output. This is a valid outcome, distinct
from the empty-inbox case above — here entries existed and were graded,
they just left the tree unchanged.

Use `git diff --cached --name-only`, not `git status --porcelain`: the
latter also reports untracked and unstaged changes elsewhere in the
worktree, so an unrelated stray file would make its output non-empty
even when nothing was staged, falsely skipping this no-op path and
falling through to `git commit` with an empty index.

Otherwise commit and push:

```bash
git commit -m "Transfer agent memory into repo docs"
git push
```

The commit message must never place a closing keyword (`close`,
`closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`,
`resolved`, case-insensitive) immediately before an issue reference
(`#N`, `owner/repo#N`, `GH-N`, or an issue URL) — that pattern
auto-closes the referenced issue.

A commit or push failure is a genuine failure, not the no-op case
above: do not report success, and do not report a SHA you have not
verified on the remote. Verifying the push is the caller's gate; report
the SHA you pushed and let it check.

## Output

Report one line per entry, grouped by verdict, one per section you cut
from a destination file, and always a `Commit:` line — the field the
caller branches on, so it is present on every path including the ones
where there is no SHA to give:

```text
## Agent memory curation

Transferred (N):
  - <plugin>-<agent>/<file> -> <destination> — <the constraint, one line>

Deleted (N):
  - <plugin>-<agent>/<file> — <the delete case, and the check that substantiated it>
  - <plugin>-<agent>/<file> — no citable delete case; states no constraint the repo should carry

Cut from <destination> (N):
  - <section> — <why it no longer earns its place>

Inbox: emptied
Commit: <SHA> | none — <why nothing was staged>
```

Where the inbox was absent or empty, the report is that one fact plus
`Commit: none`.

The two delete lines above are the two shapes a deletion takes, and
every deleted entry is reported as one of them. A delete that cites a
rubric case quotes the check that substantiated it. A surviving-bar
delete cites no case — there is none to cite — so it says so in those
words instead, which is the whole record a human gets of an entry
nothing else grades.

The per-entry and per-cut lines are the record of a destructive
operation. Report all of them — those are what a human reads to tell
curation from data loss.
