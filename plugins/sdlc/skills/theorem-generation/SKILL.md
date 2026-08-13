---
name: theorem-generation
description: How an sdlc theorem-generator turns a PR, its issues, and the surrounding codebase into a list of disprovable theorems. Preloaded into each theorem-generator variant via its skills frontmatter; not invoked from the user's slash menu.
user-invocable: false
---

# Theorem Generation

This is the operating instruction for every `sdlc` theorem generator.
It is **tier-invariant**: it carries no tier parameter and never asks
which generator is running it. The generator's reasoning tier lives
solely in the spawned agent's frontmatter `effort:`, and the pipeline
picks a tier by naming which definition to spawn (see the
`sdlc:pr-review-pipeline` skill → Inputs, and the `/sdlc:orchestrate`
skill → "Picking a generator tier").

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
`CLAUDE.md` from the worktree root: each of its sweep sections names a
fact that several surfaces mirror, so it tells you where a *changed*
fact leaves a stale restatement behind. Which of those sections
warrants a theorem is decided in "Codebase consistency" below, and the
test is narrow — the diff must change the mirrored fact, not merely
touch a file the section mentions.

## Inputs

You are given exactly these, as double-dash parameters:

- `--pr <N>` — the pull request.
- `--issues <N…>` — the issue set the PR is reviewed against, already
  resolved by the pipeline. This is the answer, not a claim: do not
  re-derive it, do not parse the branch name, and do not add or remove
  a member.
- `--branch <name>` — the PR's head branch.

## Workflow

1. **Fetch the diff** via `/github-prs:pr-diff <PR>`.
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

The repo's `CLAUDE.md` sweep sections are pre-written generators of
this class: each one names a fact and the surfaces that restate it,
any of which can go stale silently.

A sweep section warrants a theorem only when the diff **changes the
fact that section says is mirrored**. Touching a file the section
names is not the trigger, and treating it as one is what turns a diff
that merely grazes such a file into a theorem per mirrored surface —
each of them true, none of them at stake. Work each section in two
steps:

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

## On a re-review, regenerate from the whole diff

When you are generating for round N of a PR, read the **entire** diff
again, not the delta since round N−1, and regenerate the whole theorem
list. A theorem that survived in round 1 is not automatically true in
round 3: a later round can break it, and only a fresh pass over the
whole change sees the inconsistency that accumulated across rounds.

## Output format

Emit a numbered list and nothing else — no preamble, no summary, no
recommendations, no severity labels. One record per theorem:

```text
T1
claim: The diff satisfies acceptance criterion "…" of #206.
issues: #206
class: semantic
pointers: plugins/sdlc/skills/pr-review-pipeline/SKILL.md, step 4
```

Field rules:

- **`id`** — `T1`, `T2`, … in emission order. The pipeline routes and
  reports by this handle.
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
