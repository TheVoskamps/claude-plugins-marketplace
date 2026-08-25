# Plugin authoring constraints (verified)

Durable, doc-verified facts about how the Claude Code plugin system
behaves, plus the patterns this marketplace uses to work within them.
Confirmed against the Claude Code docs (`plugins-reference.md`,
`plugins.md`, `skills.md`) — line cites are from the versions read while
building this marketplace; treat them as pointers, re-verify if a doc
revision moves them.

This is reference material for **authoring plugins**, distinct from any
one migration. For the specific repackaging of the `~/.claude` skills,
see [`plugin-migration-plan.md`](./plugin-migration-plan.md).

## Verified constraints

1. **Plugins are file-sandboxed.** An installed plugin cannot read
   files outside its own directory; `../other-plugin/...` paths are
   stripped at install (`plugins-reference.md` → "Path traversal
   limitations"). A shared `lib/` file can therefore only be `Read` by
   skills/agents **in the same plugin**.

2. **Skill invocation is global and namespaced.** Once a plugin is
   enabled, its skills register as `/plugin-name:skill-name` and are
   invocable from anywhere, including from another skill's or agent's
   instructions (`skills.md` lines 110, 520, 795 — "Claude can invoke
   any skill", "all skill names are always included"). Invocation is
   NOT sandboxed per plugin — only file *access* is. This asymmetry is
   the foundation of the lib-as-skill pattern below.

3. **`dependencies` coordinates install/enable, not files.** A
   `dependencies` array in `plugin.json` auto-installs/enables the
   named plugins (`plugins-reference.md` manifest schema). It does
   **not** grant file access into the dependency. Use it to guarantee a
   depended-on plugin (and thus its invocable skills) is present.

4. **`disable-model-invocation: true` blocks programmatic invocation.**
   It means "only the human can invoke" and also drops the skill's
   description from context (`skills.md` lines 308, 334, 547). Do
   **NOT** put it on a skill that other skills/agents must invoke — it
   defeats that invocation. To hide a skill from the human `/` menu
   while keeping it Claude-invocable, use **`user-invocable: false`**
   instead.

5. **Post-compaction skill carry-forward is capped at 5,000 tokens per
   skill** (`skills.md` line 345), within a 25k combined budget. A
   large file turned into an invoked skill loses everything past its
   first 5k tokens after a compaction until re-invoked. A `Read` file
   is not subject to this per-skill cap. Keep large shared content as
   `Read` files where possible; reserve lib-as-skill for content small
   enough to survive the cap (and for the cross-plugin case, where
   `Read` is not an option at all).

6. **Symlinks for cross-plugin sharing: avoid.** The docs support
   in-marketplace symlinks dereferenced-to-a-copy at install
   (`plugins-reference.md` → "Share files within a marketplace with
   symlinks"), but they are **dropped under `--plugin-dir`/local-path
   testing** for cross-plugin targets, must be hand-created and
   maintained, and the lib-as-skill pattern is strictly better.

7. **A plugin's `bin/` directory is added to PATH when the plugin is
   enabled.** Executables a plugin ships under `bin/` (e.g.
   `${CLAUDE_PLUGIN_ROOT}/bin/gh_wrapper`) become callable by their bare
   name once the plugin is enabled, and remain callable by their full
   `${CLAUDE_PLUGIN_ROOT}/bin/<name>` path regardless. First
   demonstrated by the `github-claude-identity` plugin, which ships
   `gh_wrapper` and `git_wrapper` this way. Keep such binaries
   secret-free — they travel with the plugin (and any public mirror),
   so anything secret-bearing must stay in an un-mirrored per-machine
   location instead (see that plugin's `payload/README.md` for the
   ships-vs-per-machine split). The `claude-vm` plugin's `bin/claude-vm`
   preflight launcher (issue #51) is a second instance of the same
   pattern: it runs as the bare `claude-vm` command and forwards to
   `payload/claude-vm.sh`.

## Patterns this marketplace uses

### Sharing reference content (`lib/`)

- **Within a plugin → `Read`-able files** (`skills/lib/*.md`). No
  per-skill compaction cap, deterministic, no extra machinery. This is
  the default; use it whenever every consumer of the lib lives in the
  same plugin.

- **Across plugins → lib-as-skill.** Turn the shared `.md` into a skill
  (`SKILL.md` with `user-invocable: false`), and have consumers
  **invoke** it by its namespaced name (`/owner-plugin:lib-name`)
  rather than `Read` it. Add a `dependencies` edge so the owning plugin
  is guaranteed present. This is the *only* way to share content across
  the plugin boundary (constraint 1). Keep such libs small (constraint
  5).

- **Prefer invoking a real skill over a lib at all.** Often a consumer
  doesn't need the *lib*, it needs the *data* the lib's owner already
  produces. If plugin B needs issue detail that plugin A's
  `/A:issue-view` skill already returns, B should invoke `/A:issue-view`
  rather than reach for A's `issue.md` lib. No sharing problem to solve.

### Sharing behavior (a parse, a lookup, a derivation)

When the *same rule* ends up restated in several plugins because the
sandbox blocks a shared `Read`, the duplication is the defect — a
convention that "everyone keeps their copy in step" is a maintenance
contract for it, not a fix. Move the **mechanism** into a skill in the
plugin that owns the concept and have the others invoke it by its
namespaced name (constraint 2), with a `dependencies` edge so the
skill is present (constraint 3).

Only the mechanism moves. Each consumer keeps its own **policy** about
what to do with the result, so the extraction doesn't flatten
deliberate per-caller differences.

`git-tools:git-issues-from-branch` is the worked instance: the
branch-name grammar is stated once, in
`git-tools:git-branch-create` → "Branch name", and
`git-issues-from-branch` is the one skill that parses it —
`github-prs:pr-create`, `github-prs:pr-link-issue`, and
`sdlc:theorem-based-pr-reviewer` invoke `git-issues-from-branch`
rather than each restating the rule. The same skill also applies the global
issue-to-branch reconciliation rule in `rules/git-workflow.md`,
because that rule is global rather than per-caller; what each consumer
keeps is its own **action** per reported outcome, which is exactly the
deliberate per-caller difference the extraction must not flatten.

A new skill's registration surfaces are the owning plugin's
`plugin.json` `description` and — where the plugin ships a `README.md`
of its own that rosters what it contains — that roster as well. The
root `README.md` roster registers the *plugin*, not each skill by
name: its bullet exists and describes the plugin, so a skill added to
an already-rostered plugin needs no edit there.
`.claude-plugin/marketplace.json` is per-plugin, not per-skill, so a
new skill in an already-published plugin needs no entry there either.
A new `dependencies` edge's surface is the depending plugin's own
`README.md`, where it ships one: the edge is a fact about that plugin,
so its README names it.

`github-prs:pr-closing-issues` is the same pattern on the other side
of the same question: it is the one skill that reads a PR body's
closing lines and reports which issues the PR closes, so
`github-prs:pr-link-issue`'s idempotency check,
`sdlc:theorem-based-pr-reviewer` running standalone, and
`/sdlc:orchestrate`'s end-of-loop status flip
each invoke it instead of describing the scan again.

A **path literal** is the residue the remedy leaves behind. Several
plugins name `.issues/repo-config.md` verbatim, and no mechanism
extraction removes that: each of those consumers deliberately
inline-parses only the front-matter fields it needs rather than
bundling the `issues` plugin's reader contract — the coupling that
issue #143 removed from `sdlc` — so the path travels with every one of
those parses, and with the abort message each emits when the file is
missing. The copies are the design rather than drift, and what keeps
them in step is a grep over the literal, owned by `CLAUDE.md` → "The
issues config paths are literals every consumer spells itself" and not
restated here. Naming that owner is not the sweep rule "Where a newly
demonstrated fact belongs" forbids below: there the arms differ per
consumer by design, here every copy is one string and any difference
is a defect.

### Sharing an interface across an agent set: one preloaded skill

The session that writes a brief and the agents that receive it are the
two ends of one contract, and each end tends to spell the whole thing
out: what every parameter means, and what vocabulary the answer comes
back in. Kept in both places the two ends drift, and the receiving end
is the half that goes stale, because a widening is usually written
from the sending end.

State the interface once, as a skill in the same plugin, and name that
skill in each receiving agent's `skills:` frontmatter so it is
preloaded at spawn — the same mechanism "Varying one agent's budget:
skeletons over a preloaded skill" below uses, for a different reason.
Each agent's own file then carries only what is specific to it: which
of the parameters its brief carries, and what it does with them that
its siblings do not. The writing end carries what it *puts* in each
parameter, which is policy rather than meaning, and points at the
skill for the rest.

`sdlc`'s theorem agents are the worked instance:
`plugins/sdlc/skills/theorem-agents-interface/SKILL.md` states each
brief parameter and each consequence class once, and is preloaded into
the `theorem-generator` variants, `theorem-disprover`, and
`counterexample-verifier`. `agents/theorem-based-pr-reviewer.md`
writes the briefs and says only what it puts in each; it keeps the
class-to-severity mapping, which is its own policy over the shared
vocabulary rather than part of it.

This is dedup *within* one plugin, so no `dependencies` edge is
involved — unlike the cross-plugin case above, where the sandbox
(constraint 1) is what forces the shared content into a skill the
consumers invoke by name. The agents that receive a brief get the
skill by preload rather than by invoking it; the agent that *writes*
the briefs — the reviewer, which wants only the class glosses it
grades step 2's findings by — reaches it by name instead, since one
rare branch does not earn a preload. The skill is still
machinery rather than a user verb, so it takes `user-invocable: false`
(constraint 4) the same way.

### Varying one agent's budget: skeletons over a preloaded skill

An agent's reasoning tier is its frontmatter `effort:`, and the `Agent`
tool has no per-call `effort` parameter — so "the same agent, at a
higher tier" can only be a *second agent definition*. Copying the
agent's instructions into that second file gives its behavior two
sources of truth, and they drift.

The pattern that avoids it: move the agent's entire operating
instruction into a skill in the same plugin, name that skill in each
definition's `skills:` frontmatter so it is preloaded at spawn, and
leave each definition a **skeleton** — frontmatter plus a pointer at
the skill. The definitions then differ only in `name:`, `effort:`, and
the tier phrase in `description:`, and choosing a tier is choosing
which definition to spawn.

`sdlc`'s theorem generators are the worked instance:
`theorem-generator`, `theorem-generator-medium`,
`theorem-generator-high`, and
`theorem-generator-xhigh` are skeletons over
`plugins/sdlc/skills/theorem-generation/SKILL.md`. What keeps the
pattern honest is enforced by the repo's `CLAUDE.md` →
"The generator skeletons are copies of one file":

- **The skill is tier-blind.** It carries no tier parameter and never
  asks which variant is running it, so the variants cannot diverge in
  behavior — only in budget.
- **Guidance never lands in a skeleton.** Anything a skeleton says that
  its siblings do not is the second source of truth the pattern exists
  to remove; a `diff` of the skeletons is the mechanical check.
- **A skeleton points at the whole skill, not at its parts.** The `diff`
  check above catches only what one skeleton says and its siblings do
  not, so a list of the skill's sections — identical in every skeleton,
  and read by the agent as the skill's section set — passes it while
  falling behind the skill. `sdlc`'s skeletons carried such a list and
  it had already gone stale; the repair is a pointer at the file as a
  whole, which cannot go stale, rather than a wider list, which can.

Such a skill is machinery, not a user verb: give it
`user-invocable: false` (constraint 4) so it stays out of the human `/`
menu while remaining loadable by the agents that declare it.

### Fanning out parallel agents: one home for the procedure

A procedure whose design **is** a parallel fan-out of agents is
written once, in the one place that runs it, rather than being spelled
out at each caller. Which place that is follows from who runs it:

- **Every caller spawns one agent to do the work** → the procedure is
  that agent's own body. The callers pass a parameter vocabulary and
  read a report; nothing else needs the text.
- **Several different sessions run the fan-out inline** → the
  procedure is a skill (`user-invocable: false`, constraint 4, when it
  is machinery rather than a user verb) that each of them invokes,
  because no single agent body can hold it for all of them.

A skill wrapping a procedure only one agent ever runs is the shape to
avoid: it splits one contract across two files that must agree, and
buys nothing, since an agent body is already preloaded at spawn.
Budget is the one reason to accept the split anyway — see "Varying one
agent's budget: skeletons over a preloaded skill" above, where the
frontmatter-only `effort:` key forces several definitions over one
shared procedure.

The session that runs such a fan-out may be the main session or a
subagent — **nested spawning works in this harness**: a spawned agent
holds the `Agent` tool, and a plugin-prefixed `subagent_type` such as
`sdlc:counterexample-verifier` resolves from inside one. What a
spawned agent's context does *not* carry is an agent-type roster, so a
procedure that will run inside an agent has to name the exact
plugin-prefixed `subagent_type` string of everything it spawns rather
than relying on the runner to recognize a bare name.

`sdlc`'s PR review is the worked instance:
`plugins/sdlc/agents/theorem-based-pr-reviewer.md` spawns a
`theorem-generator`, then one `theorem-disprover` per live theorem,
then one `counterexample-verifier` per disproved theorem — two
fan-outs in one procedure, the second stage reading only what the
first broke. Both callers — `/sdlc:git-review-pr` and
`/sdlc:orchestrate` — spawn that agent rather than running the review
themselves, which is why the procedure is the agent's body and no
skill. Packaging the fan-out in
an agent is what keeps the per-round working state out of the caller's
context: what comes back to the caller is the verdicts and the
findings, not the theorem list, the briefs, and every agent's report.

**A fanned-out agent must check out detached.** Every `isolation:
worktree` worktree of a repo shares that repo's single ref store, and
a branch can be checked out in only one worktree at a time. So an
agent definition that mandates `git checkout <branch>` caps its own
fan-out at one: the second and every later sibling dies at `fatal:
'<branch>' is already used by worktree at '…'` (exit 128) before it
reads a line of code, and a standalone run hits the same wall whenever
the primary clone happens to be sitting on that branch. Write
`git checkout --detach origin/<branch>` instead — identical tree, no
claim taken — and the agent's end-of-run cleanup then has no claim to
release. Decide by what the agent does with the branch, not by which
agent it is: an agent that *commits* to the branch needs an attached
checkout and therefore cannot be fanned out over that branch at all —
its caller guarantees at most one such agent holds a given branch at a
time, running several in parallel only when each has a branch of its
own. An agent that only *reads* the branch and can be spawned more
than once concurrently must detach.

**The spawning agent fetches; the fan-out does not.** The same shared
ref store makes `git fetch origin` a contended write: k siblings
fetching at once compete for one `.git`, and a loser of that lock race
fails rather than waiting. So run the fetch in whichever session does
the spawning — for review that is `theorem-based-pr-reviewer`, not its
caller — and give each agent enough to skip its own: the reviewer reads
the PR's `headRefOid` alongside `headRefName`, fetches, confirms
`origin/<branch>` carries that commit, and passes `--head-sha` and
`--fetched yes` in every disprover and verifier brief, the second
fan-out riding the same single fetch as the first. A parameter of that
kind is an assertion about what the caller did, so the agent that
receives it must still work without it: `theorem-disprover` and
`counterexample-verifier` alike fetch whenever the brief carries
neither parameter, the ref is missing, or the SHA differs, which is
what keeps a standalone run correct. See
`docs/verification-playbook.md` → "Skip the fetch when
`origin/<branch>` already matches".

**A fan-out's wait is a resume loop, and it needs a deadline.** The
spawning agent holds no blocking primitive: it ends its turn, and the
harness resumes it on each child's `<task-notification>`. A turn ended
mid-fan-out reaches the caller as `status: completed` with the closing
message as the result, so a partial turn written like a report is
indistinguishable from a finished one — every such turn has to read as
an in-progress status, carrying no verdict, no tally and no findings.
A child that never returns parks the round forever, so the spawner
fixes a deadline, gives the unreported work an explicit disposition
rather than dropping it, and past that deadline `TaskStop`s the child,
which also releases the worktree the cleanup step has to remove. Size
the deadline off a measured worst case with room to spare, and state
the figure and the run it was measured on where the deadline itself
lives, so a re-measurement is one edit — review sizes its disprover
deadline that way, and carries both in
`plugins/sdlc/agents/theorem-based-pr-reviewer.md`. A procedure that
fans out twice needs a deadline on **each** fan-out: an unbounded
second stage parks the round exactly as an unbounded first one would,
and it is the easier one to leave unbounded, because it runs only on
the rounds the first stage found something in. Where no measurement
of the second stage exists, reuse the first's rather than deriving a
shorter one from how much less work the second does — review bounds
its verifiers on that reasoning, with the same figure its disprovers
get. Never reach for `TaskStop` to make a slow round finish sooner:
stopping a child that would have reported drops a result the report
then claims to have counted. The stop needs the tool in the spawner's
own `tools:` frontmatter, which the fanned-out agents do not carry.

### Handing data between agents: a session-scoped inbox

An agent that declares `memory: project` under `isolation: worktree`
resolves `.claude/agent-memory/<plugin>-<agent>/` inside its own
throwaway worktree. That tree starts empty on every run and is removed
with the worktree, so it persists nothing: it is a per-run intake
queue, and whatever one agent wants a *later* agent to read has to
leave the worktree before cleanup. Committing it onto the branch is
the obvious exit and the one this marketplace rejects — the tree is
gitignored, because notes nothing has graded are not repo content
(see `.gitignore`).

Route the hand-off through the harness's per-session scratchpad
instead. Every agent in a session names the same scratchpad directory
in its own context, so one agent's write is another's read, and the
directory sits outside every repository — which is what keeps the
sandboxing constraints above out of the picture. Package the two
halves as skills in the plugin that owns the format: a **writer** the
producing agents invoke at end of run, and a **curator** the consuming
agent invokes, with the path layout and the grading rules in
separate `skills/lib/` files (constraint 1). Split the judgment by
what each half can still see: the writer is the last stage holding the
run in context, so it drops the entries that mean nothing outside it —
a question no rubric can answer, which is why it reads only the
layout. The curator reads entry files stripped of that context, and
both lib files, to decide which survivors are worth publishing.
Consumers in another plugin invoke the skills by namespaced name and
add a `dependencies` edge; they cannot read those lib files
(constraint 3).

`cc-tools`'s agent-memory inbox is the worked instance:
`/cc-tools:agent-memory-inbox-capture` copies the entries that outlive
the run into an inbox keyed by branch and by writing agent — the path
is stated once, in
`plugins/cc-tools/skills/lib/agent-memory-inbox.md`, and nowhere else
— and `/cc-tools:agent-memory-inbox-cleanup` grades every captured
entry transfer-or-delete, then commits the resulting `CLAUDE.md` and
`docs/` changes. `sdlc`'s `issue-developer`, `issue-fixer`, and
`doc-updater` call the writer; `agent-memory-scrubber` calls the
curator.

These properties come with the pattern rather than with that
instance:

- **The inbox is session-ephemeral.** Nothing gitignores it, nothing
  sweeps it, and nothing carries it into the next session, so an entry
  the curator never grades is simply lost. That makes ordering part of
  the design — the curator runs after every writer, and again whenever
  a later writer runs — rather than an implementation detail.
- **A branch-keyed path is read before the detach.** An agent whose
  end-of-run cleanup detaches HEAD gets an empty
  `git branch --show-current` afterwards, so it resolves the branch
  first and captures before releasing its claim.

### Plugin grouping heuristics

- Keep a skill/orchestrator and the agents it spawns in the **same
  plugin** — `subagent_type` resolution is simplest when the agent is
  local, and you avoid any cross-plugin agent-resolution question.
- Group by shared-`lib` cohesion: skills that all `Read` the same lib
  set want to live together so those reads stay in-plugin.
- Bundling extra skills a user may not want is cheap — a skill is inert
  (its description costs a little context) until invoked. Split for
  *real* independence (different audience, optional backend), not for
  tidiness.

## Gotchas

### Frontmatter YAML: quote descriptions containing a colon-space

`claude plugin validate` parses skill frontmatter strictly. A
`description:` whose value contains an unquoted colon-space (e.g.
`description: Create an App. Idempotent: detects ...`) fails with
"YAML Parse error: Unexpected token" — YAML reads the second `:` as a
nested key. **At runtime the skill then loads with empty metadata, all
frontmatter fields silently dropped.** Quote the whole value:

```yaml
description: "Create an App. Idempotent: detects an existing one ..."
```

This bites skills that began life as custom slash commands (which did
not require frontmatter) and later had a description bolted on without
quoting. Run `claude plugin validate <path>` on every plugin before
publishing.

### `claude plugin validate` is silent on a passing skill

`claude plugin validate <plugin-dir>` validates each skill's
frontmatter, not only `plugin.json`, but on success it prints just the
manifest line and the pass marker. The `Validating skill: <path>` line
appears **only** for a skill that fails.

That silence invites the wrong conclusion — that the command skipped
the skills and a clean run proves nothing. It does not. Treat a clean
run as real evidence that every skill's frontmatter parses: do not
re-probe to confirm the command works, and do not write in a PR that
frontmatter went unchecked.

Agent frontmatter is not established as covered — only skills have been
probed — so for a new agent file, still eyeball the `description:` for
the unquoted colon-space above.

### Verify agent tool names against the live documentation

When a change touches an agent's `tools:` frontmatter, check the names
against the current Claude Code tools, sub-agents and plugins reference
documentation rather than against the issue body or training priors.
Both drift: a tool can be removed entirely, or exist but be disabled by
default in favour of a newer set, and an issue's claimed list of stale
names can be written months before the work is picked up. The plugins
reference is also the authority for which frontmatter keys a plugin
agent supports at all, which is worth reading directly rather than
inferring from the agents already in the tree.

### Where a newly demonstrated fact belongs

A round that adds a plugin, extracts a skill, or adds an agent variant
updates the plugin's own tree and stops there, because nothing in the
diff forces a marketplace-wide reference doc. Route by the kind of
fact:

- **A packaging-system fact** — sandboxing, skill namespacing,
  `dependencies`, `bin/` on PATH, a new packaging *shape* such as a
  within-plugin dedup via a preloaded skill — belongs in this file's
  "Patterns this marketplace uses" section. That is the durable home
  for a generalization, and a new shape is not covered by the existing
  cross-plugin entries.
- **A hook-event behavior fact** belongs in `docs/hook-event-notes.md`
  with a citation to the hooks documentation. It does not belong here:
  such facts hold for any `settings.json` hook with no plugin
  involved, so they are off this file's charter.
- **A new plugin's roster bullet** belongs in the root `README.md`.
  That is the one doc that reliably goes stale when a plugin is added,
  since nothing else cross-references the plugin list by name.
- **Nothing** belongs in `docs/plugin-migration-plan.md`. It is a
  frozen historical planning record whose table predates several
  shipped plugins; adding to it documents a plan, not a roster.

Two surfaces a skill-extraction round leaves behind: the consumer
plugin's README does not mention the `dependencies` edge its
`plugin.json` gained, even when that README has a section on how the
plugin resolves things internally; and a consumer README's "what
differs between these consumers" sentence enumerates the arms on which
they diverge, so giving the extracted skill a new reported outcome
makes its scoping false. Only opening both consumers settles it.

Do **not** answer surviving duplication here with a sweep rule. A
sweep rule over duplicated behavior is itself the defect — deliberate
per-consumer policy arms are not drift.

### An agent or skill may not assert a rule it cannot cite

An agent definition is instruction-as-code for whoever runs it next, so
prose that sounds like a citation but has no source is worse than no
prose — it becomes policy nothing actually backs. Before writing a
categorical prohibition about adjacent tooling into an agent or skill
file, grep the actual rules files for it. If it is not there, state
only the narrower fact this agent's own guard logic needs, and let a
real rule govern the rest.

Commit and push mechanics are the recurring temptation, and they are
not a particular agent's business to legislate: sibling agents say
nothing of the kind and should not have to.

### A cross-plugin reference does not resolve

Plugins are file-sandboxed, so a skill in one plugin cannot read a file
living in another plugin's directory, and a `dependencies` entry does
not grant file access either. A skill whose doc says it follows another
plugin's reader contract "by reference" therefore follows nothing.

Where a skill genuinely needs one or two per-repo config values, parse
those lines inline and say so. Reserve a full duplicate of another
plugin's contract for the case where the whole contract is genuinely
needed — and where neither applies, the honest answer is that the guard
was vacuous and belongs deleted rather than referenced.
