---
name: agent-memory-inbox-cleanup
description: "Curate the session's per-branch agent-memory inbox in one acting pass. Grades every captured entry transfer-or-delete, writes the durable ones into CLAUDE.md or docs as present-tense constraints, commits and pushes them on the given branch, and empties the inbox. Takes the branch name."
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
must produce, how a transfer is phrased, and which file it lands in.
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
| **transfer** | the constraint is written into `CLAUDE.md` or a `docs/*.md`, and the inbox entry is deleted |
| **delete** | the inbox entry is deleted and nothing is written |

There is no third verdict that keeps an entry where it is. The sibling
`/cc-tools:agent-memory-cleanup` has one — `persist` — because it
curates a `.claude/agent-memory/` tree that agents read back on a later
run. The inbox has no such reader, so "keep it in the inbox" would mean
"discard it at the end of the session with extra steps".

That difference decides two outcomes the rubric leaves to each skill.

An entry the rubric grades under "Entries with no code home" has
nowhere here to be kept, so it transfers into `CLAUDE.md`, where the
sibling skill would have left it in the tree.

And the verdict turns on the surviving bar rather than on the delete
bar. `transfer` iff the entry states a present-tense constraint this
repo should carry — durable lore per the rubric's "What counts as
durable", or an entry with no code home per the class beside it.
Everything else is `delete`. The rubric's delete cases each describe an
entry that fails that bar, so they remain the shapes to look for, and
their evidence bar remains what you produce in the report when you cite
one. What does not carry over is the rubric's unsubstantiated-delete
fallback: it hands the entry to a keep-in-place verdict, and this skill
has none. An entry that is neither a citable delete case nor a statable
constraint is deleted, because writing it into `CLAUDE.md` would put
prose the repo should not carry into the one file every agent reads.

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
means no agent wrote a memory this run. Report "no agent memory to
curate" and stop.

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
and holds no undo, which is why the rubric's evidence bar is the whole
protection: an unsubstantiated delete is the one thing this pass cannot
take back.

### Land the transfers

Stage by explicit path — `CLAUDE.md` and each `docs/*.md` you wrote
into. Never `git add -A`, and never a directory-wide add. Nothing under
`.claude/agent-memory/` is ever staged: the memory tree is not part of
this flow.

```bash
git add <each path you changed>
git diff --cached --name-only
```

If that output is empty — every verdict was delete, so nothing was
written — there is nothing to commit. Report "no changes to curate" and
stop: do not run `git commit`, and do not report a commit SHA. The
previous tip of the branch is not your commit, and claiming it would
misattribute someone else's work as this run's output. This is a valid
outcome, distinct from the "no agent memory to curate" case above —
here entries existed and were graded, they just all graded delete.

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

Report one line per entry, grouped by verdict:

```text
## Agent memory curation

Transferred (N):
  - <plugin>-<agent>/<file> -> <destination> — <the constraint, one line>

Deleted (N):
  - <plugin>-<agent>/<file> — <the check that substantiated it>

Inbox: emptied
```

Then the tail: the commit SHA you pushed, or "no changes to curate"
when every verdict was delete and nothing was staged. Where the inbox
was absent or empty, the whole report is the single line "no agent
memory to curate".

The per-entry lines are the record of a destructive operation. Report
all of them, and quote the check for every delete — those are what a
human reads to tell curation from data loss.
