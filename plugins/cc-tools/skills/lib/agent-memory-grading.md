# Agent memory grading rubric (`skills/lib/agent-memory-grading.md`)

This file is the single source of truth for **how a memory entry is
graded**: what makes an entry durable, what separates that from an
entry with no code home, what evidence a delete has to produce, how a
transfer is phrased, which file it lands in, and the standard that file
is held to afterwards. It is reference prose, not an executable script.

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
- `plugins/**/README.md`
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
- **Restates content already in a transfer destination** — `CLAUDE.md`,
  a `docs/*.md`, or a `plugins/**/README.md` — or in `.claude/rules/`,
  or in a skill or agent definition.
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
| already in `CLAUDE.md`, a `docs/*.md`, a plugin README, a rule, or a skill or agent definition | the file and lines that say it |
| duplicate | the entry it duplicates |

If you cannot produce the check, the verdict is not delete. Fall back
to the calling skill's **keep-in-place** verdict — the one that leaves
the entry where it is — and say so in the report. "It feels stale" is
not evidence, and curation is destructive.

A calling skill with no keep-in-place verdict has no fallback to take,
and must not borrow a different one: every verdict it offers either
destroys the entry or writes its content somewhere else, so a fallback
would answer "I could not substantiate a delete" by publishing the
entry. Such a skill decides the entry's fate on "What counts as
durable" and the class beside it instead — the entry survives only when
it clears one of those bars — and states that in its own verdict set.

## What counts as durable

An entry is durable lore when it is a "don't undo this deliberate
choice" constraint that the code **cannot** express — a deliberate
omission, an absent API, a non-obvious read path.

Durable is the narrow case, not the default. If the code already makes
the point clear to a reader, the verdict is delete.

## Entries with no code home

A second surviving class sits beside durable lore: a genuine
preference, workflow correction, or tooling gotcha with **no code
home** — a CLI that behaves unexpectedly, a skill doc that omits a
step, a harness constraint. Nothing in the repo's code can carry it.

The two classes are disjoint, so no entry matches both. Durable lore is
a claim **about the repo's own code** — what it deliberately does or
does not do — that the code cannot state about itself. A no-code-home
entry is a claim about something outside the repo's code: a tool, the
harness, or the way the work is done. Grade by what the entry is about,
and exactly one of the two fits.

What happens to a no-code-home entry depends on whether the calling
skill has a verdict that keeps an entry where it is, so each skill
states that outcome itself.

## Where a transfer lands

Narrowest first. Take the first one that fits:

- **The closest-fitting `plugins/**/README.md`** when the constraint
  governs one plugin. "Closest-fitting" ranges over every README in
  that plugin's tree, not only `plugins/<name>/README.md` — a
  constraint governing a subtree that carries its own README belongs
  in that deeper file. A plugin with no README anywhere in its tree
  still has this destination: create `plugins/<name>/README.md` and
  land the constraint in it. Write that new file as a user manual for
  someone deciding whether to install the plugin — what it does, why
  they would want it, what it needs, how to start, and what it
  deliberately does not do — never a per-skill catalogue, and mirror
  the shape of a README another plugin in the repo already ships.
- **The closest-fitting `docs/*.md`** when it is cross-plugin
  subsystem lore.
- **`CLAUDE.md`** when the constraint governs how anyone works
  anywhere in the repo.

A transfer into a plugin README writes a file under `plugins/<name>/`,
whether it edits a README already there or creates one, and some repos
require such a change to carry a `version` bump in
`plugins/<name>/.claude-plugin/plugin.json`. That obligation is the
host repo's, never this rubric's: bump when the repo's own rules say a
plugin change must, and bump nothing where they say nothing — a repo
with no such convention, or no `plugin.json` to bump, is left alone. A
calling skill that commits its transfers stages any bump it did make
alongside the README it wrote or created; one that leaves its edits for
a human to commit leaves the bump in the working tree with them.

Add to the section that already covers the surrounding subject rather
than opening a new one, and correct a statement already there when the
entry contradicts it — a transfer may repair prose as well as extend
it.

## A transfer is a doc edit, and holds the whole file to standard

The destination is markdown whose reader is a model, so
`~/.claude/docs/rules/claude-code-markdown-instructions-style.md`
governs the edit — it is on-demand, nothing expands it for you, and
this is the trigger to go and read it. Apply what it says to the
sections already in the destination as well as to the prose you are
adding, and delete what fails. Everything the guide argues for is left
there rather than repeated here.

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
