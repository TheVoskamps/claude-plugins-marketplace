# sdlc

`plugins/sdlc/docs/rules/owners.md` — read when adding, moving or
changing a statement in an sdlc agent, skill, lib file, script or hook.
Kernel: edit a fact in the one file that owns it, and restate it in no
other.

`docs/rules/plugin-authoring-constraints.md` — read when adding,
removing or changing an sdlc skill, agent, executable, hook, config key
or state file. Kernel: the README roster changes in the same PR.

- An agent's contract is two-sided: changing what an agent does edits
  the skill that briefs it, and a widened spawn template edits the
  receiving agent's `## Inputs`.
- A config value an agent acts on travels in its brief.
- The review procedure is an agent, not a skill.
- Orchestrate has one lib file per moment, loops are agents, and each
  step has one surface.
- Derivations live in `bin/sdlc-agent-result-persist`; agent prose holds
  no state machine.
- No sdlc file restates the file-class definition.
- Every PR call an agent, skill or lib file makes goes through the
  `github-prs` verb that has one; an executable under `bin/` may call
  `gh` itself.
- Every executable under `bin/` turns a failure in a command it did not
  handle into its own documented failure status, with a line naming the
  command, never the tool's own status: exit 1, or exit 2 for
  `sdlc-agent-result-persist` and the time report. Only
  `sdlc-agent-result-persist` and `sdlc-decision`, with the layout
  functions in `bin/lib/sdlc-pr-common.sh`, compose a state path; every
  other executable reaches state through the paths
  `sdlc-agent-result-persist`'s read modes and `sdlc-decision print`
  print. A script that sources `bin/lib/sdlc-pr-common.sh` runs from
  `bin/` or through a wrapper that execs it there, never through a
  symlink placed in another directory.
- Hooks register through `register.ts`.
- Every agent that writes any file lists `Read`, `Edit` and `Write` on
  its `tools:` line; `theorem-assessor` lists `Read` and `Write` and no
  `Edit`, and `pr-monitor` lists `Read, Bash, Monitor, TaskStop`. Never
  list `Skill` on a `tools:` line, and never list a skill carrying
  `disable-model-invocation: true` in an agent's `skills:`. An agent's
  default `model:` is spelled only in its own frontmatter; a per-spawn
  `model` is spelled only in the file that makes the spawn.
- Sweep a contract change by grepping the quoted string repo-wide,
  joined across line wraps, and edit every hit; reread the paragraph
  when a count changes.
- `style-checker` keys on the header `## For Authors and Checkers`,
  spelled in the style guides outside this repository; a PR that renames
  it edits `agents/style-checker.md` and every `style-checker` spawn
  prompt.
