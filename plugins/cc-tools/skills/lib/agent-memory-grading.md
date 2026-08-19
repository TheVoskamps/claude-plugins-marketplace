# Agent memory grading rubric (`skills/lib/agent-memory-grading.md`)

This file is the single source of truth for **how a memory entry is
graded**: what makes an entry durable, what evidence a delete has to
produce, how a transfer is phrased, and which file it lands in. It is
reference prose, not an executable script.

`/cc-tools:agent-memory-cleanup` and
`/cc-tools:agent-memory-inbox-cleanup` both read this contract, and
neither restates the rubric. What the two skills do **not** share is
their verdict set — only `agent-memory-cleanup` has a verdict that
keeps an entry where it is, because only it curates a tree something
reads back. Each skill states its own verdict set; this file states
what is common to both.

## Read before you grade

You cannot grade an entry without reading what it claims about. An
entry saying "the X helper skips Y" is a delete when the source visibly
skips Y, and durable when the source says nothing either way — and
opening the file is the only way to tell those apart.

So read, in full:

- every entry you are grading
- the root `CLAUDE.md`, plus any nested `CLAUDE.md`
- `.claude/rules/*.md`
- `docs/*.md`
- the code each entry makes a claim about

## The delete cases

An entry is deleted when it:

- **Restates something already implemented and self-documented in the
  code.** If the code says it, the doc doesn't — and a memory is a doc.
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
  more complete entry first, then delete the duplicate.

## A delete needs evidence

A delete verdict is a claim, and each case above is checkable. Before
deleting, produce the check:

| Delete case | The check that substantiates it |
| --- | --- |
| the code already says it | the file and lines that say it |
| names an external source of truth | the pointer, quoted from the entry |
| narrates finished work | the past-tense narration, quoted |
| already in `CLAUDE.md` or a rule | the file and lines that say it |
| duplicate | the entry it duplicates |

If you cannot produce the check, the verdict is not delete. Fall back
to whichever non-destructive verdict the calling skill offers, and say
so in the report. "It feels stale" is not evidence, and curation is
destructive.

## What counts as durable

An entry is durable lore when it is a "don't undo this deliberate
choice" constraint that the code **cannot** express — a deliberate
omission, an absent API, a non-obvious read path, a harness behavior
that surprises, a tool that misbehaves in a way no source file in the
repo records.

Durable is the narrow case, not the default. If the code already makes
the point clear to a reader, the verdict is delete.

## Where a transfer lands

- **`CLAUDE.md`** when the constraint governs how anyone works in the
  repo.
- **The closest-fitting `docs/*.md`** when it is subsystem lore.

Add to the section that already covers the surrounding subject rather
than opening a new one, and correct a statement already there when the
entry contradicts it — a transfer may repair prose as well as extend
it.

## How a transfer is phrased

Write the constraint as a **present-tense constraint**, not as the
story of how it was found:

- no SHAs, no issue numbers, no PR numbers
- no provenance — not "we learned that…", not "as of…"
- no external-source framing — not "per the X design doc"
- present tense, stated as the rule it is

Write the transfer into its destination **before** deleting the entry.
A transfer that deletes the entry before the constraint lands somewhere
is a data loss.
