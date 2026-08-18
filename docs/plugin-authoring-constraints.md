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
`sdlc:pr-review-pipeline` invoke `git-issues-from-branch` rather than
each restating the rule. The same skill also applies the global
issue-to-branch reconciliation rule in `rules/git-workflow.md`,
because that rule is global rather than per-caller; what each consumer
keeps is its own **action** per reported outcome, which is exactly the
deliberate per-caller difference the extraction must not flatten.

A new skill's registration surfaces are the owning plugin's
`plugin.json` `description`, the root `README.md` roster bullet for
that plugin, and — where the plugin ships a `README.md` of its own that
rosters what it contains, which several do, `sdlc` and `github-prs`
among them — that roster as well. `.claude-plugin/marketplace.json` is
per-plugin, not per-skill, so a new skill in an already-published
plugin needs no entry there.

`github-prs:pr-closing-issues` is the same pattern on the other side
of the same question: it is the one skill that reads a PR body's
closing lines and reports which issues the PR closes, so
`github-prs:pr-link-issue`'s idempotency check,
`sdlc:pr-review-pipeline` running standalone, and
`/sdlc:orchestrate`'s end-of-loop status flip
each invoke it instead of describing the scan again.

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
the tier word in `description:`, and choosing a tier is choosing which
definition to spawn.

`sdlc`'s theorem generators are the worked instance:
`theorem-generator`, `theorem-generator-high`, and
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

### Fanning out parallel agents: a main-session skill, not an agent

A subagent cannot spawn subagents, so a procedure whose design **is** a
parallel fan-out of agents cannot live in an agent definition. An agent
handed that job does not fail — it quietly collapses to one reader
doing the work by hand, which is the shape the fan-out existed to
replace.

Package such a procedure as a skill (`user-invocable: false`,
constraint 4, when it is machinery rather than a user verb) and have
every caller **run it in the main session** rather than delegate it to
an agent. The skill spawns the agents itself; each caller passes the
same parameter vocabulary.

`sdlc`'s PR review is the worked instance:
`plugins/sdlc/skills/pr-review-pipeline/SKILL.md` spawns a
`theorem-generator`, then one `theorem-disprover` per theorem, then one
`counterexample-verifier` per disproved theorem — two fan-outs in one
procedure, the second stage reading only what the first broke — and
its callers — `/sdlc:git-review-pr` and `/sdlc:orchestrate` — each run
it in their own session. The orchestrator's copy needs an explicit
carve-out in its "Never do work an agent owns" constraint, because a
rule that says "spawn the teammate that owns this" otherwise reads as
an instruction to delegate the very thing that cannot be delegated.

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

**The spawning session fetches; the fan-out does not.** The same shared
ref store makes `git fetch origin` a contended write: k siblings
fetching at once compete for one `.git`, and a loser of that lock race
fails rather than waiting. So run the fetch once, in the session that
spawns, and give each agent enough to skip its own — the pipeline reads
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
