---
name: agent-memory-cleanup
description: "Curate a repo's .claude/agent-memory/ in one acting pass. Grades every entry persist / scrub / transfer, deletes what the code or CLAUDE.md already says, moves durable lore into CLAUDE.md or docs as present-tense constraints, and repairs the MEMORY.md indexes and wikilinks. Takes an optional PR number; with none, curates the current working tree."
argument-hint: [PR-number]
---

# Agent Memory Cleanup

Agents that declare `memory: project` write into
`.claude/agent-memory/` as they work, and that capture is raw and
append-only — no agent judges its own writes. Left alone the directory
fills with entries that restate the code, name a design doc as the
"source of truth", or narrate finished work. Every one of those
misdirects the next agent that reads the index, which is worse than
having no memory at all.

This skill is the curation pass over that directory. It runs after the
writers have captured, grades each entry, and **acts**: it deletes, it
moves durable lore into `CLAUDE.md` or `docs/*.md`, and it repairs the
indexes. It is not read-only, and it does not hand a recommendation to
someone else to apply.

Read `skills/lib/agent-memory-grading.md` for the grading rubric — what
counts as durable, the evidence a delete must produce, how a transfer
is phrased, and which file it lands in. That contract is shared with
`/cc-tools:agent-memory-inbox-cleanup` and is not restated here; what
this skill states is its own third verdict, `persist`, which that
sibling does not have.

## Invocation

```text
/cc-tools:agent-memory-cleanup [PR-number]
```

- `[PR-number]` (optional) — curate the memory on that PR's branch.
  The skill checks the branch out, curates, commits, and pushes, so
  the cleanup lands on the same PR.
- **No argument** — curate the current repo's working tree in place.
  The skill leaves its edits uncommitted for you to review before you
  commit them.

The argument also selects the mode:

| Argument | Mode | Transfers | Result |
| --- | --- | --- | --- |
| PR number | autonomous | applied without asking | committed and pushed onto the PR branch, or left untouched with "no changes to curate" when every verdict was persist |
| none | interactive | confirmed with you one at a time | left uncommitted in the working tree |

Deletions are not confirmed in either mode. Autonomous mode therefore
carries a **precondition on its caller**: every entry this skill scrubs
must already be committed on the branch before the run starts, so the
commit this skill makes is an undo that reverts to a tree still holding
those entries. A caller that checks the branch out fresh in a clean
worktree satisfies it. A caller that invokes this skill over a working
tree already holding untracked, never-committed memory entries does
not, and has no commit to fall back on for those entries. This skill
does not verify the precondition and cannot; the caller owns it. In
interactive mode the uncommitted working tree is the undo **only for
entries git already tracks** — for an entry that is still untracked (a
fresh capture never committed), deleting the file is permanent,
because there is nothing in git to restore it from. No-argument mode
routinely encounters untracked entries: a writer agent's memory
capture that was never committed lands exactly in that state. See
"Apply the verdicts" for how this skill stages untracked entries
before touching them so the working-tree undo claim holds for every
entry, not just tracked ones.

## Execution

### Resolve the scope

With a PR number, check out its head branch:

```bash
gh pr view <PR-number> --json headRefName
git fetch origin
git checkout <headRefName>
```

With no argument, work on the current checkout as it stands. Do not
switch branches and do not fetch.

Either way the target is `.claude/agent-memory/` at the repo root. If
it is absent or empty, report "no agent memory to curate" and stop —
that is a valid outcome, not a failure.

### Read the entries, and the surfaces that grade them

1. Enumerate every memory file:

   ```bash
   find .claude/agent-memory -type f -name '*.md'
   ```

   The layout is one directory per agent
   (`.claude/agent-memory/<agent-name>/`), each holding an index
   (`MEMORY.md`) plus one file per entry.

2. Read every entry file and every `MEMORY.md` in full.

3. Read the surfaces the verdicts are decided against, per
   `skills/lib/agent-memory-grading.md` → "Read before you grade".

### Grade each entry

Every entry gets exactly one verdict, from three.

#### Scrub — delete the entry

The delete cases, and the evidence each one has to produce, are
`skills/lib/agent-memory-grading.md` → "The delete cases" and "A delete
needs evidence". This skill's keep-in-place verdict, which that
rubric's unsubstantiated-delete fallback resolves to, is `persist`.

#### Transfer — move the content out, then delete the entry

What counts as durable, which file the constraint lands in, and how it
is phrased are `skills/lib/agent-memory-grading.md` → "What counts as
durable", "Where a transfer lands", and "How a transfer is phrased".
Then delete the memory entry.

#### Persist — keep the entry

Persist when the entry falls in
`skills/lib/agent-memory-grading.md` → "Entries with no code home".
Nothing in the repo can carry it, and this skill curates a tree that
agents read back on a later run, so the memory is where it belongs.
Restate it present-tense if it is written as the story of when it was
discovered.

### Apply the verdicts

Work one agent directory at a time so an index and its entries stay
consistent:

1. Write every transfer into its destination file first. A transfer
   that deletes the memory before the constraint lands somewhere is a
   data loss.
2. In interactive mode, confirm each transfer with the human before
   writing it: show the destination file and the exact text you would
   add. In autonomous mode, write it.
3. **In interactive mode only**, before deleting anything, check
   whether each entry file about to be scrubbed or transferred is
   already tracked:

   ```bash
   git status --porcelain -- <entry-file>
   ```

   An untracked entry reports `??`. For any `??` entry, run
   `git add <entry-file>` (a full add, staging the actual content —
   **not** `git add -N`/intent-to-add, which records only the path and
   leaves `git checkout -- <entry-file>` restoring an empty file
   instead of the original content) before deleting it. Staging the
   real content makes the deletion recoverable via
   `git checkout -- <entry-file>` (or `git restore --staged --worktree
   <entry-file>`) the same way a tracked file's deletion is, so the
   "uncommitted working tree is the undo" claim actually holds. The
   file now shows staged (`git status` reports `A` then `AD` after the
   delete) rather than fully uncommitted, but the content is fully
   recoverable, which is what the undo claim depends on. Skip this
   check for autonomous mode — there the commit is the undo, on the
   caller-side precondition stated under "Invocation" above: every
   entry was already committed on the branch before the run started, so
   there is no untracked, never-committed case for `git add <path>` to
   fail to preserve. This skill does not verify that precondition, and
   an autonomous-mode caller that breaks it loses those entries.
4. Delete the entry files for every scrub and every completed
   transfer.
5. Rewrite the entries you persisted that needed a present-tense
   restatement. Keep their frontmatter `name:` slug unchanged —
   changing it breaks every `[[wikilink]]` that points at the entry.

### Repair the indexes

Each agent directory's `MEMORY.md` is an index of pointer lines, one
per entry:

```text
- [Title](file.md) — one-line hook
```

In every directory you touched:

1. Remove the pointer line for each entry you deleted, scrubbed or
   transferred alike.
2. Add a pointer line for any entry that came out of a merge and did
   not have one.
3. Update the hook on any entry you restated.
4. Confirm the index and the directory agree in both directions — no
   pointer to a missing file, and no file without a pointer.

When a directory has no surviving entries, delete the whole directory
including its `MEMORY.md`. An index of nothing is noise.

### Repair dangling wikilinks

Entries link to each other with `[[name]]`, where `name` is another
entry's frontmatter `name:` slug. Deleting an entry breaks every link
aimed at it. For each entry you deleted, search the survivors:

```bash
grep -rn "\[\[<slug>\]\]" .claude/agent-memory/
```

Repair each hit:

- **Transferred** — the content still exists, so replace the link with
  a plain-prose reference to where it now lives (`CLAUDE.md`, or the
  doc file).
- **Merged** — the content survives under the merge target's slug, so
  repoint the link at that slug.
- **Scrubbed** — the content is gone entirely, so remove the link and
  reword the surrounding sentence to still read correctly.

Repair only the links this run broke. A `[[name]]` that never had a
target is a deliberate marker for an entry worth writing later, not a
defect to chase.

### Land the result

**Autonomous mode** (a PR number was passed) — stage by explicit path:
every memory path you deleted or edited, plus `CLAUDE.md` and each
`docs/*.md` you wrote a transfer into. Never `git add -A`, and never a
directory-wide add.

```bash
git add <each path you changed>
git diff --cached --name-only
```

If that output is empty — every verdict this run was persist, so
nothing was staged — there is nothing to commit. Report "no changes to
curate" and stop here; do not run `git commit`, and do not report a
commit SHA. The previous tip of the branch is not your commit, and
claiming it would misattribute someone else's work as this run's
output. This is a valid outcome, not a failure — distinct from the "no
agent memory to curate" case above (an absent or empty directory):
here entries existed and were graded, they just all happened to be
persist.

Use `git diff --cached --name-only` here, not `git status --porcelain`
— the latter also reports untracked or unstaged changes elsewhere in
the worktree, so an unrelated stray file would make its output
non-empty even when nothing was actually staged, falsely skipping this
no-op path and falling through to `git commit` with an empty index.
`git diff --cached --name-only` reports only what is staged, which is
the exact question this check is asking.

Otherwise, commit and push:

```bash
git commit -m "Curate agent memory"
git push
```

The commit message must never place a closing keyword (`close`,
`closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`,
`resolved`, case-insensitive) immediately before an issue reference
(`#N`, `owner/repo#N`, `GH-N`, or an issue URL) — that pattern
auto-closes the referenced issue.

A commit or push failure here is a genuine failure, not the no-op case
above — the gate below still applies in full: do not report success,
and do not report a SHA that was never verified on the remote.

After the push, verify it actually landed on the remote rather than
trusting `git push`'s exit code alone:

```bash
git fetch origin
git rev-parse HEAD
git rev-parse origin/<headRefName>
git status --porcelain
```

Report success only when **both** hold: the two SHAs match, **and**
`git status --porcelain` is empty. `git log --oneline -1` alone is
**not** sufficient evidence here — it reads clean for a commit that
was made locally but never reached the remote, since it never inspects
the remote-tracking ref, which is why the SHA comparison above is
required too. The SHA comparison alone is also not sufficient: if the
curation edits were applied to the working tree but the commit itself
never happened (e.g. a failed commit-signing prompt), HEAD still
equals `origin/<headRefName>` — the mismatch never occurs — while the
working tree sits dirty with uncurated edits. `git status --porcelain`
catches exactly that case. A caller that treats either check alone as
landed, then discards the branch, destroys the only copy of the
curation.

**Interactive mode** (no argument) — stage nothing new and commit
nothing. Leave in place whatever "Apply the verdicts" step 3 already
staged for formerly-untracked entries — that staging **is** their
undo; do not `git reset` it to make the tree match "nothing staged"
literally. Show `git diff --stat` and stop. The working tree (staged
plus unstaged) is the deliverable, and the human decides what to
commit.

## Output

Report one line per entry, grouped by verdict:

```text
## Agent memory curation

Scrubbed (N):
  - <agent>/<file> — <the check that substantiated it>

Transferred (N):
  - <agent>/<file> -> <destination> — <the constraint, one line>

Persisted (N):
  - <agent>/<file> — <why it has no code home>

Indexes fixed: <agent>/MEMORY.md, ...
Wikilinks repaired: <count>
```

Then the tail for the mode you ran in: in autonomous mode, either "no
changes to curate" when every verdict was persist and nothing was
staged, or the commit SHA once the post-push check above has confirmed
both that it matches `origin/<headRefName>` and that `git status
--porcelain` is empty — never report a SHA you have not verified
landed on the remote with a clean tree, and never report the no-op
line when a commit was in fact made; in interactive mode,
`git diff --stat` plus "review and commit when you're happy".

The per-entry lines are the record of a destructive operation. Report
all of them, including the entries you persisted only because you
could not substantiate a scrub — those are the ones a human most wants
to see.
