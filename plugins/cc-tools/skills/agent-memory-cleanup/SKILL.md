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
| PR number | autonomous | applied without asking | committed and pushed onto the PR branch |
| none | interactive | confirmed with you one at a time | left uncommitted in the working tree |

Deletions are not confirmed in either mode. In interactive mode the
uncommitted working tree is the undo; in autonomous mode the commit
is.

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
2. In interactive mode, confirm each transfer with the human before
   writing it: show the destination file and the exact text you would
   add. In autonomous mode, write it.
3. Delete the entry files for every scrub and every completed
   transfer.
4. Rewrite the entries you persisted that needed a present-tense
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
- **Scrubbed** — the content is gone, so remove the link and reword
  the surrounding sentence to still read correctly.

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
git commit -m "Curate agent memory"
git push
```

The commit message must never place a closing keyword (`close`,
`closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`,
`resolved`, case-insensitive) immediately before an issue reference
(`#N`, `owner/repo#N`, `GH-N`, or an issue URL) — that pattern
auto-closes the referenced issue.

**Interactive mode** (no argument) — stage nothing and commit nothing.
Show `git diff --stat` and stop. The working tree is the deliverable,
and the human decides what to commit.

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

Then the tail for the mode you ran in: the pushed commit SHA in
autonomous mode, or `git diff --stat` plus "review and commit when
you're happy" in interactive mode.

The per-entry lines are the record of a destructive operation. Report
all of them, including the entries you persisted only because you
could not substantiate a scrub — those are the ones a human most wants
to see.
