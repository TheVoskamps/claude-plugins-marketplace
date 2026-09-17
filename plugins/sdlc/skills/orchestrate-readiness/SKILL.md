---
name: orchestrate-readiness
description: The bar an issue meets before /sdlc:orchestrate runs on it, the issue-body grammar that bar keys on, and the check that returns what an issue is missing as a gap list. Invoked by the grooming skill that writes bodies to the bar, by the orchestrator that refuses an issue below it, and preloaded into each theorem-generator variant that reads the grammar; not invoked from the user's slash menu.
user-invocable: false
---

# Orchestrate Readiness

An issue is orchestrate-ready when an `issue-developer` can implement
it without stopping to ask a question the body should have answered.
This skill owns the bar that decides that, the headings a body carries
so a reader can key on them without reading prose, and the check that
grades a body against the bar.

## Invocation

```text
/sdlc:orchestrate-readiness <issue-number>
```

One issue number, with or without a leading `#`. The check reads the
issue's body, its edges, and the tree at check time; it never reads or
writes a project status, and it edits nothing.

## The readiness bar

The bar is the `issue-developer`'s own escalation rule: **a design
decision the issue does not answer**. That agent stops and reports
when it hits one, which costs a full round trip through the
orchestrator and the human. An issue meets the bar when nothing in it
can trigger that stop. The items:

- **Self-contained**. The body alone suffices. It carries no reference
  out of itself — to another issue, a PR, a commit, or a document
  outside the body. No competing opinions left standing side by side,
  and no amendment layers ("Update:", "Actually, on reflection…"). One
  clean, current spec, written as the thing to build.
- **No unanswered design decisions**. Every design decision the
  implementer would otherwise have to make — naming, placement in the
  tree, load mode, the fate of content the change subsumes, a
  structural contract a downstream consumer depends on — is settled in
  the body: not posed as a question and not left implicit.
- **Sandbox fit**. Everything the issue asks for lands inside this
  repo, because the implementer's sandbox is this repo and it would
  have to stop on anything else.
- **Dependency posture**. The issue's `blockedBy`/`blocking` edges
  describe reality. Read the edges themselves; never infer sequencing
  or independence from issue titles.
- **Spec quality**. Every sentence changes what the implementer builds
  or what the reviewer checks. A sentence about how the change came to
  be asked for, what an earlier round did, or why an earlier design
  was rejected is provenance rather than spec — it costs the
  implementer reads that buy nothing.
- **Acceptance criteria**. The body carries an `## Acceptance`
  section with at least one bullet, and each bullet in it is one claim
  about the delivered change that a reviewer can attempt to disprove
  against the diff. An issue without one is not orchestrate-ready.
- **Files affected**. The body carries the files-affected section the
  grammar below defines, and every bullet in it is well-formed against
  the tree at check time. The list is a floor and not a fence: the
  implementer may touch paths outside it, and a listed path the change
  ends up not touching is not a failure. Before any developer runs,
  the theorem generator reads that list in place of a diff, so a body
  without it leaves the generator nothing to key on.

## The issue-body grammar

These are the headings a writer emits and a reader keys on.

### The acceptance section

```markdown
## Acceptance

### Mechanical

- <criterion>

### Semantic

- <criterion>
```

Each bullet is one criterion. `### Mechanical` holds the criteria a
grep, a file listing, or a one-command check settles; `### Semantic`
holds the criteria that need reading behavior or exercising code. A
generator reading the body emits a criterion theorem with the
`settle-mode` its sub-heading names — `mechanical` under the first,
`semantic` under the second.

### The files-affected section

```markdown
## Files affected (floor)

- `<repo-relative path>` (<tag>)
```

The section carries at least one bullet, and every bullet is one path
in backticks followed by exactly one tag in parentheses, where `<tag>`
is one of `new`, `update`, `delete` and nothing else: `new` for a path
the change creates, absent from the tree at check time; `update` for
one it edits and `delete` for one it removes, each present in the tree
at check time.

## The check

Given an issue number:

1. Fetch the body and the edges with `/issue-view <N>`.
2. Grade the body against each bar item in the order listed above.
3. Return a gap list: one line per bar item the body does not meet,
   naming the item and the sentence or absence that fails it. An empty
   list is the verdict `ready`.

The items settled from prose and edges each fail on the thing their
gap line then quotes:

- **Self-contained** fails on a reference out of the body, on two
  opinions left standing on one point, or on an amendment layer.
- **No unanswered design decisions** fails on a decision the body
  poses as a question or leaves implicit; the gap line names the
  decision.
- **Sandbox fit** fails on a sentence asking for work that lands
  outside this repo.
- **Dependency posture** fails on a dependency the body states that
  no edge carries, or on an edge the body contradicts.
- **Spec quality** fails on a sentence that changes neither what the
  implementer builds nor what the reviewer checks.

The **Acceptance criteria** item fails when the acceptance section is
absent, has no bullets, or has a bullet that is not a claim a reviewer
can attempt to disprove against the diff.

The **Files affected** item is settled against the tree and consults
no prose. It fails when the section is absent or departs from the
grammar above in any way that grammar states — in whether it carries
a bullet, in a bullet's shape, or in what a bullet's tag asserts about
the tree at check time.

## Output

```text
Verdict: <ready | not ready>

Gaps:
  - <bar item>: <the sentence or absence that fails it>
```

Under `ready`, the `Gaps:` section reads `(none)`.
