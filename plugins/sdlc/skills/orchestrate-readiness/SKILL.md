---
name: orchestrate-readiness
description: The bar an issue meets before /sdlc:orchestrate runs on it, the issue-body grammar that bar keys on, the terms for a repo statement an issue contradicts, and the check that returns what an issue is missing as a gap list. Not invoked from the user's slash menu.
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
- **Outcome, not method**. It fails on a sentence that specifies an
  implementation step the implementer can derive from the tree or from
  running a tool, rather than the delivered behavior, a constraint, or
  a decision. Its failures include a fix prescribed per finding of a
  tool's report — a linter, a type checker, a test run, a scanner; a
  file-and-line location given as where to make a change; and a
  diagnosis taken from a tool's report and stated as fact. The item
  admits what the implementer cannot derive: the content of a config
  file, a name, a placement in the tree, a policy such as which findings
  may be excluded and where, an interface a downstream consumer depends
  on, and the observable outcome — for tool output, that the tool
  reports clean. The gap line names the sentence and says to restate it
  as the outcome it was meant to produce.
- **No contradicted repo statement**. It fails a body that specifies
  something an instruction file in the repo forbids and does not say
  what happens to that statement. The body passes when, for each
  statement it contradicts, it says one of: the statement is deleted,
  the statement is replaced with given text, or the statement gains a
  named exception with the reason; the statement's file is then in the
  files-affected section, and a criterion covers the edit. The gap line
  quotes the statement and names its file. The terms are defined under
  "Contradicted repo statements" below.
- **Acceptance criteria**. The body carries the acceptance sections
  the grammar below defines, and each bullet in either is one claim
  about the delivered change that a reviewer can attempt to disprove
  against the diff. Your own reading of the body
  settles which file class a bullet's subject is in. It fails:
  - when neither `## Code and instruction Markdown acceptance` nor
    `## Documentation acceptance` is present;
  - when a section is present with no bullet under `### Mechanical` or
    `### Semantic`;
  - when a section's `### Mechanical` lines depart from that grammar in
    any way the grammar states — in a line's shape, in a bullet's check
    key, in a bullet carrying a command, or in a path a bullet names;
  - when the body carries an `## Acceptance` section; the gap line says
    to split it into `## Code and instruction Markdown acceptance` and
    `## Documentation acceptance`;
  - on a bullet whose subject spans both sections' classes; the gap
    line names the bullet and says to split it into one bullet per
    class;
  - on a bullet whose subject's class does not match its section; the
    gap line names the bullet and the section it belongs in;
  - on a bullet that is not such a claim.
- **Files affected**. The body carries the files-affected section the
  grammar below defines. Settled against the tree and consulting no
  prose, it fails when the section is absent or departs from that
  grammar in any way the grammar states — in whether it carries a
  bullet, in a bullet's shape, or in what a bullet's tag asserts about
  the tree at check time. The list is a floor and not a fence: the
  implementer may touch paths outside it, and a listed path the change
  ends up not touching is not a failure. Whether the list names a path
  changes nothing about that path's class, its owner, or how it is
  reviewed — those follow from the path alone.

## Contradicted repo statements

An **instruction file** is a file a session auto-loads as instructions,
or one another instruction file directs the model to read: every
`CLAUDE.md`, every file under `docs/rules/`, every `SKILL.md`, every
agent file, and the `README.md` at the root of each plugin the body
touches. Documentation — changelogs, ADRs, and any other README — is
not an instruction file and is not searched.

A statement in an instruction file that an issue contradicts is one of:

- A **capability claim** — what the harness or a tool can or cannot do.
  It can be tested.
- A **policy claim** — a choice the repo made where the harness permits
  both.

Prescriptive wording such as "never" or "may only" does not decide the
kind. A statement is a capability claim only when a test of it was
run; every other contradicted statement is a policy claim.

A **test** is a command whose output settles the claim, and its output
is quoted verbatim wherever the test is reported. A test that needs an
action a rule forbids, or one a rule gates behind the human's approval,
is not run, and the statement is then a policy claim.

## The issue-body grammar

These are the headings a writer emits and a reader keys on.

### The acceptance sections

```markdown
## Code and instruction Markdown acceptance

### Mechanical

- [<key>] <arguments>

### Semantic

- <criterion>

## Documentation acceptance

### Mechanical

- [<key>] <arguments>

### Semantic

- <criterion>
```

A bullet is a line opening with a hyphen and a space followed by text;
a hyphen and a space with nothing after them is not one. Each bullet is
one criterion whose subject is in the class its section names.
`## Code and instruction Markdown acceptance` holds the criteria about
code and instruction Markdown, and `## Documentation acceptance` holds
the criteria about documentation. A documentation-only change carries
the second alone; which sections a body must carry, and with what, is
the "Acceptance criteria" bar item's.

Within either section, `### Mechanical` holds the criteria one of the
check keys below settles; `### Semantic` holds every other criterion,
including any a key cannot express.

Every non-blank line under `### Mechanical` is a bullet, or an indented
line continuing the bullet above it with no blank line between; any
other line, a fenced block's opening included, is a gap. Every
`### Mechanical` bullet opens with a check key followed by its
arguments, and never carries a command. A path is a repo-relative
literal with no whitespace and no glob. A path the script cannot check
as one location inside the repo root — under `[no-match]`, as one file
to read — is refused, and the bullet's gap line says why. The keys:

- `[no-match] <ERE> in <path>…` — no line of any named file matches
  the ERE. A named path absent from the tree at check time passes only
  when the files-affected section lists it as `new`, and is a gap
  otherwise; grep is not run on such a path, so the ERE is checked only
  against the named files that exist.
- `[exists] <path>` — the path exists.
- `[executable] <path>` — the path is an executable file.
- `[version-bumped] <plugin>` — `version` in
  `plugins/<plugin>/.claude-plugin/plugin.json` is higher than on
  `origin/<default branch>`, where `<plugin>` is the plugin's directory
  name under `plugins/`.
- `[max-lines] <path> <n>` — the file has at most `n` lines.
- `[lint-clean] <path>…` — each file lints clean: Markdown with the
  `markdownlint-cli2` binary on `PATH`, run from the worktree root,
  shell with `bash -n`.
- `[test-passes] <path>` — a test script inside the repo exits zero
  when run with `bash`.

`sdlc-readiness-check` grades the `### Mechanical` bullets of both
acceptance sections against the tree at check time, by the same keys
and rules in each. `[no-match]` is the one prohibition key, and the
only key it executes: each site it reports is covered only when its file is listed
in the files-affected section with the tag `update` or `delete`. Every
other key is presence-shaped and never executed, since it fails before
implementation by design: it passes when each path it names — for
`[version-bumped]`, the plugin's `plugin.json` — is listed in the
files-affected section, whatever the tag. A bullet with no key, a key
outside this list, or a line under `### Mechanical` that is not a
bullet is a gap, and nothing is executed for it.

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
   means it found no gap; exit 3 prints one gap line per gap, each
   already naming its bar item, and each goes into the gap list as it
   stands. On any other exit, relay its stderr verbatim and stop. Then
   grade the rest of each bar item but "No contradicted repo
   statement", in the order listed above, by reading the body; the
   script's lines are the whole grading of each
   `### Mechanical` line's shape and check key, of whether each
   acceptance section is present and carries a bullet under
   `### Mechanical` or `### Semantic`, of an `## Acceptance` section,
   and of a files-affected list under another heading, and the
   file-class failures under "Acceptance criteria" are yours to grade
   for `### Mechanical` and `### Semantic` bullets alike. Never run a
   command a `### Mechanical` bullet's text spells.
3. Grade "No contradicted repo statement" by searching the instruction
   files for statements about what the body's design changes, on every
   invocation. At minimum, grep them for every path in the body's
   files-affected section and every identifier the design names —
   skill, agent, script and section names — and read the root
   `CLAUDE.md` and the `README.md` of each plugin the body touches in
   full. The search is a floor, not a proof that no conflict exists.
   Each statement the body contradicts and does not settle is a gap.
   For one that reads as a capability claim, run a test of it; its gap
   line proposes deleting the statement only when the test showed it
   false, and then quotes the test and its output.
4. Return the search and a gap list: a `Searched:` line naming the
   terms step 3 grepped and the files it read, then every line step 2's
   script printed, and one line per other failure of a bar item, naming
   the item and the sentence or absence that fails it. An empty
   list is the verdict `ready`.

## Mechanical gaps

A **mechanical gap** is one the bar alone settles the repair of, so
no design decision is in it: a section the bar forbids, a sentence that
fails "Spec quality", and a missing acceptance or files-affected heading
around content the body already carries. Its gap line opens with the
label `mechanical:`. The script labels the ones it prints; label each
"Spec quality" failure you grade yourself.

## Output

```text
Verdict: <ready | not ready>

Searched: grepped <terms>; read <files>

Gaps:
  - [mechanical: ]<bar item>: <the sentence or absence that fails it>
```

Under `ready`, the `Gaps:` section reads `(none)`.
