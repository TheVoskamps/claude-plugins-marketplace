---
name: agent-memory-cleanup
description: "Curate a repo's local .claude/agent-memory/ in one acting pass. Grades every entry persist / scrub / transfer, deletes what the code or CLAUDE.md already says, moves durable lore into CLAUDE.md or docs as present-tense constraints, and repairs the MEMORY.md indexes and wikilinks. Takes no arguments — the memory tree is gitignored and local to the clone that wrote it, so curation stays in the working tree and the whole tree is copied to a backup first so every deletion is recoverable."
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

## Invocation

```text
/cc-tools:agent-memory-cleanup
```

No arguments. The skill curates `.claude/agent-memory/` in the current
checkout and leaves its edits in the working tree for you to review.
Transfers are confirmed with you one at a time; deletions are not
confirmed, and the backup described below is their undo.

### The tree is local, so nothing here touches git history

`.claude/agent-memory/` is gitignored and never committed. The tree
belongs to the clone — or the throwaway worktree — that wrote it, so
there is no branch carrying it, nothing to commit, and no PR for a
curation to land on. This skill therefore never checks out a branch,
never stages, never commits, and never pushes.

Git offers no undo for the tree either, which is why the backup below
is not optional. Against an ignored path:

- `git add <path>` exits 1 with "The following paths are ignored by one
  of your .gitignore files", for a file and for the directory alike, so
  staging cannot preserve an entry's content.
- `git status --porcelain -- <path>` prints **nothing**, even for a file
  that exists and has never been committed — only `--ignored` reports
  it, as `!!`. So a `??`-detection branch never fires here, and a
  safeguard conditional on one is silently skipped.
- `git checkout -- <path>` fails with "did not match any file(s) known
  to git", because the file is in no index and no commit.

Deleting an entry is therefore permanent unless a copy of it exists
outside git. Making that copy is a step of this skill, not a caller's
responsibility.

### If an argument is passed

Curate nothing. Report:

```text
This skill takes no arguments. Agent memory is local to the clone that
wrote it and is never committed, so there is no PR branch to curate and
nothing to push. Re-run with no argument to curate this checkout's tree.
```

and stop. That abort is deliberate: the `sdlc` plugin's
`agent-memory-scrubber` still passes a PR number, from when the tree was
committed, and a caller that expects a commit pushed onto a PR branch
must not be handed a curation it cannot land.

Do not read the abort as something the scrubber will notice. Its own
verification gate is a git-state check — `HEAD` against
`origin/<branch-name>`, plus an empty `git status --porcelain` — and an
abort satisfies both trivially: no commit was made, so `HEAD` still
equals the ref the scrubber checked the branch out from, and nothing
was written, so the tree is clean. The gate's own no-op carve-out does
not even name this shape; it names "no agent memory to curate" and "no
changes to curate", of which this skill still reports only the first.
So the abort reads to the scrubber as an ordinary success rather than
as a recognized no-op. Making the abort visible to that
caller is the `sdlc` side's job, not this skill's; it goes away with
the scrubber itself.

## Execution

### Resolve the scope

Work on the current checkout as it stands. Do not switch branches, do
not fetch, and do not stash.

The target is `.claude/agent-memory/` at the repo root. If it is absent
or empty, report "no agent memory to curate" and stop — that is a valid
outcome, not a failure.

### Back up the tree before anything else

Copy the whole tree, before reading a single entry and long before
deleting one:

```bash
BACKUP=".claude/tmp/agent-memory-cleanup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp -R .claude/agent-memory/. "$BACKUP"/
find .claude/agent-memory -type f | wc -l
find "$BACKUP" -type f | wc -l
```

The two counts must be equal and non-zero. If they differ, or the copy
failed, **stop** — report the failure and curate nothing. An
unrecoverable curation is worse than an uncurated tree.

The undo for any deletion this run makes is then:

```bash
cp -R "$BACKUP"/. .claude/agent-memory/
```

`.claude/tmp/` is the conventional scratch surface and repos ignore it,
which is what keeps the backup out of a commit. Confirm it in this repo
rather than assuming:

```bash
git check-ignore -q "$BACKUP" || echo "NOT ignored: $BACKUP"
```

If that prints the warning, say so in the report so nobody commits the
backup by accident. Either way the backup path goes in the report — see
"Output".

### Read the entries, and the surfaces that grade them

1. Enumerate every memory file:

   ```bash
   find .claude/agent-memory -type f -name '*.md'
   ```

   The layout is one directory per agent
   (`.claude/agent-memory/<agent-name>/`), each holding an index
   (`MEMORY.md`) plus one file per entry.

2. Read every entry file and every `MEMORY.md` in full.

3. Read the surfaces the verdicts are decided against:
   - the root `CLAUDE.md`, plus any nested `CLAUDE.md`
   - `.claude/rules/*.md`
   - `docs/*.md`
   - the code each entry makes a claim about

You cannot grade an entry without reading what it claims about. An
entry saying "the X helper skips Y" is a scrub when the source visibly
skips Y, and a keep when the source says nothing either way — and
opening the file is the only way to tell those apart.

### Grade each entry

Every entry gets exactly one verdict.

#### Scrub — delete the entry

Scrub when the entry:

- **Restates something already implemented and self-documented in the
  code.** If the code says it, the doc doesn't — and a memory is a
  doc.
- **Names a design doc, a decomposition doc, or another repo or plugin
  as the "source of truth."** That pointer sends the next agent away
  from the code that actually governs, toward a document that has
  already drifted.
- **Narrates finished work.** "Slice 3 added the retry loop" is a
  changelog, and `git log` already holds it. A memory earns its place
  by binding future behavior, not by recording past behavior.
- **Restates content already in `CLAUDE.md`,** in `.claude/rules/`, or
  in a skill or agent definition.
- **Duplicates another entry.** Merge the surviving content into the
  more complete entry first, then scrub the duplicate.

#### Transfer — move the content out, then delete the entry

Transfer when the entry is genuine durable lore: a "don't undo this
deliberate choice" constraint that the code **cannot** express — a
deliberate omission, an absent API, a non-obvious read path. Write it
into `CLAUDE.md` when it constrains how anyone works in the repo, or
into the closest-fitting `docs/*.md` when it is subsystem lore. Write
it as a **present-tense constraint**:

- no SHAs, no issue numbers, no PR numbers
- no provenance — not "we learned that…", not "as of…"
- no external-source framing — not "per the X design doc"
- present tense, stated as the rule it is rather than the story of how
  it was found

Then delete the memory entry. Transfer is the narrow case, not the
default: if the code already makes the point clear to a reader, the
verdict is scrub.

#### Persist — keep the entry

Persist when the entry is a genuine preference, workflow correction,
or tooling gotcha with **no code home** — a CLI that behaves
unexpectedly, a skill doc that omits a step, a harness constraint.
Nothing in the repo can carry it, so the memory is where it belongs.
Restate it present-tense if it is written as the story of when it was
discovered.

### A scrub needs evidence

A scrub verdict is a claim, and each scrub case above is checkable.
Before deleting, produce the check:

| Scrub case | The check that substantiates it |
| --- | --- |
| the code already says it | the file and lines that say it |
| names an external source of truth | the pointer, quoted from the entry |
| narrates finished work | the past-tense narration, quoted |
| already in `CLAUDE.md` or a rule | the file and lines that say it |
| duplicate | the entry it duplicates |

If you cannot produce the check, the verdict is not scrub — persist
the entry and say so in the report. "It feels stale" is not evidence,
and curation is destructive.

### Apply the verdicts

Work one agent directory at a time so an index and its entries stay
consistent:

1. Write every transfer into its destination file first. A transfer
   that deletes the memory before the constraint lands somewhere is a
   data loss.
2. Confirm each transfer with the human before writing it: show the
   destination file and the exact text you would add.
3. Before deleting anything, confirm the backup from "Back up the tree
   before anything else" is in place and holds the entries you are
   about to remove:

   ```bash
   ls "$BACKUP/<agent>/<entry-file>"
   ```

   That copy is the undo, for every entry alike. Do not reach for a git
   safeguard instead — `git add` refuses an ignored path, and the
   `git status --porcelain` check that would tell you an entry is
   untracked prints nothing for one, so a git-based safeguard here does
   not fail loudly, it silently does not run.
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

Stage nothing, commit nothing, push nothing. The curated tree in the
working directory **is** the deliverable, and the backup is what makes
it reversible.

The memory tree itself cannot be shown with a plain `git diff`: it is
ignored, so git reports no change in it at all. Show the two halves
separately.

```bash
diff -rq "$BACKUP" .claude/agent-memory
git diff --stat
```

The `diff -rq` is the record of what happened inside the memory tree —
files only in `$BACKUP` are the entries this run deleted. The
`git diff --stat` covers the transfer destinations (`CLAUDE.md`, the
`docs/*.md` files), which are tracked and do show up.

Transfers are the one part of a run that lands in tracked files, so
they are the part the human may want to commit. Say so, name those
files, and leave the decision to them.

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
Backup: <$BACKUP>
```

Then the tail: `diff -rq "$BACKUP" .claude/agent-memory` for what left
the memory tree, `git diff --stat` for the transfer destinations, the
backup path with the one-line restore command, and "review, commit the
transfers if you want them, and delete the backup when you're happy".
Report the backup path even when nothing was deleted — a run whose
verdicts were all persist still leaves one, and a reader should not
have to work out whether there is anything to clean up.

The per-entry lines are the record of a destructive operation. Report
all of them, including the entries you persisted only because you
could not substantiate a scrub — those are the ones a human most wants
to see.
