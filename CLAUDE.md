# CLAUDE.md

## Bump the plugin version when you change a plugin

When a PR modifies any file under `plugins/<name>/`, it MUST also bump
that plugin's `version` in `plugins/<name>/.claude-plugin/plugin.json`,
in the same PR. The version bump is a separate, deliberate edit. A
plugin change without a version bump is incomplete.

## Settle a claim with the playbook, not by reasoning

The `/docs` playbooks carry the techniques that establish a fact about
this repo's code — how to build the harness, what control each probe
needs, and which convincing-sounding shortcuts measure the wrong
thing. Read the matching one before asserting behavior you have not
run:

- [`docs/guardrails-verification-playbook.md`](docs/guardrails-verification-playbook.md)
  — binary provenance (recipe rebuild, `nm` tables, build IDs,
  comment-only rounds), synthetic `PreToolUse` probing, flag-whitelist
  audits, and row-cross replays.
- [`docs/claude-vm-verification-playbook.md`](docs/claude-vm-verification-playbook.md)
  — non-booting vfkit probes, privileged-container mount semantics,
  probe-container/guest package parity, mkosi source checks,
  launcher-loop slicing, and grading a real boot's console-marker
  assertions.
- [`docs/verification-playbook.md`](docs/verification-playbook.md) —
  cross-domain: suite baselining and hybrid-tree negative controls,
  bounded-cleanup harnesses, pty handoff probes, bash 3.2 parsing,
  containerized bash 5 runs with a borrowed yq, rebase verification,
  and lint baselining.

They record technique, not policy: when a playbook step and a rule
here disagree, the rule wins and the playbook is the thing to fix.

[`docs/prose-claim-shapes.md`](docs/prose-claim-shapes.md) answers the
inverse question — not how to establish a fact, but which sentences to
distrust: the claim shapes that go false while every test stays green,
each with the tell and the check that settles it. Read it before
grading prose, and add to it when a round turns up a new shape.

Their sibling [`docs/agent-tooling-notes.md`](docs/agent-tooling-notes.md)
answers a different question — not how to establish a fact, but how the
tools themselves behave here: which shell the Bash tool runs, when a
successful `git fetch` leaves its ref behind, which `gh` verbs are
GraphQL and can fail while REST is healthy, what actually caps a long
`--body` (quoting, not the argument list), and the `yq` expressions
that return a wrong answer rather than an error.

## Grade a repo statement an issue contradicts, don't pick a side

An issue can specify something a repo document already forbids. Never
ship one half silently: implement the issue **and** settle the
contradicted statement in the same PR. Shipping the issue's version
alone leaves the repo asserting the opposite in a file a future agent
reads as policy; shipping the repo's version alone leaves an acceptance
criterion unmet with no explanation.

Which repair is right turns on what kind of claim the statement makes,
and the two take opposite repairs:

- A **capability** claim — what the harness can or cannot do — is
  verifiable. When it is false, delete it. Carving an exception out of
  it preserves a false claim as the general rule.
- A **policy** claim — a choice this repo made, where the harness
  permits both — is not falsifiable, so an issue may carve a named
  exception out of it, with the reason the two differ stated inline.

Prescriptive wording ("may only", "never") does not settle the grade;
that is exactly how a false capability claim reads. Whichever grade you
give, sweep every restatement rather than the one the issue names, and
say in the PR body which grade you gave, so the reviewer grades that
judgment rather than re-finding the contradiction. This is not an
escalation: the issue answered the design question, and what is left is
only what the repo statement was worth.

## MD041 on a SKILL.md is convention, not debt

`npx markdownlint-cli2` reports
`MD041/first-line-heading/first-line-h1` on essentially every
`plugins/*/skills/**/SKILL.md`, always at the first prose line after
the YAML frontmatter. Leave it alone. A `SKILL.md` body is a *prompt*
the model reads, not a document, so it opens with an instruction ("You
are running the `/foo` skill…") rather than an H1, and MD041 is the
only error class those files produce — a rule that fires uniformly and
alone, in a tree whose Markdown is otherwise spotless, is a tolerated
convention.

The global "Leave Markdown clean" rule would otherwise push you into
adding an H1 to a skill file, which changes the prompt payload the
model receives and, swept per "sweep the class", churns every skill
file in every plugin. Don't. When you edit a `SKILL.md`, verify you
introduced **no new** error classes — re-lint the base and compare
counts, rather than reading the raw total as debt you inherited — and
say in the PR body that the remaining MD041 hits are pre-existing and
why. Changing the convention is a repo-wide decision, not a doc-pass
sweep — the same carve-out shape as the `Phase 1` / `Phase 2` headings
below.

`lib/*.md` files under a plugin's `skills/` are ordinary documents and
DO carry an H1. They lint clean, and a new one you write must too.

## Never invoke a GitHub publishing verb

A `gh` verb that publishes — `gist create`, `gist edit`, `release
create`, `release upload`, `pr create`, `issue create`, `pr comment`,
`issue comment` — is never run to establish behavior, in any spelling,
for any reason. Not with `--help`, not with an invalid flag value, not
with a nonexistent path, not "because it will obviously error first".
Every abort story of the shape "the operand is absent" or "stdin is
empty" is exactly the story that fails: `gh gist create -pd <path>`
looks like it must abort on a missing `-d` value, but `-d` eats the
operand, `gist create` then falls back to stdin, and it POSTs. The
permission gate escalates a publishing verb to a human click rather
than denying it, so the gate is not the backstop for this — the rule
is. The prohibition is on establishing behavior; publishing a PR or a
comment the task actually asks for is ordinary work.

The questions that tempt an agent into one each have a safe answer:

- **A gate verdict** is settled by replaying a synthetic `PreToolUse`
  event against the built `permission-gate` binary. No verdict
  question is answered better by a real invocation.
- **A vendor parse fact** — which flags a verb takes, what its
  positionals mean, whether it defaults to stdin — is settled by
  reading `cli/cli`'s own source at the tag `gh` is pinned to:
  `gh api "repos/cli/cli/contents/<path>?ref=<tag>" --jq .content`
  piped through `base64 -d`. That is a non-mutating GET, and the
  command's registration block is stronger evidence than `--help`,
  which renders neither the whole accepted grammar nor the stdin
  fallbacks.

When a claim looks like it can only be settled by a real publish, stop
and report that, rather than deciding it is fine because you expect an
error first.

### The one named exception: the publish path itself is the deliverable

A PR that changes **how a body gets onto GitHub** — the `--body-file`
route `/github-prs:pr-review-submit` and
`sdlc:theorem-based-pr-reviewer` post through (issue #321) — may run
one `gh pr comment --body-file` against a scratch PR, carrying a body
of the size a real round produces, as its acceptance test.

The two differ in what the invocation is for. The prohibition exists
because an agent probing a verb's *grammar* can publish by accident,
against which the gate is not the backstop, per this section's
opening paragraph. Here nothing is being learned about the verb's
parsing: the flags, the target and the content are all chosen in
advance, and what the run establishes is that a body that size
survives the trip. No synthetic gate replay and no reading of
`cli/cli`'s source answers that, because the thing under test is the
round trip.

The exception is bounded to that: one publish, a scratch PR, a body
the PR's author wrote. It does not license a second run "to be sure",
a publish against a real PR, or any other verb. Everything else in
this section stands unchanged.

## Sweep orchestrate/SKILL.md when an sdlc agent's contract changes

`plugins/sdlc/README.md` exists, but it is a **pointer** document: it
owns the roster of skills and agents the plugin ships, plus the
`dependencies` edges and the cross-plugin skills those edges cover,
restating no agent's contract, no model, and no effort. So it is not
where a contract change lands: it takes an edit when a PR adds,
removes, or renames a skill or an agent, or changes which cross-plugin
skill this plugin invokes, and the sweep target for a contract change
is unchanged. The cross-plugin skills a `dependencies` edge covers are
not the same set as the skills this plugin invokes, so settle that list
by grepping the plugin tree for each dependency's skill names and
grading every hit rather than writing it from memory: a mention is not
a call site, and `skills/orchestrate/SKILL.md` names
`git-cleanup-branches-and-worktrees` — covered by the same `git-tools`
edge as skills `sdlc` genuinely invokes — only as the whole-repo sweep
of the same shape as the per-worktree cleanup the orchestrator does
inline. What it carries beyond the rosters is not a restatement
of any of that, but each part has a trigger of its own: it spells the
frontmatter keys that hold for a whole class — `isolation: worktree`
on every agent, `user-invocable: false` on the skills that are not
user verbs — so a PR changing either key edits it; and it is the only
file in the plugin that states `/sdlc:orchestrate` does not invoke
`/sdlc:orchestrate-ready` — `skills/orchestrate/SKILL.md` names the
grooming skill nowhere — so a PR that changes how the two relate edits
it there and this paragraph, which states the same thing in the course
of naming its owner, with it. Grade a uniqueness claim on either side
of that pair — "stated here and in no other file" — with a grep that
leaves the plugin, never one confined to `plugins/sdlc/`: the confined
grep returns the answer the claim wants, and naming an owner is itself
a second statement of the fact, so each side has to scope itself and
name the other as the second edit point.

Frontmatter tiers are a partial exception, and the halves differ.
SKILL.md deliberately names no agent's `model:`, so a model change is
confined to the agent file. That holds of `theorem-disprover` too,
whose model the reviewer routes per spawn: SKILL.md describes
the routing without spelling either model, per "The generator
skeletons are copies of one file" below. It does state the
`effort: medium` default — twice, in the teammate-frontmatter prose
near the top and in the "Token Efficiency" bullet — because that value
is a decision (the bounded, spec-driven tasks the teammates get are
more solid at medium) rather than a per-agent tier, and because effort
has no `Agent`-tool override, so frontmatter is the only lever. A PR
that changes any teammate's `effort:` therefore updates both SKILL.md
statements as well; grep SKILL.md for `effort` and confirm every hit
still describes the agents it claims to.

Both statements carry a named exception, so neither reads "every
teammate" unqualified: `theorem-generator` pins `effort: low`, and
`theorem-generator-high` and
`theorem-generator-xhigh` pin `effort: high` and `effort: xhigh`. That
is not effort varying per spawn — the thing the same statements forbid
— but a different agent definition being spawned, per "The generator
skeletons are copies of one file" below. `theorem-generator-medium`
sits at the default and is deliberately *not* in that exception list.
A PR that adds a further
off-default variant extends the exception in both places rather than
deleting the default.

Review is an agent — `theorem-based-pr-reviewer` — and its contract
lives in that agent's own body,
`plugins/sdlc/agents/theorem-based-pr-reviewer.md`, which both
`/sdlc:orchestrate` and `/sdlc:git-review-pr` reach by spawning it.
The review procedure is deliberately **not** a preloaded skill: the
shell-over-skill shape in this plugin exists for the generator tiers
alone, where `effort:` being frontmatter-only forces several
definitions over one procedure, and the reviewer has no tiers. So
a change to what a review does sweeps several files, not one — the
reviewer agent file, orchestrate's "Run the review pipeline" and
"Overriding the generator tier" sections, and
`skills/git-review-pr/SKILL.md`, which
is the standalone caller and states which parameters it deliberately
does not pass. A change to the review's *stages* — which agents it
spawns, in how many fan-outs — reaches one surface outside
`plugins/sdlc/` as well: `docs/plugin-authoring-constraints.md` →
"Fanning out parallel agents: one home for the procedure"
cites the reviewer as its worked instance and names the stages, and
the fetch-once paragraph below it names the agents that skip their own
fetch.

The generator **tier rubric** lives in the reviewer agent, next to the
delta it reads, and nowhere else. Orchestrate carries override
guidance only, and `git-review-pr` states that it computes no tier at
all. A PR that changes what the rubric measures edits the reviewer's
rubric section; a PR that changes when a *human* should override it
edits orchestrate. Re-adding a rubric to either caller is the second
source of truth this split removes.

What a brief parameter *means*, and what a consequence class means, is
owned by `plugins/sdlc/skills/theorem-agents-interface/SKILL.md`,
preloaded into every theorem agent through its `skills:` frontmatter.
So adding, renaming, or redefining a parameter or a class edits that
skill: the reviewer states only what it *puts* in each parameter and
what severity each class becomes, and a spawned agent's file only which
parameters its own brief carries and what it does with them that its
siblings do not. A brief-parameter gloss or a class gloss reappearing in
the reviewer or in an agent file is the second source of truth this
split removes, and a widening that stops at the reviewer leaves every
receiving agent describing a brief it no longer gets. The generator's
theorem *record* is a different surface carrying the same vocabulary,
and is not that duplication: `skills/theorem-generation/SKILL.md`
states what a generator puts in each record field and the reviewer's
"The theorem contract" tabulates what it consumes from one, with the
reviewer transcribing a record into a brief between them. So renaming
or redefining a class sweeps those surfaces as well.

On any widening of the orchestrator's teammate spawn templates, the
receiving side is the half that stays stale, and the half to check is
the bullet *list* under that agent's `## Inputs`, not the prose around
it. A widening is often argued by quoting that prose, which reads like
checking the other end: the quoted sentence can be true while the
enumeration above it still omits the new field. Match the list against
the template block field by field and repair on the receiving side,
since the template is what actually gets sent.

The orchestrator's own teammate briefs are two-sided the same way, and
the load-bearing side is what a brief may **not** carry.
`issue-developer`'s "Inputs" states that nothing of an issue's
*content* reaches it, and SKILL.md's spawn-prompt template carries no
title, body, labels, or files-likely-affected list — the two only
agree because both were changed together. Re-adding either end,
however helpful it looks, silently falsifies the other. The reasoning
for both, and for what the orchestrator may do with the report that
comes back, lives in SKILL.md → "Spawn-prompt principle" and
"Report-consumption principle"; a change to either contract updates
the principle rather than the one brief that prompted it.

Every mention of those two principles at a SKILL.md point where a
brief is written or a report is consumed — plus the two Hard
Constraints — is a `see`/`per` pointer, and what follows a pointer is
that site's *application* of the rule, never the rule's own
justification restated. "Never pre-solve a teammate's task" names the
review-findings exemption and points; "When a teammate escalates"
declares itself the named carve-out from "Own the synthesis" and
points. Re-arguing a rule at a consumption point reads like a helpful
reminder and reinstates the second source of truth the pointer shape
exists to prevent. The file's opening paragraph names both principles
in a bare parenthetical and is the one hit outside this rule: it
introduces them rather than applying them, so it neither points nor
restates. Grep `principle"` in SKILL.md and grade each hit that way
rather than by whether it is short.

Cross-reference strings need the same sweep:
`plugins/sdlc/agents/doc-updater.md` and SKILL.md's own fix-loop step
quote a `### After each ...` heading verbatim, so renaming a heading in
SKILL.md means grepping the quoted title across `plugins/sdlc/`.

That verbatim bar governs every quoted heading, not only the
`### After each ...` ones, and a returned grep is not the check. A
`→ "Section"` pointer that quotes the readable half of a longer title
— "The emission bar" for "The emission bar: falsifiability, then
stakes" — greps to a hit while quoting a string that is no heading in
that file, so a round that renames a heading and points at it in the
same commit is where truncated pointers appear. Compare each pointer
against the heading line itself. A line wrap inside the quotes is not
a mismatch: these files wrap at a column limit, so a title near it has
to break somewhere, and forbidding the break would be unsatisfiable.
Join the quoted string back across its line breaks — each newline and
the following line's leading whitespace collapsing to the single space
the wrap replaced — and compare that. What the comparison catches is a
pointer whose *words* differ from the heading's: a truncation, a
reordering, a dropped subtitle. A wrapped pointer and an unwrapped one
to the same heading both pass, so never reflow surrounding prose just
to unwrap one.

`plugins/sdlc/agents/theorem-based-pr-reviewer.md` numbers its workflow
steps (`### 4. Pick the generator tier`), which adds a failure mode
the bar above does not catch on its own: inserting or deleting a step
renames every later heading without the diff touching one of them, and
the pointers quoting the old number sit in files such a PR has no
other reason to open — every generator skeleton,
`skills/theorem-generation/SKILL.md`,
`skills/theorem-agents-interface/SKILL.md`,
`skills/orchestrate/SKILL.md`, and this file. So a renumbering PR
greps `→ "` for a leading digit across the repo rather than across
`plugins/sdlc/`, and compares each hit against the heading it names.
That grep is not the whole sweep either: the reviewer's own body
refers to its steps by bare number ("step 3", "step 9") throughout,
and no heading grep reaches those, so read that file end to end after
a renumber. The numbered headings themselves stay as they are, for the
reason the `Phase 1` / `Phase 2` paragraph below gives: renaming them
is a cross-file refactor rather than a doc-pass sweep.

Lower-yield surfaces name the agents and go stale only when a PR
changes which skill or config field an agent uses:
`plugins/github-prs/README.md` attributes one PR verb per agent in its
opening paragraph, repeats the diff-consumer list in its `/pr-diff`
section, and names `theorem-based-pr-reviewer` again in its
`/pr-review-submit` section as the caller that posts by `--body-file`,
which `plugins/github-prs/skills/pr-review-submit/SKILL.md` names once
more — as `plugins/github-prs/skills/pr-diff/SKILL.md` spells that same
diff-consumer list once more. Those are surfaces a `sdlc`-only PR
reaches only by remembering that adding a diff-reading agent, or
changing how the reviewer hands a body over, bumps `github-prs`
too. `plugins/issues/` names no `sdlc` reader of repo-config, and that
is deliberate: a reader contract states what the file provides, never
who consumes it, so `skills/lib/repo-config.md` describes each field
and the read sequence while `skills/repo-config/SKILL.md` describes
the file it writes, neither naming a consumer. A new `sdlc` reader of
repo-config is therefore no edit in that plugin, and re-adding a
reader roster to either file — however helpful the pointer reads — is
the defect this shape removes. What `plugins/issues/` does still name
the orchestrator for is unrelated to repo-config and stays:
`skills/lib/issue.md` says it is not part of the `/issue-*` namespace
and does not read that library, and `skills/issue-create/SKILL.md`
sizes an issue off the "Files affected" section the orchestrator's
analysis produces. The root `README.md`'s `sdlc` bullet names the
agents by shorthand only and spells no skill name, so it has nothing
to falsify: per `docs/plugin-authoring-constraints.md`, the root
roster registers the *plugin*, so a skill added, removed or renamed
leaves that bullet alone, and so does an agent's contract changing.
`docs/plugin-migration-plan.md` mentions the agents but is a frozen
historical plan — never edit it.

SKILL.md's `Phase 1` / `Phase 2` / `Phase 3` headings stay as they
are. They violate the writing-style no-sequence-names rule, but they
are load-bearing across the file's own report templates and a Hard
Constraint ("wait for confirmation before starting Phase 2"), so
renaming them is a cross-file refactor rather than a doc-pass sweep.
Say so in the report instead of churning on them.

## The generator skeletons are copies of one file

`plugins/sdlc/agents/theorem-generator.md`,
`theorem-generator-medium.md`, `theorem-generator-high.md`, and
`theorem-generator-xhigh.md` are
byte-identical except for the frontmatter lines `name:` and `effort:`
and the tier phrase inside `description:` (`default (low)` versus
`medium`, `high` or `xhigh`). That is the whole design — the generation
instructions live in
`plugins/sdlc/skills/theorem-generation/SKILL.md`, preloaded into each
skeleton through its `skills:` frontmatter, so a tier is a choice of
which definition to spawn rather than a parameter anything passes.

So an edit to any one skeleton sweeps every other one, and the check
is mechanical:

```bash
diff plugins/sdlc/agents/theorem-generator.md \
     plugins/sdlc/agents/theorem-generator-medium.md
diff plugins/sdlc/agents/theorem-generator.md \
     plugins/sdlc/agents/theorem-generator-high.md
diff plugins/sdlc/agents/theorem-generator.md \
     plugins/sdlc/agents/theorem-generator-xhigh.md
```

Each must report only those lines. Any further differing line is a
defect however sensible it reads: a variant that says something the
base does not is a second source of truth for generation behavior,
which is exactly what keeping the instructions out of the agent files
removed.

Generation guidance itself never goes in a skeleton. It goes in
`theorem-generation`, which is tier-blind by construction — it takes
`--pr`, `--issues`, `--branch`, `--carried-records`, `--delta-commits`
and no tier parameter, and asking it
which variant is running would let the tiers drift apart in behavior
as well as budget. The reviewer's tier rubric and its `--generator`
override parameter
(`plugins/sdlc/agents/theorem-based-pr-reviewer.md` → "4. Pick the
generator tier") are where a variant is named; adding or removing one
updates that section, orchestrate's "Overriding the generator tier"
section and the teammate roster above it, the reviewer's own
Inputs, and both `effort` statements the sdlc sweep section already
names.

A skeleton must not *enumerate* what that skill supplies either. Its
shared body says the generation procedure lives there in full and that
the generator follows every section of it, deliberately naming none:
any list of the skill's parts reads as its section set, and the one
the skeletons carried had already fallen behind, naming some of
`theorem-generation`'s H2 sections and silently omitting the rest. The
repair that fails next time is widening such a list; a skeleton
pointing at the whole file cannot go stale as the skill gains or
renames a section. The `diff` above is no protection here: that list
was byte-identical in every skeleton, so it passed the check while
naming a section set the skill no longer had. Read a skeleton's pointer
against `theorem-generation`'s own headings, not against its siblings.

What a generator may emit at all is generation guidance too, so it has
the same single owner: `theorem-generation` → "The emission bar:
falsifiability, then stakes", which states the questions a candidate
must clear to be emitted at all. Nowhere else — this file included —
is that bar restated rather than reached by pointer, and each pointing
site is deliberately bounded: the reviewer's "The theorem contract"
says only what a theorem arriving at the reviewer therefore is, and
orchestrate's teammate-effort paragraph only prices a surplus theorem
against the diff's stakes. A change to
either question edits the skill and then re-reads every such site,
because a bar spelled out at one of them is the second source of truth
that keeping generation guidance in one file removes. The bar is
tier-blind, like the rest of that skill: a higher tier buys a deeper
search for claims that clear it, never a lower one, which is why the
reviewer's tier rubric reads what the round's delta puts at stake and
not the effort the change took to write.

`theorem-disprover` is deliberately **not** a skeleton set. It has one
definition and no tiers, and its instructions live in the agent file
because there is no sibling to drift from. What varies per spawn is
its `model`, which the reviewer routes by theorem class. A frontmatter
`model:` is only a default — the `Agent` tool's `model` parameter may
name a lower, higher, or equal model on any spawn — so the value in
the disprover's frontmatter is what an unrouted spawn gets, not a
bound on what the reviewer may pass. No file outside that frontmatter
spells the value, here included: the reviewer names only the cheaper
model it passes for a `mechanical` theorem and otherwise says "the
declared default", which is what keeps a disprover model change a
one-file edit.

`counterexample-verifier` is the same shape and holds the same
property. It too is a single definition with no tiers, its model is
routed per spawn by the same theorem class, and no file outside its
frontmatter spells its value — the reviewer's verifier fan-out names
the cheaper `mechanical` model and otherwise points at the agent
file, and `plugins/sdlc/skills/orchestrate/SKILL.md`'s
model-routing paragraph names neither agent's default. So a verifier
model change is a one-file edit too, and adding a restatement to
either the reviewer or orchestrate is what would end that.

## Review writes nothing, so review lore is a PR

`plugins/sdlc/agents/theorem-based-pr-reviewer.md` and the agents it
spawns are strictly non-mutating on the PR branch: none of
`theorem-based-pr-reviewer`, `theorem-generator`, `theorem-disprover`,
or `counterexample-verifier`
declares `memory:`, and none carries an `Edit` tool. A review round
therefore commits nothing, pushes nothing, and writes nothing to
`.claude/agent-memory/`.

`theorem-based-pr-reviewer` alone carries `Write`, for one bounded
purpose: staging its review body under `.claude/tmp/<task-slug>/` so
`/github-prs:pr-review-submit` can post it by path, which a real
round's body needs because the inline form spells the body into a
double-quoted `--body "<body>"`, where the shell reads every backtick
and `$` in tens of kilobytes of Markdown that quotes code throughout
(issue #321). `.claude/tmp/` is gitignored and the reviewer has no
commit or push step, so nothing it stages reaches the branch. The
spawned agents carry no writing tool at all.

The theorem list a round carries forward is no exception either,
because it never lands on the branch: the reviewer persists the
records in the **review it posts**, and the next round reads them back
off the PR. A PR artifact is not a branch write. Do not repair a
persistence gap by giving review a file the branch would carry.

That is enforcement, not convention, so keep it structural: do not add
a `memory:` key to any of those definitions, do not widen the
reviewer's `Write` past body staging, do not give any spawned agent a
writing tool, and do not give the reviewer a commit step. A durable
lesson learned while reviewing lands as a PR against
`theorem-generation` (how to state a better theorem),
`theorem-disprover` (how to establish a fact),
`counterexample-verifier` (how to reject a bad counterexample), or
this file — never as a memory entry on the branch being reviewed.

No `sdlc` agent commits agent memory at all. `issue-developer`,
`issue-fixer` and `doc-updater` declare `memory: project`, and their
end-of-run step invokes `/cc-tools:agent-memory-inbox-capture`, which
copies the entries that outlive the run into a session-scoped inbox
under the harness scratchpad and drops the rest.
`agent-memory-scrubber` runs after all of them, invokes
`/cc-tools:agent-memory-inbox-cleanup`, and commits only the
`CLAUDE.md` and `docs/` changes it decides on. Nothing under
`.claude/agent-memory/` is ever staged, and the inbox dies with the
session — an entry capture drops, or one the scrubber does not
transfer, is gone.

That roster of memory-declaring agents is therefore `issue-developer`,
`issue-fixer`, `doc-updater` and nothing else.
`plugins/sdlc/skills/orchestrate/SKILL.md` names it in its
frontmatter-baseline paragraph and again under "Before `/pr-ready`:
curate the PR's agent memory", and the capture-then-curate sentences
later in that same frontmatter-baseline paragraph refer back to it as
"those three" — a count, not names, so no agent-name grep reaches that
back-reference and it goes stale in silence. A PR that changes which
agents declare `memory:` therefore sweeps every one of those sites.
`grep -rn 'memory: project' plugins/sdlc/` finds the frontmatter one;
the curation restatement names the agents without the key, so grep the
agent names too, and read the frontmatter-baseline paragraph to its end
rather than expecting a grep to surface the back-reference.

## The memory hand-off crosses a plugin boundary by contract, not by string

The capture-then-curate flow above is owned by `cc-tools` and driven by
`sdlc`, so a PR touching either side bumps both plugins' versions. No
`sdlc` file quotes a `cc-tools` skill's prose: `agent-memory-scrubber`
branches its landed-on-the-PR gate on the `Commit:` field the cleanup
skill's report carries, never on a sentence around it. Re-introducing a
quoted no-op line as a branch condition is the coupling this shape
removes — nothing tests such a string, so a reword in one plugin
silently breaks a gate in another.

The contracts under `plugins/cc-tools/skills/lib/` go the same way, and
the discipline is to keep it that way. The inbox path and
layout live only in `agent-memory-inbox.md`, and the grading rubric
only in `agent-memory-grading.md`; no file outside `cc-tools` spells
the inbox path, and the `sdlc` side says only that the entries go to
a session-scoped inbox under the harness scratchpad. An `sdlc` file
that spells the path, or restates when an entry is durable, is the
second source of truth those contracts exist to prevent — and it
cannot be a `Read` either way, since plugins are file-sandboxed
(`docs/plugin-authoring-constraints.md` → "Verified constraints").

## The issues config paths are literals every consumer spells itself

The `issues` plugin owns these config paths:

- `.issues/repo-config.md` — team-shared, committed, written by
  `/issues:repo-config`.
- `.issues/user-config.md` — one user's settings for one repo,
  gitignored, written by `/issues:user-config`.
- `$XDG_CONFIG_HOME/issues/user-config.md` — machine-wide per-user,
  written by `/issues:global-user-config`, outside every git clone.

None of those paths is a naming preference, and each of them replaces
a rules path — the two repo-level ones a `.claude/rules/` path, the
machine-wide one the home-anchored `~/.claude/rules/user-config.md` —
so do not move any of them back. Claude Code auto-loads every
`.claude/rules/*.md` that carries no `paths:` frontmatter into the
context of every session and every subagent, on every turn, so the
repo-level files living there were carried by every session in the
repo, including the ones that never invoke an issue verb — a config
is reference data a
reader fetches when it needs it, not an instruction the model has to
hold. And the user-global file sat inside the `~/.claude` mirror
clone, where staying uncommitted depended on that clone's own
`.gitignore` entry; under `$XDG_CONFIG_HOME/issues/` it sits outside
that clone instead, which is why `/issues:global-user-config` now
writes no ignore entry at all.

Nothing factors those out. Plugins are file-sandboxed
(`docs/plugin-authoring-constraints.md` → "A cross-plugin reference
does not resolve"), so a consumer in another plugin cannot follow
`plugins/issues/skills/lib/repo-config.md` and writes the path out
instead. `.issues/repo-config.md` is the one that crosses the
boundary, and it crosses it two ways. Its readers outside `issues`
inline-parse only the front-matter each one needs — a scalar field, a
status slot, or both — never the whole contract:
`git-tools`'s `git-branch-create` and `git-issues-from-branch`,
`github-prs`'s `pr-create`, and `sdlc`'s `theorem-based-pr-reviewer`,
`orchestrate` and `orchestrate-ready`. Its other mentions read
nothing and are just as breakable: `sdlc`'s `git-review-pr` describes
what the reviewer reads, `sdlc`'s `doc-updater`, `issue-developer`
and `issue-fixer` each say they no longer read it themselves, and
`issues-jira`'s `jira-lib` points at its `jira:` schema. The two
user-config paths stay inside `issues`.

So a PR that moves or renames a config path edits every plugin that
spells it and bumps each of their versions, in that one PR. Sweep it
by grepping the literal — `grep -rn '\.issues/' plugins/` and
`grep -rn 'XDG_CONFIG_HOME/issues' plugins/` — rather than by opening
the plugins the diff already touched, since a plugin can name the
path without reading it and a prose mention goes stale as loudly as a
reader does.

The `$XDG_CONFIG_HOME` fallback is the one part that is not
duplicated. `plugins/issues/skills/lib/user-config.md` → "Where
`$XDG_CONFIG_HOME` resolves" is the single definition of what an
unset or empty variable resolves to, and a consumer that needs the
resolution rule points at that heading. A second spelling of the
fallback is the defect, not a helpful expansion: nothing reads either
copy, so the two go out of step in silence.

Nothing migrates a repo or a machine off the old paths, so treat that
as the state of things rather than as an oversight to fix in passing.
`/issues:repo-config`, `/issues:user-config` and
`/issues:global-user-config` each look only at the new path, so an
already-configured repo re-runs the interview from built-in defaults
and the file under `.claude/rules/` stays put — still auto-loaded into
every session, which is the cost the move exists to remove. The one
automated cleanup is `/issues:user-config` deleting a stale
`.claude/rules/user-config.md` line from the repo's `.gitignore`; the
old files themselves are the operator's to delete. A repo whose
`.gitignore` is an allow-list needs the edit in the other direction
too — it would ignore a committed `.issues/repo-config.md` until a
`!` line un-ignores it, and this repo's own `.gitignore` is one such
allow-list.

## Sweep the claude-vm docs when guardrails hook packaging changes

How the `guardrails` permission-gate is *shipped* — prebuilt, committed
binaries under `plugins/guardrails/hooks/bin/<goos>-<goarch>/`, selected
at run time by `uname` — is described outside the `guardrails` tree as
well as inside it, because it decides what a claude-vm bake file's
`packages:` list must contain. The mirroring surfaces are
`plugins/claude-vm/payload/README.md`,
`plugins/claude-vm/payload/config-bake.example.yml`, and
`plugins/claude-vm/skills/claude-vm/SKILL.md` (both the commented config
block and the derived-keys section). What those surfaces mirror is the
*packaging shape*, so the trigger is a PR that changes it: the set of
`<goos>-<goarch>` directories under `plugins/guardrails/hooks/bin/`, the
selection or fail-closed logic in `plugins/guardrails/hooks/hooks.json`,
or the gate's build recipe. Such a PR must update those surfaces in the
same PR, and therefore bumps both plugins' versions.

Rebuilding the committed binaries in place — same directories, same
`uname` selection, still nothing needed in `packages:` — mirrors
nothing, so it fires no claude-vm sweep and no `claude-vm` version bump.
Every classifier-change PR touches `hooks/bin/`, so treating the path
itself as the trigger would demand a no-op edit on every one of them.

Gate *classifier* behavior is nearly the opposite: it lives in
`plugins/guardrails/hooks/permission-gate/README.md`, and no other
plugin describes it. The `/docs` surfaces that do are each bounded to
one reader. `docs/guardrails-verification-playbook.md` names verdicts
only as the *controls a probe needs* — which track terminates in allow
and which in defer, which probe rows must still deny, which spellings a
widening already allowed on the base. A verdict change that moves any
of those control rows updates it; grep it for `deny`, `allow`, `defer`
and `ask` alongside the README.
`docs/agent-tooling-notes.md` → "Read the worktree, never the primary
clone's path" names them for the agent being denied: that a
primary-clone read comes back as a worktree-escape deny carrying either
the worktree path to re-read or, where this worktree checks that path
out nowhere, a ref extraction; and the routes that still reach the
wrong bytes with no deny at all — a tool `hooks.json`'s matcher does
not name, a ref rather than a path, a statically unresolvable path, a
program the gate has no read table for, and `git`'s own subcommands,
which it classifies by subcommand shape and never for path
containment. A
verdict change that opens or closes one of those routes, or that makes
a denied read allow, updates it — and so does a change to the
`PreToolUse` matcher itself, which decides the first route and is
quoted verbatim there, in the gate README's "Gaps left in place
deliberately", and again in that README's "Registration" — so sweep it
by grepping the matcher string, not by editing the sites this sentence
happens to name.
`docs/verification-playbook.md` → "Baseline a lint run before filing
anything" names one verdict only, and only to keep a technique
runnable: linting the primary clone's copy of a file is the base-config
baseline, so that paragraph says why the lint run survives the
primary-clone read deny and why reading the base config itself does
not. A change that grades an unrecognized program's path operands, or
that changes what the read deny prescribes, updates it.

The gate README's one in-plugin sibling is
`plugins/guardrails/rules/scratch-file-location.md`, which describes
verdicts only where they decide **which destination an agent should
write a scratch file to** — the containment and `.git/` denies, their
prescriptive wording, the credentialed-tool redirect destination, the
`gh` publish-file read. A verdict change that leaves that choice
unchanged needs no edit there; one that makes a previously-safe
destination unsafe — or newly grades a path an agent parks a scratch
file in — does. `.claude/agent-memory/` is deliberately not on that
list, though a note teaching an agent to route around a gate verdict
does describe classifier behavior: that tree is gitignored, it lives
only inside the writing agent's throwaway worktree, and the session
inbox its entries are captured into dies with the session, so nothing
there survives to be falsified. Such a note reaches the repo only once
the scrubber transfers it into `CLAUDE.md` or a `/docs` file — grep
those two for the gate's own message fragments ("not all static
literals", "resolves outside the current repository", "cannot resolve
statically") whenever a verdict changes.

What a verdict looks like **on the wire** is a different axis, owned by
`docs/hook-event-notes.md` → `PreToolUse` (the decision channel, any
matcher): which `permissionDecision` values the harness accepts, what
it does with each, and that a hook abstains by emitting the envelope
with the field omitted rather than the literal `"defer"`, which Claude
Code reads as "pause this tool call for later resumption" and which
therefore ends a headless subagent's run (#271). That axis binds every
PreToolUse hook in the marketplace, not just the gate, so it lives in
`/docs`; the gate README carries the consequence for this gate and
points there for the harness-side rules around it. A
rebucketing PR touches none of it; a PR that changes how a bucket is
spelled on stdout touches it, the gate README, and the playbook's
probe-reading note together.

## Keep claude-vm's declaration prose and image-state prose apart

`plugins/claude-vm` uses the word "baked" for two different things, and
a sweep that flattens one into the other introduces errors. Before
rewording any "baked" / "already carries" sentence, check which side of
the host/guest seam the code it describes sits on.

- **Declaration (host side).**
  `claude_vm_boot_marketplace_egress_needed` in `payload/lib/config.sh`
  tests a boot-declared marketplace's name against
  `claude_vm_baked_marketplace_names` — the bake *declaration*. The
  build only *tries* to pre-register a boot-declared marketplace, so the
  host cannot know the image state and the gate is deliberately
  conservative. Prose here says "bake-declared", never "already baked
  into the image".
- **Image state (guest side).** `build-guest-image.sh`'s
  `boot_plugin_phase` genuinely reads the image, shelling out to
  `claude plugin marketplace list`. State wording is correct there and
  must survive a sweep; say which of the two a given step reads.
- **Neither.** The apt paragraphs' "hard-secure all-baked config"
  (`payload/README.md`, `payload/build-guest-image.sh`,
  `payload/claude-vm.sh`, `payload/config-boot.example.yml`,
  `payload/lib/config.sh`, `payload/provisioners/podman-mkosi.sh`,
  `skills/claude-vm/SKILL.md`) are about apt packages, which really are
  image bytes, and that gate has no membership test at all. Editing
  those is churn. Grep the exact phrase before deciding a hit is in this
  class: the marketplace sibling in
  `payload/provisioners/podman-mkosi.sh` is spelled "hard-secure
  all-bake-declared config" and belongs to the Declaration bullet above,
  not here.

That one derived-egress gate is described in several places, so a doc
pass that fixes the obvious ones looks complete: `payload/README.md`'s helper
bullet for `claude_vm_boot_marketplace_egress_needed`,
`payload/README.md`'s separate *Derived egress* paragraph much further
down in the guest-image section, and `skills/claude-vm/SKILL.md`'s
`add_marketplace_uris_to_allowlist` bullet. Grep the criterion wording,
not the helper name — the Derived egress paragraph never names the
helper. When the per-entry policy gains skip paths, count them in the
code and check the prose enumerates the same set.

## Narrow every claude-vm surface-only claim to the layer it measures

These `plugins/claude-vm` surfaces assert that the guest's Claude
configuration comes from the claude-vm configs **only**, because the
host's `~/.claude/settings.json` is never read:

- `payload/config-boot.example.yml` (the `permission_mode` /
  `permissions` block)
- `payload/config-bake.example.yml` (the marketplaces/plugins block)
- `payload/claude-vm.sh` (the settings-render call site)
- `payload/lib/config.sh` (the rendered-document key list)

Each sentence's evidence is about `settings.json` or about plugins, so
each names the layer it actually measures — the PERMISSION surface, the
PLUGIN surface — rather than "the Claude surface" as a whole. A change
that seeds further host `~/.claude` content into the guest widens the
host→guest seam and must re-narrow every one of them, because the false
half of such a sentence is its noun, not its verb: the `settings.json`
grep that finds these sites keeps returning true statements while the
subject above them is wrong. Grep the surface wording across
`plugins/claude-vm/` rather than checking only the files the diff
touched — the example YAML files among them are ones no test and no
doc pass naturally opens.

## Sweep every "no read-only mounts" surface when read-only lands

`plugins/claude-vm` extra mounts are read-write only, and the config
carries no `mode:` key: read-only cannot be enforced on this stack
(vfkit's virtio-fs device has no read-only export, and the guest session
is root, so a guest-side `-o ro` is undoable from inside). Issue #233
carries the enforced design — a read-only block device, so the
hypervisor refuses the write and guest root is irrelevant — and it need
not spell its config surface `mode:`.

Until it lands, an explicitly-supplied `mode:` is a hard abort at config
load rather than an ignored key, because silently accepting `mode: ro`
leaves an operator believing a share is read-only when the guest can
write it. The abort is a *presence* test (`claude_vm_mount_mode_entries`
asks yq `has("mode")`), since `mode: ""` and a valueless `mode:` render
as the same empty field an omitted key does. It is asked of the MERGED
boot document, which today lets `mode: {}` through — see the
presence-gate section below before restating "any `mode:` aborts" as a
complete claim.

The "there is no read-only option" claim is restated on every surface an
operator or an agent can reach, so a PR that adds enforced read-only in
one place leaves the rest asserting the opposite: `payload/README.md`
(*No read-only mounts*), `payload/config-boot.example.yml`'s boxed
`mounts` warning, `payload/lib/config.sh`'s extra-mount block and the
abort's own operator message, `payload/claude-vm.sh` in **two** places —
its extra-mount block *and* its `claude_vm_check_mounts` call-site
comment, which restates the same rule in one line —
`payload/build-guest-image.sh`'s `boot_mount_phase` block and its
`-o rw` comment, `skills/claude-vm/SKILL.md`, and
`skills/claude-vm-config-repo/SKILL.md`. `payload/test/config-test.sh`
pins the abort in every spelling.
`docs/claude-vm-verification-playbook.md` carries the vfkit and
kernel measurements the claim rests on — that virtio-fs has no
read-only knob, and that guest root remounts a `ro` bind `rw` — so
enforced read-only lands there too, as the measurement that changed.

A `read-only` grep across `plugins/claude-vm/` also turns up a second,
opposite class, and the two are easy to conflate: the **built-in** shares
(`runconfig`, `claudebin`, `claudecreds`) really are read-only, but
**guest-side only**. The host attaches each as a plain
`--device virtio-fs,sharedDir=…,mountTag=…` — the only shape vfkit accepts,
so read-write like any extra mount — and the `ro` comes from the image's own
`/etc/fstab`, authored in `payload/provisioners/podman-mkosi.sh` (the source
of truth for which tag is `ro` and which is `rw`). Write "shared into the
guest, where the image's fstab mounts it `ro`", never "shared read-only into
the guest": the latter puts the guarantee on the side of the seam that
cannot make it, and contradicts the no-read-only-mounts surfaces above.

`payload/README.md` → *Where the `ro` on a built-in share comes from* is the
one place that explains this; every other mention is a restatement that
should point there rather than re-derive it. The restating surfaces are
`payload/README.md` (its credential section and its *Verified claude cache*
section, twice in the latter), `payload/claude-vm.sh`,
`payload/build-guest-image.sh`, `payload/lib/claude-cache.sh`,
`payload/config-boot.example.yml`, `payload/test/host-acceptance.sh`,
`skills/claude-vm/SKILL.md` and `skills/claude-vm-config-global/SKILL.md`.
Grep both `read-only` and `RO` across `plugins/claude-vm/` and sort every hit
into one of these two classes rather than fixing the surfaces a diff happens
to touch.

## Grade a new use of a claude-vm mount tag against the enumeration

A `mounts` tag in `plugins/claude-vm` is consumed **verbatim** in every
position it reaches: vfkit's `mountTag=`, a bare argv word in the guest's
`mount -t virtiofs -o rw <tag> <path>`, a path *component* — in the
`/mnt/<tag>` default mountpoint, in the host-side wrap directory a
single-file source is staged in, and in that wrap's own guest mountpoint —
and a `mounts.tsv` field. `claude_vm_check_mounts`'s charset check
(`[A-Za-z0-9._-]`) is therefore necessary and not sufficient, and its `.` /
`..` and leading-`-` arms exist because two of those positions reject
spellings the charset admits.

`payload/README.md` → *The tag is not just a tag* is the enumeration those
arms are derived from. Code that gives the tag a **new** position — a
filename, another argv slot, a shell-interpolated string — must be graded
against that list and add an arm when the new position rejects something the
existing ones accept, rather than being assumed safe because the charset
passed. The restating surfaces to keep in step are
`payload/lib/config.sh`'s block comment, `payload/claude-vm.sh`'s
`claude_vm_check_mounts` call-site comment — which enumerates the validator's
whole rejection set in one paragraph, a file away from the check itself —
`payload/config-boot.example.yml`'s `tag:` bullet,
`skills/claude-vm/SKILL.md` and `skills/claude-vm-config-repo/SKILL.md`.

The same verbatim-interpolation exposure runs one level wider than the
config: every vfkit argument carrying a host path — the built-in `--device`
shares, the EFI variable store, the disk, the console log, the gvproxy socket
— embeds it in a comma-delimited option string with no comma check, so a
repo, `$HOME` or `$TMPDIR` path carrying a comma breaks a launch that has no
`mounts` entry at all. `$TMPDIR` reaches it on every launch, through the
gvproxy socket's own `mktemp -d`, whatever the mount mode. That is deliberate
and documented in the same README section — do not "fix" it inside
`claude_vm_check_mounts`, which never sees those paths. The single-file wrap
share (`sharedDir=$MOUNT_WRAP_DIR/<tag>`) is the one member the launcher does
check, and only because this feature adds it: the check sits in the
extra-mount loop's single-file branch — at the point of use, not beside the
`$MOUNT_WRAP_DIR` assignment, since only there is there an entry to name —
and blames `$TMPDIR` or the run dir rather than the operator's `mounts` entry.
It buys an early, cause-naming abort, not survivability — the other arguments
still break the same launch, and a directory-only `mounts` list under the same
comma-carrying `$TMPDIR` is not aborted at all.

## Never split a claude-vm TSV record with a tab-IFS `read`

`plugins/claude-vm` moves multi-field records between its scripts as
yq `@tsv` lines. A consumer must not take one apart with
`IFS=$'\t' read -r a b`: a tab is IFS *whitespace*, so `read` collapses
a run of tabs into one separator *and* strips a leading one. A record
with an empty **middle** field loses it, shifting every later field
left; a record with an empty **leading** field loses that. Both are
silent. Issue #226 found the middle-field case on a marketplace url, an
apt `key_url` and a mount `tag`, and the leading-field case on a
marketplace `name` and a `claude.plugins.enabled` key — each producing
a wrong-but-plausible value rather than a failure, so two-field records
are no safer than three-field ones. Read the whole line with
`IFS= read -r` and split it with `${rec%%$TAB*}` / `${rec#*$TAB}`,
which is total because `@tsv` always writes every separator. Skip a
wholly empty record first: an empty result set from these emitters is
one empty *line*, not zero bytes.

Splitting correctly only makes a malformed entry visible. An entry
whose KEY field (a marketplace `name`, a mount `tag`, an `enabled` ref)
is empty must then abort at config load, naming the entry — not be
skipped. The reasoning, the affected loops, the load-time gates, and
the test shape (run the real loop against the real emitter, plus a
negative control rebuilt from the same captured lines) are in
`plugins/claude-vm/payload/README.md` → *Splitting a TSV record back
apart*.

One collection deliberately never travels as `@tsv` at all: `env.set`
(issue #135). An environment value may legitimately contain a tab or a
newline, and `@tsv` escapes those into a literal `\t` / `\n` — silently
changing what the operator wrote, with nothing to detect it downstream.
So `claude_vm_env_set_names` / `_tag` / `_value` fetch one entry per yq
call instead, and the value never shares a line with anything else.
Folding them back into a single record emitter, for symmetry with the
other loops or to save yq invocations, is the bug this paragraph exists
to prevent: the map holds a handful of entries, so the extra calls are
not a cost worth the exposure.

Avoiding `@tsv` is only half of it: `$( )` strips **all** trailing
newlines, and yq adds one of its own, so capturing an `env.set` value
raw loses the newlines the operator wrote and cannot even distinguish
one from three. That is the same silent mutation, and it is worse than a
bad value on its own because the bake tier has no such loss — the value
rides `claude_vm_bake_config_json`'s JSON and Python `shlex.quote`s it —
so the two tiers ship different bytes for the same literal.
`claude_vm_env_set_value` therefore captures behind a sentinel byte,
strips exactly yq's one newline, and returns the value already
`%q`-quoted, so its own caller's `$( )` has no newline left to eat. Any
new reader of an `env.set` value calls that helper rather than adding a
second raw capture. The reasoning and the test shape (source both tiers'
rendered assignments for the same trailing-newline literal and compare
bytes, plus a negative control on the raw-capture shape) are in
`plugins/claude-vm/payload/README.md` → *Guest environment variables*.

## Write claude-vm for bash 3.2, not for bash 5

Every `plugins/claude-vm` script is `#!/usr/bin/env bash`, so on a stock
macOS the interpreter is `/bin/bash` **3.2**, and no launcher-reachable
code may need bash 4 — `lib/config.sh` today contains no bash-4
construct at all. The old carve-out ("parts run late and fail loudly")
is retired: it excused a `local -A` in
`claude_vm_render_guest_settings`, which #108's real launch killed after
the image build, and whose `map["$ref"]=` assignment 3.2 mis-parsed
*silently* — an indexed subscript is evaluated arithmetically, so a
plugin ref died on `set -u` rather than announcing anything. A late
failure is neither harmless nor reliably loud.

The config-load guards keep the sharper form, because their failure is
quieter still: they run first and decide whether a mount is safe, so a
construct that behaves differently on 3.2 silently changes a guard's
verdict instead of stopping the launch. Specifically: never declare an
associative array (`local -A` / `declare -A`) — use two parallel indexed
arrays and a last-wins linear lookup; never write a backslash-escaped
delimiter in the **replacement** half of
`${var//pattern/replacement}` (bash ≥ 4.3 unescapes `\/`, 3.2 does not —
hold the literal in a variable), and never expand `"${arr[@]}"` on a
possibly-empty array under `set -u` (write `${arr[@]+"${arr[@]}"}`). Pin
such a guard by *running* it under the host's pre-4 bash, with a negative
control on the spelling it avoids, skipping the block when the host has
no old bash rather than faking it with a fixture. `test/config-test.sh`
carries the same shebang, so the suite is under the same rule, not only
the code it checks: a `case` written inline in an assertion's own `$( )`
mis-parses on 3.2 — the substitution ends at the pattern's `)`, and what
comes back is a fragment of the assertion's own source — so the harness
FAILs on a guard that is fine. Lift the `case` into a function and call
that from the substitution. Say which side of the line such a failure
sits on: a 3.2-only construct in an assertion costs a reader's trust
with a false FAIL, where the same construct in a guard ships a hole. The
reasoning, the measured outputs and the test shape are in
`plugins/claude-vm/payload/README.md` → *A guard must survive the oldest
bash that can reach it*.

`payload/test/config-test.sh` must be **fully green** under `/bin/bash`,
and a "these N always fail on 3.2" baseline is never an acceptable
answer — that baseline is precisely what hid the `local -A` render
defect through several review rounds while a real launch could not get
past it. A red assertion under 3.2 is a defect to fix, in the code or in
the assertion, never a number to carry in a PR body. An acceptance run
proves nothing about this either way: the stub config it launches with
exercises only the paths its own keys reach.

## Sweep the ordering notes and share lists on a boot-launcher insertion

Inserting a step into the boot launcher that
`plugins/claude-vm/payload/build-guest-image.sh` emits leaves two
surfaces stale, both far from the diff: the launcher is one long
heredoc, so phase-ordering prose sits hundreds of lines from any
insertion point, and the credential share a new step may read is
described from a different file entirely.

- **The next phase's `ORDERING:` note.** Each phase's block comment
  states its own position as "first thing after X, before Y", so a step
  inserted between two phases silently falsifies the note on the one
  that follows it. Grep `ORDERING:` in `build-guest-image.sh` after any
  insertion, not only the block the insertion lands in.
- **The `claudecreds` content enumerations.** The headers that list
  what the transient credential share carries: `claude-vm.sh`'s run.env
  `CLAUDECREDS_TAG` comment, `claude-vm.sh`'s `CREDS_DIR=` header
  several hundred lines earlier, `build-guest-image.sh`'s
  `CLAUDECREDS_MNT=` header, and `payload/test/host-acceptance.sh`'s
  share-topology block, which enumerates the same members while
  describing the stub shares its boot test stands up — a fourth surface
  with the same shape, in a file a code-only sweep does not reach. Only
  the first sits next to a change that adds an entry. The other three
  also assert what the launcher *does* with each entry — installs it
  into `$HOME/.claude/` — so an entry the guest merely sources needs
  that sentence widened rather than a list item appended under it.
  Every one of them that also asserts the *mode* each lands with
  (`0600`, `chmod`'d after each copy) — today
  all but the `CREDS_DIR=` header — states a clause covering only the
  single files the launcher `chmod`s. An entry the guest copies with no
  `chmod` — `claude-home/` (issue #108), whose contents the launcher
  merges in without one — makes the clause false the moment it joins
  the enumeration above it, so narrow the clause on every surface that
  carries it rather than only appending to the list.

Re-run `payload/test/boot-launcher-test.sh` on any launcher edit,
including a comment-only one: it parses the emitted script.

## A claude-vm presence gate asks the raw config file, not the merged one

`claude_vm_merge_config`'s last step is
`claude_vm_prune_empty_skeleton`, which deletes every
`CLAUDE_VM_LIST_KEYS` entry whose merged value is an empty list, plus
any map left empty as a result. That prune is correct and stays: it is
what stops a consumer conflating "the operator configured this as
empty" with "the operator never touched it". Its consequence is the
trap — **adding a key to `CLAUDE_VM_LIST_KEYS` silently disarms any
`has()` presence gate on that key**, because the merged document no
longer carries the key in exactly the spellings the gate exists to
catch (a valueless `copy:`, `copy: []`, `copy: ""`). Nothing errors;
the gate just answers *false* and the launch proceeds.

The list-key route is only the loudest of three, and the other two
reach keys that are **not** list keys at all, so "this key does not
union" never clears a merged-document read. Pass 2 deletes an empty
*map* wherever it sits, so any key written `key: {}` vanishes. And a
valueless `key:` arrives as a genuine null, which a `!= null` value
test reads as absent — except in the global-file-with-no-repo-file
layering, where the deep merge against the empty document coerces it
to `''` and the same test says present. A gate reading a merged
document can therefore give two verdicts for one config, decided by
which layer the file sat in.

That is what the first round of issue #135 shipped and what a real
launch caught: `.env.copy` / `.env.files` joined
`CLAUDE_VM_LIST_KEYS`, `claude_vm_check_env` asked `MERGED_BAKE`, and
a bake file holding a valueless `copy:` built an image. The repair is
to ask the RAW files the operator wrote — `claude_vm_env_bake_has_key`
takes one raw bake path, and `claude_vm_check_env` takes the global
and repo bake paths after the two merged documents, which is also what
lets the diagnostic name *which* file carries the key. Never exempt a
key from the prune instead: an exemption reinstates the
configured-empty-looks-configured trap for the next reader and changes
merge semantics for keys that have nothing to do with the gate.
Presence is a property of what was WRITTEN, and only the raw files
still hold it.

So: any gate that asks "did the operator write this key?" asks the raw
file, whatever spelling the test is written in. Grep
`plugins/claude-vm/payload/` for `has(`, `!= null` and `== null` and
grade every hit against all three prune routes — not just against
`CLAUDE_VM_LIST_KEYS`, and not by the document the gate happens to
read. `claude_vm_check_plugin_key_placement` shipped a `!= null` value
test on the merged documents and was measured accepting a misplaced
key in four spellings out of four for `bake` / `install_at_boot` and
two out of four for `update_at_boot` /
`add_marketplace_uris_to_allowlist` / `enabled`; it now asks
`claude_vm_plugin_raw_has_key` of the four raw config paths and takes
no merged document. Its two directions are asymmetric — a BOOT-only
key is hunted in the two BAKE files, a BAKE-only key in the two BOOT
files — which is why it takes four raw paths where
`claude_vm_check_env` takes the bake pair only.

Sitting inside a list *element* is not the exemption it looks like.
`claude_vm_mount_mode_entries` asks `has("mode")` of the merged boot
document on that reasoning, and pass 1 (whole empty list keys) does
leave it alone — but pass 2 is `del(.. | select(tag == "!!map" and
length == 0))`, and `..` descends into list elements, so a `mode: {}`
written inside an entry is deleted and that config launches while
`mode: ro` / `""` / `[]` / valueless all abort (measured through the
real merge against yq v4.53.3, both layers). Treat that as an open gap
in the `mode:` abort, not as a documented exemption. A fallback READER
is fine — `claude_vm_bool_scalar`'s `(<path> == null)` treats a pruned key as
unconfigured, which is what the prune means. Pin the difference by
driving `claude_vm_merge_config` in the launcher's own argument shape
rather than calling the gate on a hand-written fixture —
`config-test.sh`'s env battery was green on fixtures for four review
rounds while the launcher was letting the config through, and the
placement battery had the same shape. The local reasoning and the
measured per-key table are in
`plugins/claude-vm/payload/README.md` → *Guest environment variables*.

## Sweep the claude-vm config wizards when its schema or validation changes

`plugins/claude-vm/skills/claude-vm-config-global/SKILL.md` and
`plugins/claude-vm/skills/claude-vm-config-repo/SKILL.md` duplicate the
config key tables and the YAML templates rather than referencing
`payload/README.md`, `skills/claude-vm/SKILL.md` and the
`config-*.example.yml` files, so nothing forces them to move when those
do. A claude-vm doc pass covers the latter three naturally and misses the
wizards, and the miss is a live defect rather than a cosmetic one: the
wizards instruct the model to write a config verbatim, so a key sitting
in the boot template when it belongs in the bake one — or an entry shape
the launcher now rejects — makes the wizard produce a config that aborts
the launch.

Any change to the config schema **or to its validation** therefore sweeps
both wizard files. These classes land there and nowhere else:

- **Key placement.** Check the key table's bake/boot *file* column, the
  YAML template the skill writes verbatim, and the "Hard constraints"
  placement bullet.
- **A new load-time gate**, even when no key changed — an entry the
  launcher now refuses, a subkey that became required. The wizard writes
  entries verbatim, so a gate it does not know about is a config that
  will not launch. A gate that runs over the MERGED global+repo lists
  belongs in the per-repo wizard's bullet too: the `mounts` tag and path
  checks work that way, so a per-repo entry can collide with a global one
  the wizard has just shown the operator.
- **A behavioral caveat about a value the wizard offers** — proposing a
  single file as a `source:`, say. The wizard is what talks the operator
  into the entry, so a caveat that reaches `payload/README.md`,
  `skills/claude-vm/SKILL.md` and `config-boot.example.yml` and stops
  there leaves the wizard recommending the shape the caveat warns about.

Grep the wizards for `sibling slice` and `schema + merge only` on the
same trigger: a key described there as having no consumer yet keeps that
description after it gains one.

Neighbouring surfaces go stale on the same trigger and are missed the
same way.
`payload/README.md`'s helper-function list carries new `lib/config.sh`
helpers and changed signatures. And the summary comments that enumerate a
validator's cases or the launcher's phases from *elsewhere in the same
file* — `claude_vm_check_mounts`'s call-site comment in `claude-vm.sh`,
and the emitted boot launcher's file-header step list in
`build-guest-image.sh` — go stale while the function's own header and the
phase's own block comment get updated.

## github-setup's App-permission sweep is owned by its plugin README

`plugins/github-setup/README.md` → "Sweep every App-permission surface
when the starter set changes" owns what a change to the PR-automation
App's starter permission set fires: which files in that plugin restate
the set as a literal list, which one deliberately renders it instead,
which look-alike list in another plugin is never swept along, and the
converge-time consequence of widening the set. Read it before editing
any `plugins/github-setup/` file that names a permission scope.

None of that is restated here. The pointer exists because this file is
loaded in every session and a plugin README is not, so without it the
sweep is reachable only by an agent who already thought to open the
README.

## Add a README roster entry when you publish a plugin

When a PR adds a new plugin entry to `.claude-plugin/marketplace.json`,
it MUST also add a matching bullet to the top-level `README.md`
"Published plugins" list, in the same PR. Registering the plugin in
`marketplace.json` and writing its own `plugins/<name>/README.md` does
not update that roster — it is a separate, easy-to-miss doc surface.
Word the bullet like its neighbors: the plugin name in bold backticks,
an em-dash, and a one-line description (pull language from the plugin's
`plugin.json` `description` or its README's opening line).

## An issue's "Known gaps" section is a doc requirement

When an issue body carries a "Known gaps left in place" section — or
any equivalent statement of what the change deliberately does *not*
do — treat it as an unmet doc requirement until the PR proves
otherwise. The developer documents what the change does; the gaps read
as nothing to write down, and they are exactly what a future agent
cannot recover from the code, because the absence of a check looks
like an oversight to fix rather than a decision to respect.

Grep the README for each gap's mechanism name before concluding it is
covered, and check whether nearby prose now reads as a completeness
claim it cannot support — a true statement about one spelling of a
case routinely reads as covering every spelling.

## The PR description is a doc surface

A PR body goes stale for the same reasons a README does, and nothing
tests it, so a hand-listed count or an unjustified "the list is closed
because …" survives there longest. Read it with
`gh pr view <N> --json body -q .body`, edit a scratch copy, and pass it
back with `--body-file`.

Two constraints bound that work, and only two. The closing keyword
survives byte for byte — never add, remove, or retarget one. And
nothing else on the PR is in scope: no comments, no reviews, no
labels, no other PR or issue.

## A rebase can absorb an identical version bump

After rebasing a plugin-touching branch, re-read each touched plugin's
`version` against the default branch's copy and bump again if they now
match. When both sides bumped the same plugin to the same value — which
is exactly what happens when the branch and a concurrently-merged PR
each apply the bump rule above — git sees an identical change on both
sides and resolves it silently. No conflict, no marker, nothing in the
rebase output; the file simply drops out of the branch's diff. The
branch still modifies files under `plugins/<name>/`, so the per-PR bump
rule is now violated, and the only signal is the *absence* of a diff
line you have to notice is missing.

## Never test the package's own prose

A test suite asserts that code does what it should do. It is not the
place to enforce a documentation or style standard. Never write a test
that parses or greps the package's own source for prose shapes — issue
references in comments, comment wording, TODO formats — and when told
to remove one, do not replace it with a differently shaped mechanism:
no build tag, no generator, no linter config added in the same PR, no
equivalent check relocated elsewhere.

Two reasons. Documentation standards change independently of behavior,
so a style rule living in the test suite fails the build over prose.
And a pattern-matching check encodes the narrow syntactic case as the
definition of the class, making the tree look clean when it is not —
the wrap-split instances of the very pattern go unseen.

The legitimate sibling, so the line stays clear: a check over text the
program *emits* is behavior and stays. Grading the reason strings a
hook returns is part of its contract; grading comments is not.

When you remove such a mechanism, sweep every claim it spawned in the
same round — README sections, code comments, the PR body — including
its exemptions and any "every X is gone" or "fails the build if
reintroduced" completeness claim. Those are false the moment the check
is gone, and a stale claim is worse than none. Keep the convention and
its rationale; drop the enforcement story.

## The rebase automation can move a PR branch mid-session

This repo runs a scheduled rebase sweep that force-rebases open PR
branches onto the default branch, and it can fire while you are working
on one. The symptom is a checkout that reports diverged histories right
after a fetch, with the same logical commits under different hashes
rooted on a newer merge.

Recover by rebuilding your work onto the new tip rather than resetting
— a worktree must never reset away commits it has not pushed. The
sweep acts only on behind-or-blocked states and deliberately skips
conflicted ones, so a conflicted PR never self-heals and is yours to
rebase.
