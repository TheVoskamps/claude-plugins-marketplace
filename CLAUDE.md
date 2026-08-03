# CLAUDE.md

## Bump the plugin version when you change a plugin

When a PR modifies any file under `plugins/<name>/`, it MUST also bump
that plugin's `version` in `plugins/<name>/.claude-plugin/plugin.json`,
in the same PR. The version bump is a separate, deliberate edit. A
plugin change without a version bump is incomplete.

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

Cross-reference strings need the same sweep:
`plugins/sdlc/agents/doc-updater.md` and SKILL.md's own fix-loop step
quote a `### After each ...` heading verbatim, so renaming a heading in
SKILL.md means grepping the quoted title across `plugins/sdlc/`.

Lower-yield surfaces name the agents and go stale only when a PR
changes which skill or config field an agent uses:
`plugins/github-prs/README.md` attributes one PR verb per agent in its
opening paragraph and repeats the diff-consumer list in its `/pr-diff`
section, and `plugins/issues/skills/**` names the agents as repo-config
readers, with `lib/repo-config.md` adding which of them dispatch on
`source-control`. The root `README.md`'s `sdlc` bullet names them by
shorthand only, with no behavior to falsify.
`docs/plugin-migration-plan.md` mentions the agents but is a frozen
historical plan — never edit it.

SKILL.md's `Phase 1` / `Phase 2` / `Phase 3` headings stay as they
are. They violate the writing-style no-sequence-names rule, but they
are load-bearing across the file's own report templates and a Hard
Constraint ("wait for confirmation before starting Phase 2"), so
renaming them is a cross-file refactor rather than a doc-pass sweep.
Say so in the report instead of churning on them.

## Sweep the claude-vm docs when guardrails hook packaging changes

How the `guardrails` permission-gate is *shipped* — prebuilt, committed
binaries under `plugins/guardrails/hooks/bin/<goos>-<goarch>/`, selected
at run time by `uname` — is described outside the `guardrails` tree as
well as inside it, because it decides what a claude-vm bake file's
`packages:` list must contain. The mirroring surfaces are
`plugins/claude-vm/payload/README.md`,
`plugins/claude-vm/payload/config-bake.example.yml`, and
`plugins/claude-vm/skills/claude-vm/SKILL.md` (both the commented config
block and the derived-keys section). A PR touching
`plugins/guardrails/hooks/hooks.json`, `plugins/guardrails/hooks/bin/`,
or the gate's build recipe must update those surfaces in the same PR,
and therefore bumps both plugins' versions. Gate *classifier* behavior
is the opposite: it lives only in
`plugins/guardrails/hooks/permission-gate/README.md`, and no other
markdown in the repo describes it.

## Sweep the branch-name grammar across plugins when it changes

`git-tools:git-branch-create` **writes** the issue-branch name
(`issue-<N1>-…-<Nk>-<slug>`, behind the configured prefix) and its
"Branch name" section owns the rule that parses the issue set back out
of it: after the `issue-` marker, the leading run of all-numeric
hyphen-separated tokens is the set, and everything from the first
non-numeric token onward is the slug. Consumers in other plugins
restate that rule rather than importing it — plugins are
file-sandboxed (`docs/plugin-authoring-constraints.md`), so there is
nowhere shared to put it. A PR that changes the grammar (a new
separator, a different slug boundary, a different prefix position)
silently falsifies every restatement.

Grep `plugins/` for `issue-<N` and for `all-numeric` — a short,
wrap-proof needle, since the sentence carrying the rule wraps
differently in each copy — and check every hit. The known
restatements live in
`plugins/github-prs/skills/pr-create/SKILL.md` and
`skills/pr-link-issue/SKILL.md` (each under "Own issue set only"),
`plugins/github-prs/README.md` → "One PR, one issue set",
`plugins/sdlc/agents/pr-reviewer.md` step 2, and
`plugins/issues/skills/lib/repo-config.md` under
`issue-branch-naming-prefix` — which documents only the prefix shapes
and defers to the skill for the rest.

What those consumers do when parsing yields **no** set needs the same
sweep, and it is the half that gets missed: `pr-create`,
`pr-link-issue`, and `pr-reviewer` each spell out their own arm for a
branch name that doesn't match the convention — all three fall back to
the numbers the caller passed or the PR body already carries — and the
first two add further arms for a caller selection that misses a
one-member or a multi-member branch set. These arms sit in the
Execution steps, away from the `all-numeric` sentence, so the grammar
grep above walks straight past them; grep `∩` and `` `B` empty ``
too, and change every consumer in the same PR. Only a standalone
`/sdlc:git-review-pr` on a human-named or `dependabot/…` branch
exercises the no-set arm — an orchestrated run always has a
convention branch, so nothing in the pipeline catches a missing one.

Tightening one of these rules inside a SKILL.md **Execution** step
leaves three further surfaces stating the old, looser version, and
none of them is reachable by grepping the new arm's own vocabulary:
the narrative section above Execution in the same SKILL.md (the "Own
issue set only" sections state the branch-name-wins rule as a flat
absolute that a case split in the steps below can contradict); the
per-skill blurb in `plugins/github-prs/README.md` (`### /pr-create …`,
`### /pr-link-issue …`, one per skill, both needing the same edit);
and the calling agent's paraphrase in
`plugins/sdlc/agents/issue-developer.md` step 10, which describes what
`/pr-create` guards against in running prose. Grep the rule's own
distinctive phrase (`higher-fidelity`) alongside the skill name, and
prefer replacing a downstream restatement with a pointer at the step
that owns the resolution over restating the amended rule a second
time.

## Add a README roster entry when you publish a plugin

When a PR adds a new plugin entry to `.claude-plugin/marketplace.json`,
it MUST also add a matching bullet to the top-level `README.md`
"Published plugins" list, in the same PR. Registering the plugin in
`marketplace.json` and writing its own `plugins/<name>/README.md` does
not update that roster — it is a separate, easy-to-miss doc surface.
Word the bullet like its neighbors: the plugin name in bold backticks,
an em-dash, and a one-line description (pull language from the plugin's
`plugin.json` `description` or its README's opening line).
