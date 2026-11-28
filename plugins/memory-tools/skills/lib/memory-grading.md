# Memory grading rubric

How a memory is graded: what makes it a delete and the evidence that
grade needs, what makes it durable, what separates that from a memory
with no code home, where a surviving memory would land, and how its
constraint would be phrased there. A grade is reported, never applied.

## Read before you grade

You cannot grade a memory without reading what it claims about. A
memory saying "the X helper skips Y" is a delete when the source
visibly skips Y, and durable when the source says nothing either way —
and opening the file is the only way to tell those apart.

So read, in full:

- every memory you are grading
- the root `CLAUDE.md`, plus any nested `CLAUDE.md`
- `.claude/rules/*.md`
- `docs/rules/*.md`
- the code each memory makes a claim about

## The delete cases

A memory is graded **delete** when it:

- **Restates something already implemented and self-documented in the
  code.** If the code says it, the doc doesn't — and a memory is a doc.
- **Names a design doc, a decomposition doc, or another repo or plugin
  as the "source of truth."** That pointer sends the next agent away
  from the code that actually governs, toward a document that has
  already drifted.
- **Narrates finished work.** "Slice 3 added the retry loop" is a
  changelog, and `git log` already holds it. A memory earns its place
  by binding future behavior, not by recording past behavior.
- **Restates content already in a destination** — a `CLAUDE.md` or a
  `docs/rules/*.md` — or in `.claude/rules/`, or in a skill or agent
  definition.
- **Duplicates another memory.** Name the more complete one.

## A delete needs evidence

A delete grade is a claim, and each case above is checkable. Produce
the check with the grade:

| Delete case | The check that substantiates it |
| --- | --- |
| the code already says it | the file and lines that say it |
| names an external source of truth | the pointer, quoted from the memory |
| narrates finished work | the past-tense narration, quoted |
| already in a `CLAUDE.md`, a `docs/rules/*.md`, a rule, or a skill or agent definition | the file and lines that say it |
| duplicate | the memory it duplicates |

When you cannot produce the check, the grade is not delete: grade the
memory by "What counts as durable" and "Memories with no code home"
instead, and say in the report that the delete could not be
substantiated. "It feels stale" is not evidence.

## What counts as durable

A memory is **durable** when it is a "don't undo this deliberate
choice" constraint that the code **cannot** express — a deliberate
omission, an absent API, a non-obvious read path.

Durable is the narrow case, not the default. If the code already makes
the point clear to a reader, the grade is delete.

## Memories with no code home

A second surviving grade sits beside durable: a genuine preference,
workflow correction, or tooling gotcha with **no code home** — a CLI
that behaves unexpectedly, a skill doc that omits a step, a harness
constraint. Nothing in the repo's code can carry it.

The two grades are disjoint, so no memory matches both. A durable
memory is a claim **about the repo's own code** — what it deliberately
does or does not do — that the code cannot state about itself. A
no-code-home memory is a claim about something outside the repo's
code: a tool, the harness, or the way the work is done. Grade by what
the memory is about, and exactly one of the two fits.

A memory that clears neither bar, and whose delete cannot be
substantiated, is graded by whichever of the two it comes nearest, and
the report says it cleared neither.

## Where a surviving memory would land

A durable or no-code-home memory carries the destination it would land
in. Narrowest first; take the first one that fits:

1. **The nearest governing `CLAUDE.md`** — the nearest `CLAUDE.md`
   above the code the constraint is about, however deep that sits; a
   subtree carrying its own `CLAUDE.md` owns the constraints about that
   subtree. When the constraint governs one part of the repo and that
   tree has no `CLAUDE.md` of its own, the destination is a new one at
   the tree's root. A constraint fits here when it applies on every
   turn spent in that tree.
2. **An on-demand `docs/rules/*.md`** when the constraint does not fit
   there — it applies only when a trigger comes up, or it spans trees.
   Name the closest-fitting file, or a new one, and say when the
   governing `CLAUDE.md` would need a routing entry for it.
3. **The root `CLAUDE.md`**, failing both.

A destination is never a README.

Name the section that already covers the surrounding subject, and name
a statement already there that the memory contradicts.

## How the constraint is phrased

The constraint as it would be written in its destination is a
**present-tense constraint**, not the story of how it was found:

- no SHAs, no issue numbers, no PR numbers
- no provenance — not "we learned that…", not "as of…"
- no external-source framing — not "per the X design doc"
- present tense, stated as the rule it is

The destination is markdown whose reader is a model, so
`docs/rules/claude-code-markdown-instructions-style.md` in the directory
`claude-home` prints governs the phrasing — it is on-demand, nothing
expands it for you, and this is the trigger to go and read it.
