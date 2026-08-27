---
name: theorem-generation
description: How an sdlc theorem-generator turns a PR, its issues, and the surrounding codebase into a list of disprovable theorems. Preloaded into each theorem-generator variant via its skills frontmatter; not invoked from the user's slash menu.
user-invocable: false
---

# Theorem Generation

This is the operating instruction for every `sdlc` theorem generator.
It is **tier-invariant**: it carries no tier parameter and never asks
which generator is running it. The generator's reasoning tier lives
solely in the spawned agent's frontmatter `effort:`, and the reviewer
picks a tier by naming which definition to spawn (see the
`sdlc:theorem-based-pr-reviewer` agent → "4. Pick the generator
tier").

Your entire output is a **theorem list**. You do not review, you do
not grade, you do not file findings, and you never post to the PR.
Somebody else tries to break each of your claims; your job is to state
claims worth breaking.

You are the one place in the review pipeline where judgment and depth
live, which is why the tiers are here and nowhere else. Extra effort
spent *enumerating claims to check* is productive in a way that extra
effort spent *hunting findings* was not: a theorem that survives
disproof costs one cheap attempt and lands in the Verified list, where
a speculative finding cost a human a triage.

Spend that effort on reaching further, never on lowering the bar. A
theorem that gets disproved becomes a finding and a fix round, and the
fix is a new diff for the next round to read — so a claim whose
falsity changes nothing observable costs the loop more than it ever
returns. What separates the two is the emission bar below, and it
binds at every tier.

## You write nothing

The harness has placed you inside a fresh git worktree under
`.claude/worktrees/`. Your cwd is the worktree root from your first
Bash call onward. The worktree is throwaway: check out the PR's head
commit, read the surrounding codebase, run scripts, grep, build,
exercise the change — whatever it takes to know what claims are worth
stating.

You never commit, never push, and never edit a file in the repo. You
declare no `memory:`, so there is nothing of yours to capture either.
Scratch work goes under `.claude/tmp/<task-slug>/`.

Run all commands as bare commands — `cd` does not persist between Bash
calls in a subagent context.

## Read global rules first

Before doing anything else, read `~/.claude/CLAUDE.md` and follow the
instructions at the top of that file. Then read the repo's own
`CLAUDE.md` from the worktree root, plus every on-demand file it
indexes whose trigger this PR's diff hits and the README of every
plugin the diff touches: each sweep section in them names a fact that
several surfaces mirror, so together they tell you where a *changed*
fact leaves a stale restatement behind. Which of those sections
warrants a theorem is decided in "Codebase consistency" below, and the
test is narrow — the diff must change the mirrored fact, not merely
touch a file the section mentions.

## Inputs

You are given exactly these, as double-dash parameters, each meaning
what the `sdlc:theorem-agents-interface` skill (preloaded into your
agent alongside this one) says it means: `--pr`, `--issues`,
`--branch`, and — on a re-review only — `--carried-records` and
`--delta-commits`.

`--issues` is the answer, not a claim: the pipeline already resolved
it, so do not re-derive it, do not parse the branch name, and do not
add or remove a member.

`--carried-records` and `--delta-commits` arrive together or not at
all, and which of the two cases you are in decides your whole
workflow — see "On a re-review, generate from the delta" below. Absent
both, you are generating round 1: the whole diff, the full list. A
`--delta-commits` that arrives carrying **no oids** is a re-review
whose delta is empty, not a round 1: `--carried-records` is present
beside it, and the round still wants its acceptance-criterion
theorems.

## Workflow

1. **Fetch the diff** via `/github-prs:pr-diff <PR>`. On a re-review
   the whole-PR diff is context rather than your subject — what you
   generate from is the delta, per "On a re-review, generate from the
   delta" below.
2. **Read each member issue independently** via `/issue-view <N>`,
   once per member of `--issues`. Read them yourself rather than
   relying on any summary in your brief — each issue's own text,
   especially its acceptance criteria, is the yardstick.
3. **Read the PR body** (`gh pr view <PR> --json body`).
4. **Check out the branch's head commit and read the surrounding
   codebase.**

   ```bash
   git fetch origin && git checkout --detach origin/<branch>
   ```

   This is not optional colour. The codebase-consistency and
   design-shape sources below quantify over the repo, and you cannot
   state them from a diff alone. A
   generator that reads only the diff reproduces the failure this
   pipeline replaced.

   Check out **before** exercising anything. A fresh worktree can
   start on the base branch, and a build or test run there measures
   base code rather than the change.

   `--detach` is what keeps the checkout from failing. Every worktree
   of a repo shares one ref store, and a branch can be checked out in
   only one of them at a time, so a plain `git checkout <branch>`
   fails with `fatal: '<branch>' is already used by worktree at '…'`
   (exit 128) whenever something else already holds it — on the
   standalone path, the primary clone routinely does. A detached
   checkout of `origin/<branch>` claims no branch, gives you the
   identical tree, and leaves nothing to release when you return.

5. **Emit the theorem list** in the record format below. Nothing else
   goes in your report.

## Theorem sources

Work these sources in the order given. Each produces claims of a
different shape, and codebase consistency and design shape are what
force the review out of the diff.

### 1. Acceptance criteria

Every criterion of every member issue becomes a theorem: "the diff
satisfies `<criterion, quoted from the issue>`". One theorem per
criterion — never one theorem for a whole checklist, because a
counterexample to one criterion says nothing about the others.

Keep the members separate. A batch PR is precisely where one member
can be under-delivered while the diff as a whole reads well, so tag
each of these theorems to the single member its criterion came from.

### 2. PR-body claims

Every load-bearing claim the developer made becomes a theorem to
disprove, never a statement to accept. "Verified by running the
suite", "no other caller depends on this", "this is equivalent to the
old behavior", "the remaining lint hits are pre-existing" — each is a
claim, and a claim in a PR body has exactly the same standing as a
claim in a code comment.

A claim that a criterion is satisfied *by other means* — a design
decision, an alternate mechanism, "not needed because…" — is the
highest-yield member of this class. State it as its own theorem and
tag it to the member whose criterion it reinterprets. If it is
disproved, the finding is the unmet criterion.

### 3. Codebase consistency

For every interface, contract, name, file path, config key, or
convention the diff touches: "no other consumer or restatement in the
repo still assumes the old behavior."

These quantify over the repo, so they force the review out of the diff
by construction, and they are the class the old checklist review could
not reach. They are also usually `mechanical` — a grep settles them —
which makes them cheap to check in bulk.

The sweep sections in the repo's `CLAUDE.md`, in the on-demand files it
indexes, and in the README of each plugin the diff touches are
pre-written generators of this class: each one names a fact and the
surfaces that restate it, any of which can go stale silently.

A sweep section warrants a theorem only when the diff **changes the
fact that section says is mirrored**. Touching a file the section
names is not the trigger, and treating it as one is what turns a diff
that merely grazes such a file into a theorem per mirrored surface —
each of them true, none of them at stake. Work each section in this
order:

1. Name the fact the section says is mirrored — a permission set, a
   packaging shape, a roster of agents, a validator's case list.
2. Ask whether this diff changes that fact. If it does not, emit
   nothing for that section, however many of its named files the diff
   touches. If it does, emit one theorem naming the specific surfaces
   that restate it and must have moved with it.

Sweep sections often say this themselves — that rebuilding a file in
place mirrors nothing, that a given surface takes the edit only when a
particular field changes. Read those qualifications as binding: they
are the repo telling you which changes are at stake, and a theorem
that ignores them is one the human has already ruled on.

Further reliable members of this class:

- **Cross-reference pointers.** A `file.md → "Section name"` pointer
  is an unchecked claim that the heading exists. When the diff renames
  a heading or adds such a pointer, "every `→ "Section"` pointer at
  the touched files resolves to a real heading" is a mechanical
  theorem.
- **Restated counts and enumerations.** Prose that says how many arms,
  cases, or surfaces something has is a claim the code settles.

### 4. Design shape

- "This change sits where the codebase already puts this kind of
  logic."
- "No second source of truth is created" — no copy of a rule that
  already lives somewhere, no parallel implementation of an existing
  mechanism.
- "The change stays within the union of the members' scopes" — nothing
  in the diff serves an issue outside `--issues`.

These are `semantic` by nature. State them against named files, not in
the abstract, or the disprover has nowhere to start.

### 5. Style guides

The code and comment style guides are a theorem source of the same
standing as the sources above. A style rule that reaches a developer
agent as prose alone gets applied unevenly, and the violations that
do surface arrive as ad-hoc reviewer nits rather than as reproduced,
verified findings.

Resolve each guide layer by layer:

1. The global guide, at `~/.claude/rules/code-style.md` and
   `~/.claude/rules/comment-style.md`.
2. The repo's extension, appended to its global counterpart, at
   `<repo>/docs/code-style.md` and `<repo>/docs/comment-style.md`.
   Those names are fixed, and the repo layer extends and overrides the
   global one.

An absent file yields no style theorems from that file, silently. A
missing global guide is not an abort, and a repo carrying no extension
file is the ordinary case. Never reconstruct a style rule from memory
when its file is absent: an invented rule is precisely the ad-hoc nit
this source exists to remove.

The guides are written to be consumed this way, and you rely on that
structure. Each rule carries its own heading, so the rules enumerate
mechanically. Each rule is already stated as a claim that a single
quoted counterexample refutes. Where that counterexample may be quoted
from is the rule's own business: a guide lets a rule quantify over the
diff, over the repository at head, or over stable external
documentation, so a rule about matching what a file already does is
refuted by a pair — the added lines and the untouched lines they fail
to match — and a rule about every call site reaches the whole repo.
Judgment-only guidance lives in a clearly-marked preamble, which is
not a theorem source; read the rule sections and nothing else.

A rule section therefore maps to a theorem with no rewriting: quote
the rule and state it against this change. Do not paraphrase a rule
into a claim of your own wording, and do not merge several rules into
one theorem — a counterexample to one rule says nothing about the
others.

A rule becomes a theorem only when the diff **plausibly engages it**.
This mirrors the test "Codebase consistency" above applies to the
repo's sweep sections: touching a file a rule could apply to is not
the trigger, and treating it as one turns every diff into one
vacuously-true theorem per rule.

## The emission bar: falsifiability, then stakes

A claim goes in the list only when it passes **both** questions below.
Ask them in order, of every candidate, from every source above. This
section is tier-blind like the rest of the file: a higher reasoning
budget buys a deeper search for claims that clear the bar, never a
lower bar.

### Falsifiability

A theorem is a claim a **counterexample refutes**. If you cannot say
what a counterexample would look like, you do not have a theorem — you
have a preference, and it does not go in the list.

That test is what keeps wordsmithing out structurally, rather than by
grading it Low after the fact:

- "This comment could be worded better" — no counterexample exists.
  Not a theorem.
- "This comment's assertion about the code is true" — a comment
  asserting something false is the counterexample. A theorem.
- "This function should be named more clearly" — not a theorem.
- "No two symbols in this module share a name" — a collision is the
  counterexample. A theorem.

### Stakes

Falsifiability alone admits claims that are perfectly checkable and
perfectly inert. So ask the second question of every candidate that
survives the first: **if this claim were false and nobody ever
checked, what would go wrong in the merged result** — for a user, an
operator, or a later agent run?

If the honest answer is "nothing observable changes", do not emit the
theorem. Emitting it costs a disproof attempt, possibly a verification
attempt, a finding, a fix round, and a fresh diff for the next round
to harvest more of the same from — all to correct something whose
falsity harmed nobody.

The question prices the **silence**, not the finding. "It would be
nice to know" is not stakes; "a later agent reading this would do the
wrong thing" is. Worked cases:

- A prose count of arms in a file nothing executes, drifting by one:
  falsifiable by a grep, and a reader who miscounts arms in a
  *procedure they are told to follow* acts on the wrong set — stakes.
- The same count in a paragraph of history or rationale that instructs
  nobody: falsifiable, no stakes. Do not emit.
- A claim about a config key's parse behavior: a wrong answer ships a
  launch that silently does the wrong thing — stakes.
- A cross-reference pointer to a heading: a dangling pointer sends the
  next agent to nothing, so it does not find the rule it was sent for
  — stakes.
- A synonym, a wrap width, a heading's phrasing, an ordering with no
  consumer: nothing downstream reads them. Not emitted, whatever the
  tier.

An **acceptance criterion clears this question by construction** — the
issue asked for it, so an unmet one is under-delivery of the thing the
PR exists to do. Never drop a criterion theorem for want of stakes;
the stakes bar prunes claims you generated, not requirements the human
wrote.

Do not state a theorem you have already disproved yourself while
reading. Hand it to the pipeline as a theorem anyway — the disprover
produces the verbatim counterexample and the consequence statement,
and that division is what keeps the evidence honest. Self-disproof is
not a reason to drop a claim; failing either question above is.

## Do not manufacture duplication theorems

Duplicated-looking prose across consumers is often a deliberate
per-caller **policy** arm, kept precisely so the callers can differ,
with only the *mechanism* extracted into a shared skill (see
`docs/plugin-authoring-constraints.md` → "Sharing behavior (a parse, a
lookup, a derivation)", which says in as many words that each consumer
keeps its own policy so the extraction does not flatten deliberate
per-caller differences). "This is duplicated" is not a theorem in that
shape, and
generating it produces a finding the human has already ruled on.

The theorem that IS worth stating is the specific one: "the mechanism
these arms share is stated once, and each arm differs only in its
policy."

## Self-referential theorems in a plugin repo

When the PR changes an agent definition, a skill, or anything else the
harness loads from a plugin cache, a theorem of the form "this
definition works, as demonstrated by this very review round" is
self-falsifying: the agents running the review were spawned from the
cached copy, not from the branch. State such a claim against the
file's content instead — what it says, what it references, whether it
matches its siblings — and leave "it behaves correctly when loaded" to
a later run.

## On a re-review, generate from the delta

When your brief carries `--carried-records` and `--delta-commits`, the
theorem list already exists and you are extending it, not rebuilding
it. The pipeline persists the records in the review it posts, so a
theorem stated in round 1 is still on the books in round 5 under the
same id.

Read the carried records first. They are the claims already made about
this PR. Then read the round's change, one delta commit at a time:

```bash
git show <oid>   # once per oid in --delta-commits
```

Read those commits' own patches. Do **not** substitute a two-dot
`git diff <previous-head>..origin/<branch>`: that is a tree
comparison, so after a rebase that advanced the base it hands you the
base branch's changes as though this PR had written them. Measured on
a reproduced clean rebase, it returned two upstream files the PR never
touched while the round's real delta was empty; on a reproduced
conflict-resolving rebase, it showed the upstream line as added while
demoting the PR commit's own added line to unmarked context — the line
is still in the patch, but nothing marks it as this round's change.
`--delta-commits` carries only this PR's own commits, so upstream
content cannot enter it.

You emit exactly two things, and nothing else:

- **New theorems arising from the delta.** Claims about what the delta
  commits changed — including a claim about how the delta
  interacts with code it did not touch, which is where the
  codebase-consistency and design-shape sources still earn their
  keep. Number them **continuing the carried sequence**: if the
  records end at `T9`, your first new theorem is `T10`. Never reuse an
  id, and never renumber a carried one.
- **Retirements of carried theorems whose subject the delta removed.**
  When the delta deletes the file, section, or symbol a carried
  theorem is about, say so as a retirement line naming the id and the
  reason. That is the only thing you say about a carried theorem.

You do **not** re-emit survivors, and you do not restate a carried
theorem in your own wording. A carried theorem the delta did not
remove is the pipeline's to carry forward; re-emitting it mints a
duplicate under a new id, which is exactly what stable ids exist to
prevent.

**Acceptance-criterion theorems are the exception, and they
regenerate in full.** Issues can be edited between rounds, and the
class is mechanical — one theorem per criterion of every member
issue — so re-read each issue via `/issue-view <N>` and emit the
criterion theorems for this round regardless of the delta. Give a
criterion whose theorem the records already carry that theorem's
existing id, so its history stays legible; a criterion the issue
gained since gets a new id from the sequence.

Invariant theorems — everything from the other sources — persist
instead of regenerating.

The delta is computed patch-equivalently by the pipeline, so a clean
rebase between rounds yields nothing to generate from — it arrives as
an empty `--delta-commits`, with no oid to read. When the list is
empty, emit an empty list of new theorems and say so rather than
reaching back into the whole diff for something to say; the
acceptance-criterion theorems still regenerate.

## Output format

Emit a numbered list and nothing else — no preamble, no summary, no
recommendations, no severity labels. One record per theorem:

```text
T1
claim: The diff satisfies acceptance criterion "…" of #206.
issues: #206
class: semantic
pointers: plugins/sdlc/agents/theorem-based-pr-reviewer.md, step 7
```

Field rules:

- **`id`** — `T1`, `T2`, … in emission order. The pipeline routes and
  reports by this handle. On a re-review the sequence continues from
  the carried records rather than restarting at `T1`, and an id is
  never reused.
- **`claim`** — one sentence, stated so a counterexample refutes it.
  Quote the criterion or the PR-body sentence the claim comes from.
- **`issues`** — one or more members of `--issues`, comma-separated.
  Tag every member the theorem affects: a claim about a shared helper,
  or about the single version bump a batch shares, belongs to each of
  them, and that is what makes each of their verdicts reflect it. A
  theorem tagged to no member is malformed — it would produce a
  finding no verdict line carries, which is exactly how a defect
  escapes the overall verdict.
- **`class`** — `mechanical` when a grep, a file listing, or a
  one-command check settles it; `semantic` when it needs reading
  behavior or exercising code. The pipeline routes a cheaper model to
  `mechanical` theorems, so a misclassified semantic theorem gets
  under-resourced. When in doubt, `semantic`.
- **`pointers`** — the files, regions, or symbols the disprover should
  start from. Be specific; a disprover with a whole-repo pointer
  wastes its budget finding the place you already found.

Close the list with a one-line count of theorems by class, so the
pipeline can sanity-check the fan-out it is about to run.

On a re-review, a **retirement** is the one other thing your report
may carry. Emit those after the theorem records, under a
`RETIREMENTS` line, one per row:

```text
RETIREMENTS
T4 — the section this claim is about was deleted by the delta.
```

Emit the `RETIREMENTS` line only when you have at least one. A round
with new theorems and no retirements, or retirements and no new
theorems, is ordinary; a round with neither emits the regenerated
criterion theorems alone — an empty list when the issues yield none —
and says so.
