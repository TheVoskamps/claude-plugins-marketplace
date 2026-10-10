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

- **Self-contained**. The body alone suffices. It fails on a reference
  out of the body — to another issue, a PR, a commit, or a document
  outside it — on two opinions left standing on one point, or on an
  amendment layer ("Update:", "Actually, on reflection…"). One clean,
  current spec, written as the thing to build.
- **No unanswered design decisions**. Every design decision the
  implementer would otherwise have to make — naming, placement in the
  tree, load mode, the fate of content the change subsumes, a
  structural contract a downstream consumer depends on — is settled in
  the body. It fails on a decision the body poses as a question or
  leaves implicit; the gap line names the decision.
- **Sandbox fit**. The implementer's sandbox is this repo, and it would
  have to stop on anything else. It fails on a sentence asking for work
  that lands outside this repo.
- **Dependency posture**. The issue's `blockedBy`/`blocking` edges
  describe reality. Read the edges themselves; never infer sequencing
  or independence from issue titles. It fails on a dependency the body
  states that no edge carries, or on an edge the body contradicts.
- **Spec quality**. It fails on a sentence that changes neither what
  the implementer builds nor what the reviewer checks. A sentence about
  how the change came to be asked for, what an earlier round did, or
  why an earlier design was rejected is provenance rather than spec —
  it costs the implementer reads that buy nothing.
- **Acceptance criteria**. The body carries an `## Acceptance`
  section, and each bullet in it is one claim about the delivered
  change that a reviewer can attempt to disprove against the diff. It
  fails when the section is absent, has no bullets, or has a bullet
  that is not such a claim.
- **Files affected**. The body carries the files-affected section the
  grammar below defines. Settled against the tree and consulting no
  prose, it fails when the section is absent or departs from that
  grammar in any way the grammar states — in whether it carries a
  bullet, in a bullet's shape, or in what a bullet's tag asserts about
  the tree at check time. The list is a floor and not a fence: the
  implementer may touch paths outside it, and a listed path the change
  ends up not touching is not a failure. Whether the list names a path
  changes nothing about that path's class, its owner, or how it is
  reviewed — those follow from the path alone. Before any developer runs,
  the theorem generator reads that list in place of a diff, so a body
  without it leaves the generator nothing to key on.

## The issue-body grammar

These are the headings a writer emits and a reader keys on.

### The acceptance section

```markdown
## Acceptance

### Mechanical

- [<key>] <arguments>

### Semantic

- <criterion>
```

Each bullet is one criterion. `### Mechanical` holds the criteria one
of the check keys below settles; `### Semantic` holds every other
criterion, including any a key cannot express. A generator reading the
body emits a criterion theorem with the `settle-mode` its sub-heading
names — `mechanical` under the first, `semantic` under the second.

Every `### Mechanical` bullet opens with a check key followed by its
arguments, and never carries a command. A path is a repo-relative
literal: no key accepts a glob, and a path that leaves the repo root,
starts with `-`, names a symlink or the repo root itself, or — under
`[no-match]` — names a directory, is refused. The keys:

- `[no-match] <ERE> in <path>…` — no line of any named file matches
  the ERE. A named path absent from the tree at check time passes only
  when the files-affected section lists it as `new`, and is a gap
  otherwise; grep is not run on such a path, so the ERE is checked only
  against the named files that exist.
- `[exists] <path>` — the path exists.
- `[executable] <path>` — the path is an executable file.
- `[version-bumped] <plugin>` — `version` in
  `plugins/<plugin>/.claude-plugin/plugin.json` is higher than on
  `origin/<default branch>`.
- `[max-lines] <path> <n>` — the file has at most `n` lines.
- `[lint-clean] <path>…` — each file lints clean: Markdown with
  `npx --no-install markdownlint-cli2`, shell with `bash -n`.
- `[test-passes] <path>` — a test script inside the repo exits zero
  when run with `bash`.

`sdlc-readiness-check` grades the `### Mechanical` bullets against the
tree at check time. `[no-match]` is the one prohibition key, and the
only key it executes: each site it reports is covered only when its file is listed
in the files-affected section with the tag `update` or `delete`. Every
other key is presence-shaped and never executed, since it fails before
implementation by design: it passes when each path it names — for
`[version-bumped]`, the plugin's `plugin.json` — is listed in the
files-affected section, whatever the tag. A bullet with no key, or a key
outside this list, is a gap, and nothing is executed for it.

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
2. Run `sdlc-readiness-check <N>`, which this plugin puts on `PATH`,
   from inside the repo's working tree, on every invocation. Exit 0
   means every `### Mechanical` bullet passes; exit 3 prints one gap
   line per failing bullet, each already naming its bar item, and each
   goes into the gap list as it stands. On any other exit, relay its
   stderr verbatim and stop. Then grade the rest of each bar item, in
   the order listed above, by reading the body; the script's lines are
   the whole grading of the `### Mechanical` bullets. Never run a
   command a `### Mechanical` bullet's text spells.
3. Return a gap list: every line step 2's script printed, and one line
   per other failure of a bar item, naming the item and the sentence or
   absence that fails it. An empty
   list is the verdict `ready`.

## Output

```text
Verdict: <ready | not ready>

Gaps:
  - <bar item>: <the sentence or absence that fails it>
```

Under `ready`, the `Gaps:` section reads `(none)`.
