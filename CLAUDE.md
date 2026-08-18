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
  comment-only rounds, quoted digests), synthetic `PreToolUse`
  probing and what a probe cannot settle, flag-whitelist audits,
  row-cross replays, and the comment-vocabulary sweep a rebucketing
  owes.
- [`docs/claude-vm-verification-playbook.md`](docs/claude-vm-verification-playbook.md)
  — non-booting vfkit probes, privileged-container mount semantics,
  probe-container/guest package parity, container-egress probing,
  mkosi source checks, launcher-loop slicing, driving a real build and
  boot with a stub `claude` as the assertion channel, `debugfs`
  inspection of the built image, and grading a real boot's
  console-marker assertions.
- [`docs/verification-playbook.md`](docs/verification-playbook.md) —
  cross-domain: suite baselining and hybrid-tree negative controls,
  deriving a control from the shipped code, bounded-cleanup harnesses,
  command-substitution harness traps, pty handoff probes, bash 3.2
  parsing, unquoted-heredoc prose, async process-substitution probes,
  containerized bash 5 runs with a borrowed yq, rebase verification,
  and lint baselining.

They record technique, not policy: when a playbook step and a rule
here disagree, the rule wins and the playbook is the thing to fix.

Their `/docs` siblings answer different questions, so reach for each
on its own trigger:

- [`docs/prose-claim-audit.md`](docs/prose-claim-audit.md) — a section
  per shape of sentence that goes false while every test stays green,
  and what settles each. Read it before writing or grading prose about
  how the code works: the playbooks say how to establish a fact, this
  says which sentences owe you one.
- [`docs/agent-environment-notes.md`](docs/agent-environment-notes.md)
  — the harness and gate constraints on *how you invoke* something in
  this repo: which refuser is talking, the accepted git command forms,
  worktree path and branch-state discipline, and the tooling and `gh`
  quirks that otherwise read as a bug in your own change. Read it when
  a command is refused, rather than inventing a workaround.
- [`docs/hook-event-notes.md`](docs/hook-event-notes.md) — how each
  Claude Code hook *event* behaves: which fields it honors, what the
  harness does with each value, and how to re-verify against the
  official docs. Read it before asserting that Claude Code does
  anything in particular with a hook's output.
- [`docs/plugin-authoring-constraints.md`](docs/plugin-authoring-constraints.md)
  — verified constraints of the plugin system itself (file sandboxing,
  skill namespacing, what a `lib/` file can be read by) and the
  patterns this marketplace uses within them, including what an agent
  or skill file may assert as policy. Read it before adding a plugin,
  moving anything between two of them, or writing agent or skill prose.
- [`docs/plugin-migration-plan.md`](docs/plugin-migration-plan.md) —
  the frozen plan for repackaging `~/.claude` as plugins, kept for
  provenance. Read it for history; never edit it.

Nothing else indexes `/docs`, so this section is where a file there
becomes discoverable — add a bullet when you add one.

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

## A test asserts behavior, never a documentation convention

Never add a test that parses or greps a package's own source for prose
shapes — issue references in comments, TODO formats, comment wording.
When one is removed, do not replace it with a differently shaped check:
no build tag, no `go:generate`, no linter config added in the same PR,
no equivalent assertion relocated elsewhere. Documentation standards
change independently of behavior, so a style rule living in `go test`
fails the suite over prose, and a pattern-matching check quietly
encodes its narrow syntactic case as the definition of the class — the
one this repo shipped and reverted for issue #193
(`TestNoIssueRefsInComments`) missed every wrap-split reference while
making the tree look clean.

The line is drawn at what the program *emits*. Text the code returns to
a caller is behavior and stays under test:
`trackerRefInReason` / `TestRemediationReasonsAreActionable_58` grades
the `Reason` strings the permission-gate hands back to a blocked agent,
which are part of its contract
(`plugins/guardrails/hooks/permission-gate/README.md` → "Comments state
the invariant, not the ticket", whose closing paragraphs draw the same
line). Ask which side of it a proposed assertion sits on before writing
it.

When a finding asks you to enforce a documentation convention, state
the convention on the doc surface and let review carry it, saying so
explicitly rather than reaching for a mechanism. Removing such a
mechanism sweeps every claim it spawned in the same round — README
sections, code comments and the PR body, including its exemptions and
any "fails the build if reintroduced" completeness claim, all of which
are false the moment the check is gone.

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

## Sweep orchestrate/SKILL.md when an sdlc agent's contract changes

The `sdlc` plugin ships no `plugins/sdlc/README.md`. An agent's
contract — what it commits, when it runs, what it returns — is
restated outside that agent's own file in
`plugins/sdlc/skills/orchestrate/SKILL.md`, in several places at once:
the teammate-agent roster near the top (one bullet per agent, each
closing with what that agent leaves behind — a push, a PR, or a posted
review), and again in running prose in the "After each issue-developer
or issue-fixer" section and the fix-loop's `doc-updater` step. A PR
that edits only `plugins/sdlc/agents/*.md` falsifies every one of them
silently. Grep SKILL.md for each agent the PR touches and check every
hit against that agent's current Output section, rather than fixing
only the roster bullet.

Frontmatter tiers are a partial exception, and the halves differ.
SKILL.md deliberately names no agent's `model:`, so a model change is
confined to the agent file. That holds of `theorem-disprover` too,
whose model the review pipeline routes per spawn: SKILL.md describes
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
teammate" unqualified: `theorem-generator-high` and
`theorem-generator-xhigh` pin `effort: high` and `effort: xhigh`. That
is not effort varying per spawn — the thing the same statements forbid
— but a different agent definition being spawned, per "The generator
skeletons are copies of one file" below. A PR that adds a further
off-default variant extends the exception in both places rather than
deleting the default.

Review is a further exception to the "an agent's contract lives in its
own file" shape above, because review is not an agent at all: it is
`plugins/sdlc/skills/pr-review-pipeline/SKILL.md`, run in the main
session by both `/sdlc:orchestrate` and `/sdlc:git-review-pr`. So a
change to what a review does sweeps several files, not one — the
pipeline skill, orchestrate's "Run the review pipeline" and "Picking a
generator tier" sections, and `skills/git-review-pr/SKILL.md`, which
is the standalone caller and states which parameters it deliberately
does not pass. A change to the pipeline's *stages* — which agents it
spawns, in how many fan-outs — reaches one surface outside
`plugins/sdlc/` as well: `docs/plugin-authoring-constraints.md` →
"Fanning out parallel agents: a main-session skill, not an agent"
cites the pipeline as its worked instance and names the stages, and
the fetch-once paragraph below it names the agents that skip their own
fetch.

The briefs the pipeline writes are a two-sided contract, and both
sides are prose. A double-dash parameter added to, removed from, or
redefined in a generator, disprover, or verifier brief lands in the
pipeline's brief block *and* in the receiving agent's "Inputs" list —
plus, when the parameter changes what a step does, in that step
itself: `--head-sha` and `--fetched yes` are described in each of the
pipeline's two fan-out steps, and again in step 1 of
`theorem-disprover` and step 1 of `counterexample-verifier`, each of
which decides from them whether to fetch. Grep the parameter name
across `plugins/sdlc/` rather than editing the end that the change
started from.

One vocabulary spans three of those files instead of two: the
consequence-class tokens. `theorem-disprover` proposes one,
`counterexample-verifier` confirms or corrects it, and the pipeline
transcribes it into a severity. The *tokens* appear in all three
files: glossed in the two agent files, bare in the pipeline's
class-to-severity table. Only the pipeline states that mapping, and
the two agent files say outright that the severity is not theirs to
argue. So adding, renaming, or removing a class edits all three files
— the gloss in each agent file, the token in the pipeline's table —
and a severity table appearing in an agent file is the defect this
split exists to prevent.

Inside those two "The consequence classes" sections, the gloss bullets
are shared copy — byte-identical, and they must stay so. So is the
sentence that ends both sections, handing the severity to the pipeline
("What severity each class becomes is the pipeline's business, not
yours…"); it is the same wording in both files at a different line
wrap, so a change to it edits both. What is deliberately per-agent is
the sentence introducing the bullets and the sentences that precede
that closing one, because the two agents stand in different places in
the chain: the disprover's say its class is a *proposal* the verifier
may correct, the verifier's say the disprover proposed one and that on
disagreement the verifier's wins. Do not converge those framing
sentences while sweeping the bullets; a disprover file that claims its
class is final, or a verifier file that calls its own class a
proposal, is the error the split wording prevents.

The glosses themselves have a fourth home, which a token grep does not
reach: the pipeline's "The findings that carry no class" section
restates those same definitions against the **severity** names,
because step 2's findings come from no theorem and no verifier grades
them. Those bullets say outright that they are "the same ones the
classes name", so a change to what a class *means* — as opposed to
what it is called — edits them too, and they are the surface that
silently keeps the old meaning.

On any brief or spawn-template widening — the pipeline's briefs and
the orchestrator's teammate templates alike — the receiving side is
the half that stays stale, and the half to check is the bullet *list*
under that agent's `## Inputs`, not the prose around it. A widening is
often argued by quoting that prose, which reads like checking the
other end: the quoted sentence can be true while the enumeration above
it still omits the new field. Match the list against the template
block field by field and repair on the receiving side, since the
template is what actually gets sent.

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

Lower-yield surfaces name the agents and go stale only when a PR
changes which skill or config field an agent uses:
`plugins/github-prs/README.md` attributes one PR verb per agent in its
opening paragraph and repeats the diff-consumer list in its `/pr-diff`
section, and `plugins/github-prs/skills/pr-diff/SKILL.md` spells that
same consumer list once more — a surface a `sdlc`-only PR reaches only
by remembering that adding a diff-reading agent bumps `github-prs`
too. `plugins/issues/skills/**` names the `sdlc` readers and
what each of them still reads — `lib/repo-config.md` says per field
who consumes it (no `sdlc` reader dispatches on `source-control` any
more, and of the `sdlc` readers only the orchestrator and the review
pipeline parse `issue-link-prefix`), and its "Migration policy"
section records that the `sdlc` readers left the reader contract
entirely in #143. The root `README.md`'s `sdlc` bullet names them by
shorthand only, with no behavior to falsify.
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
`theorem-generator-high.md`, and `theorem-generator-xhigh.md` are
byte-identical except for the frontmatter lines `name:` and `effort:`
and the tier word inside `description:`. That is the whole design —
the generation instructions live in
`plugins/sdlc/skills/theorem-generation/SKILL.md`, preloaded into each
skeleton through its `skills:` frontmatter, so a tier is a choice of
which definition to spawn rather than a parameter anything passes.

So an edit to any one skeleton sweeps every other one, and the check
is mechanical:

```bash
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
`--pr`, `--issues`, `--branch` and no tier parameter, and asking it
which variant is running would let the tiers drift apart in behavior
as well as budget. The pipeline's `--generator` parameter and the
orchestrator's selection rule
(`plugins/sdlc/skills/orchestrate/SKILL.md` → "Picking a generator
tier") are where a variant is named; adding or removing one updates
that section, the teammate roster above it, the pipeline skill's
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
was byte-identical in all three skeletons, so it passed the check while
naming a section set the skill no longer had. Read a skeleton's pointer
against `theorem-generation`'s own headings, not against its siblings.

What a generator may emit at all is generation guidance too, so it has
the same single owner: `theorem-generation` → "The emission bar:
falsifiability, then stakes", which states the questions a candidate
must clear to be emitted at all. Nowhere else — this file included —
is that bar restated rather than reached by pointer, and each pointing
site is deliberately bounded: the pipeline's "The theorem contract"
says only what a theorem arriving at the pipeline therefore is, and
orchestrate's teammate-effort paragraph only prices a surplus theorem
against the diff's stakes. A change to
either question edits the skill and then re-reads every such site,
because a bar spelled out at one of them is the second source of truth
that keeping generation guidance in one file removes. The bar is
tier-blind, like the rest of that skill: a higher tier buys a deeper
search for claims that clear it, never a lower one, which is why
"Picking a generator tier" reads blast radius and not the effort the
change took to write.

`theorem-disprover` is deliberately **not** a skeleton set. It has one
definition and no tiers, and its instructions live in the agent file
because there is no sibling to drift from. What varies per spawn is
its `model`, which the pipeline routes by theorem class. A frontmatter
`model:` is only a default — the `Agent` tool's `model` parameter may
name a lower, higher, or equal model on any spawn — so the value in
the disprover's frontmatter is what an unrouted spawn gets, not a
bound on what the pipeline may pass. No file outside that frontmatter
spells the value, here included: the pipeline names only the cheaper
model it passes for a `mechanical` theorem and otherwise says "the
declared default", which is what keeps a disprover model change a
one-file edit.

`counterexample-verifier` is the same shape and holds the same
property. It too is a single definition with no tiers, its model is
routed per spawn by the same theorem class, and no file outside its
frontmatter spells its value — the pipeline's verifier fan-out names
the cheaper `mechanical` model and otherwise points at the agent
file, and `plugins/sdlc/skills/orchestrate/SKILL.md`'s
model-routing paragraph names neither agent's default. So a verifier
model change is a one-file edit too, and adding a restatement to
either the pipeline or orchestrate is what would end that.

## Review writes nothing, so review lore is a PR

`plugins/sdlc/skills/pr-review-pipeline/SKILL.md` and the agents it
spawns are strictly non-mutating on the PR branch: none of
`theorem-generator`, `theorem-disprover`, or `counterexample-verifier`
declares `memory:`, and none carries a `Write` or `Edit` tool. A
review round therefore commits nothing, pushes nothing, and adds
nothing to `.claude/agent-memory/`.

That is enforcement, not convention, so keep it structural: do not add
a `memory:` key or a writing tool to any of those definitions, and do
not give the pipeline a commit step. A durable lesson learned while
reviewing lands as a PR against `theorem-generation` (how to state a
better theorem), `theorem-disprover` (how to establish a fact),
`counterexample-verifier` (how to reject a bad counterexample), or
this file — never as a memory commit on the branch being reviewed.

`agent-memory-scrubber`'s roster of memory-declaring agents is
therefore `issue-developer`, `issue-fixer`, `doc-updater` and nothing
else. `plugins/sdlc/skills/orchestrate/SKILL.md` restates that roster
in its frontmatter-baseline paragraph, in the capture-then-curate
paragraph below it, and again under "Being last is the whole point" —
so a PR that changes which agents declare `memory:` sweeps every one
of them plus the scrubber's own "You persist no memory" section.
`grep -rn 'memory: project' plugins/sdlc/` finds the first; the other
restatements name the agents without the key, so grep the agent names
too.

## Agent memory is local-only and never committed

`.claude/agent-memory/` is gitignored (issue #260). Agents that declare
`memory: project` keep writing there as they work, but the tree belongs
to the clone — or the throwaway worktree — that wrote it, and reaches
no branch, no PR, and no other machine.

Nothing in it is repo content, so it is not reviewed, not swept as a
doc surface, and not evidence for a claim about this repo. A note there
that a code change falsifies is corrected by the agent that next reads
it, not by that change's PR. A lesson worth keeping past the run that
learned it lands as an edit to this file, to `/docs`, or to the plugin
it is about — the same routing that "Review writes nothing, so review
lore is a PR" above already requires of the review agents, now binding
every agent.

Never `git add -f` the tree, and never un-ignore it again. The ignore
also makes the current state easy to misread:
`git add .claude/agent-memory/` exits 1 with "The following paths are
ignored by one of your .gitignore files", while
`git status --porcelain .claude/agent-memory/` prints nothing even when
the tree has new files — so the `sdlc` agents' capture steps, which are
conditional on that `git status`, skip silently rather than failing.
Those steps and `agent-memory-scrubber`'s whole job still describe a
committed tree; retiring that machinery is issue #261, so read them as
stale rather than as evidence the tree is committed.

The skill the scrubber drives, `/cc-tools:agent-memory-cleanup`, is
already on the local-only model: it takes no argument, never checks out
a branch, never stages or commits or pushes, and copies the tree to a
backup under `.claude/tmp/` before deleting anything, because git can
neither stage nor restore an ignored path. Passed an argument it aborts
without curating, which is the one place the skill still names the
scrubber; do not "fix" it by re-adding a PR mode.

That abort does not reach the scrubber as a failure. Its step-3 gate
asks whether `HEAD` matches `origin/<branch-name>` and whether
`git status --porcelain` is empty, and an abort satisfies both
trivially: no commit was made, so `HEAD` still equals the ref the
branch was checked out from, and nothing was written, so the tree is
clean. The gate's own no-op carve-out does not name this shape at all —
it names the skill's "no agent memory to curate" report and a "no
changes to curate" outcome the skill no longer produces — so the
abort passes the gate as an ordinary success rather than as a
recognized no-op. So the scrubber reports success over a curation that
never ran, which is one more reason its machinery is stale rather than
load-bearing here. Retiring it is #261's job, not something to patch
around from the `cc-tools` side.

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
plugin describes it. The `/docs` surfaces that do are bounded, each in
its own way.
`docs/guardrails-verification-playbook.md` names verdicts in two
bounded ways: as the *controls a probe needs* — which track terminates
in allow and which in defer, which probe rows must still deny, which
spellings a widening already allowed on the base — and as the *comment
vocabulary a rebucketing falsifies*, where the buckets are named to
say which comment claims go stale and how to enumerate the surviving
tier. A verdict change that moves any of those control rows, or that
moves a bucket the vocabulary section names, updates it; grep it for
`deny`, `allow`, `defer` and `ask` alongside the README.
`docs/agent-environment-notes.md` names a
refusal only where an agent must reach for a different command form to
get its own work done. The gate is only one of the refusers it covers —
the worktree-isolation check and the auto-mode classifier are in there
too, some refusals attributed and some left unattributed — so read the
file rather than an enumeration here, which goes stale silently at this
distance. It states no tier and no verdict vocabulary, so a
rebucketing leaves it alone; a change that makes a currently-refused
form work, or refuses one it prescribes, edits it. The gate README's
one in-plugin sibling is
`plugins/guardrails/rules/scratch-file-location.md`, which describes
verdicts only where they decide **which destination an agent should
write a scratch file to** — the containment and `.git/` denies, their
prescriptive wording, the #225 redirect, the #229 publish read. A
verdict change that leaves that choice
unchanged needs no edit there; one that makes a previously-safe
destination unsafe — or newly grades a path an agent parks a scratch
file in — does. `.claude/agent-memory/` is **not** a further exception:
notes there do teach agents to route around a gate verdict, but the
tree is local to whichever clone wrote it and is never committed, so no
PR can sweep it and none is asked to. A note that a verdict change
falsifies is corrected by the agent that next reads it, not by the
verdict's PR.

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
touched — the two example YAML files above are ones that no test and no
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
`plugins/claude-vm/payload/build-guest-image.sh` emits leaves the
surfaces below stale, each far from the diff: the launcher is one long
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
do. A claude-vm doc pass covers those referenced files naturally and
misses the wizards, and the miss is a live defect rather than a
cosmetic one: the
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

## Sweep every App-permission surface when the starter set changes

The PR-automation GitHub App's permission set is restated as a literal
list in several `plugins/github-setup` places, each a separate edit:

- `skills/gh-create-app/SKILL.md` — the *Starter permission set* table,
  the `required_permissions` code block under it, the "Permissions →
  Repository permissions" bullets the user is told to click through
  during registration, and the `__APP_PERMISSIONS__` rendering example
  in the metadata-doc step.
- `skills/gh-repo-setup-pr-automation/SKILL.md` — the *Required GitHub
  App permissions* block and the `required_permissions = { … }` line in
  its App-resolution step.
- `skills/lib/gh-app.md` — the `required_permissions` example in the
  caller-passes list.

`payload/gh-create-app/app-metadata.md` renders the set from
`__APP_PERMISSIONS__` and holds no literal list, so it never takes this
edit — hard-coding a map there would freeze one caller's scopes into
every rendered metadata doc.
`plugins/github-claude-identity/skills/gh-create-identity-app/SKILL.md`
does carry a literal permission list, but it belongs to a **different**
App (the per-user commit identity, provisioned with its own scopes).
Never sweep it along with this set.

Widening the set has a converge-time consequence worth stating wherever
the new scope is introduced: a scope added to an already-registered App
is not live until every installing account approves it
(`skills/lib/gh-app.md` → "Granting a missing permission to an existing
App"), so every previously-provisioned App fails the library's
permission filter until that approval lands.

That failure is determinate in every caller: the library aborts the
calling skill with its "missing permissions" report and the pointer to
the two-step remediation — on the discovery path from Step 3's
no-suitable-candidates branch, on the `--app-name` path from that
path's own permission check. No caller routes such an App into
registration instead.

## Add a README roster entry when you publish a plugin

When a PR adds a new plugin entry to `.claude-plugin/marketplace.json`,
it MUST also add a matching bullet to the top-level `README.md`
"Published plugins" list, in the same PR. Registering the plugin in
`marketplace.json` and writing its own `plugins/<name>/README.md` does
not update that roster — it is a separate, easy-to-miss doc surface.
Word the bullet like its neighbors: the plugin name in bold backticks,
an em-dash, and a one-line description (pull language from the plugin's
`plugin.json` `description` or its README's opening line).
