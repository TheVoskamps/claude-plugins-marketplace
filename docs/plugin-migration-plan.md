# Plugin migration plan

How the skills and agents currently in `~/.claude/{skills,agents}` are
to be repackaged as Claude Code plugins served from this marketplace.

This is a **plan**, not an implemented state. No `plugins/` directory
exists yet. Decisions recorded here were made interactively; the
"Open items" section lists what is still undecided.

## Goal and direction

`~/.claude` is the current home of these skills/agents. The intended
end state: this marketplace becomes the canonical source, and a
stripped-down `~/.claude` installs the plugins **from** this
marketplace via `/plugin`. The migration is therefore: author working
plugins here, verify, then strip and reinstall `~/.claude` from them.

## Source inventory (as of authoring)

- **33 skills** in `~/.claude/skills/` (one `SKILL.md` each).
- **5 shared lib files** in `~/.claude/skills/lib/`: `issue.md` (1408
  lines, includes the GitHub backend inline), `jira.md` (452),
  `repo-config.md` (496), `user-config.md` (366), `gh-app.md`.
- **4 agents** in `~/.claude/agents/`: `issue-developer`,
  `issue-fixer`, `doc-updater`, `pr-reviewer`.

### Which skills spawn agents (verified)

Only **`issue-address`** spawns the four agents (`subagent_type:`).
**`git-review-pr`** spawns `pr-reviewer`. **`repo-config` does NOT
spawn agents** — it only *mentions* them in prose ("this file is read
by those subagents"). An earlier grep that suggested otherwise was
matching prose, not `subagent_type:` calls.

## Verified plugin-system constraints

The doc-verified facts that shape this design — file sandboxing, global
namespaced invocation, `dependencies`, `disable-model-invocation` vs
`user-invocable`, the 5k-token compaction cap, and why symlinks are
avoided — live in
[`plugin-authoring-constraints.md`](./plugin-authoring-constraints.md),
since they are reusable for any plugin work, not specific to this
migration.

## Lib strategy (the load-bearing design choice)

- **Within a plugin → keep libs as `Read`-able files**
  (`skills/lib/*.md`). No per-skill compaction cap, deterministic, no
  extra machinery. Covers every lib consumed inside its own plugin.
- **Across plugins → lib-as-skill** (`user-invocable: false`), invoked
  by name, with a `dependencies` edge guaranteeing presence. This is
  the ONLY way to share lib content across the plugin boundary
  (constraint 1). The only file that needs it is `jira.md`.
- Happy consequence: `jira.md` is 452 lines (~3.5k tokens), **under**
  the 5k carry-forward cap (constraint 5), so the truncation cliff does
  not bite the one file forced into the skill mechanism. The large
  `issue.md` (1408 lines) stays a `Read` inside the `issues` plugin.

## The GitHub-vs-Jira asymmetry (why no `github-lib`)

The desired "install jira-lib XOR github-lib" does not map onto the
current code: the GitHub backend is baked **inline** into `issue.md`;
only Jira (`jira.md`) was ever extracted. So:

- `issue.md` = tracker-agnostic dispatcher **+ GitHub backend**
  (inseparable today).
- `jira.md` = Jira backend (separate, referenced by name from
  `issue.md` in ~6 places).

Chosen approach (**Option 2**): ship the GitHub path inside the always-
present `issues` plugin; split **only** Jira into an optional
`issues-jira` plugin. GitHub-only users never install the Jira content.
True three-way symmetry (`issue-core` / `github` / `jira`) would
require refactoring `issue.md` to extract a `github.md` — a risky
source change to a 1408-line file with ~24 consumers — and is deferred
("down the road").

## Target plugins (7)

| # | Plugin | Skills | Agents | In-plugin lib (`Read`) | Cross-plugin lib (skill) | Depends on |
|---|--------|--------|--------|------------------------|--------------------------|------------|
| 1 | `issues` | 22 `issue-*` verbs + `issue-add` (alias) + `repo-config` + `user-config` + `global-user-config` | — | `issue.md` (incl. GitHub), `repo-config.md`, `user-config.md` | — | — |
| 2 | `issues-jira` | — | — | — | `jira-lib` (= `jira.md`, `user-invocable: false`) | `issues` |
| 3 | `sdlc` | `orchestrate` (renamed from `issue-address`) + `git-review-pr` | `issue-developer`, `issue-fixer`, `doc-updater`, `pr-reviewer` | — | — | `issues` |
| 4 | `github-setup` | `gh-create-app`, `gh-repo-setup-pr-automation`, `gh-repo-setup-protection`, `repo-public-mirror-setup` | — | `gh-app.md` | — | — |
| 5 | `git-tools` | `git-cleanup-branches-and-worktrees`, `test-generate` | — | — | — | — |
| 6 | `cc-tools` | `cc-all`, `cc-watchlist` | — | — | — | — |
| 7 | `github-claude-identity` | `gh-create-identity-app` | — | — | — | — |

Notes:

- **No file duplication, no symlinks.** Every `Read`-lib lives in the
  plugin that reads it. `jira-lib` is the sole cross-plugin case and is
  handled by invoke + `dependencies`.
- **`sdlc` holds all four agents AND both agent-spawning skills**
  (`orchestrate`, `git-review-pr`). So `pr-reviewer` is never needed
  across a plugin boundary — the duplicate problem is designed out.
- **`sdlc` depends on `issues`** (its orchestrator reads the issue and
  repo-config libs, which live in `issues`). Because those reads cross
  the plugin boundary, any lib content `orchestrate` needs from
  `issues` must itself be exposed as an invocable lib-skill, OR
  `orchestrate`'s own copy must carry it. **OPEN — see open items.**
- **`issues-jira` depends on `issues`** so installing Jira support
  pulls the base.
- **`github-setup` = the 4** workflow-auth / repo-provisioning skills in
  one plugin (skills are inert until invoked; bundling is cheap).
  Internal coupling: the workflow-App pair (`gh-create-app` ←
  `gh-repo-setup-pr-automation`) plus two fully-standalone skills
  (`gh-repo-setup-protection`, `repo-public-mirror-setup`).
- **`github-claude-identity` is split out from `github-setup`.**
  `gh-create-identity-app` provisions a **per-user local bot identity**
  (token-minting on the developer's machine), a separate concern from
  `github-setup`'s **org/workflow** App provisioning. It ships its own
  `bin/gh_wrapper` and `bin/git_wrapper` executables (added to PATH when
  the plugin is enabled) plus the un-mirrored per-machine payload the
  skill deploys, so it stands alone as its own plugin.

## Source edits this migration requires

Repackaging is not pure file-moving. Known source changes:

1. **Rename `issue-address` → `orchestrate`** (skill dir + namespace
   `/sdlc:orchestrate`). Update any cross-references.
2. **`issue.md`**: replace its ~6 `Read skills/lib/jira.md` references
   with "invoke `/issues-jira:jira-lib`" (cross-plugin now). Guard for
   the case where `issues-jira` is not installed (GitHub-only users):
   the Jira path is already only taken when a `jira:` block exists, so
   absence must degrade the same way it does today.
3. **`jira.md` → `jira-lib` SKILL.md**: wrap as a skill with
   `user-invocable: false`; content otherwise unchanged.
4. Per-plugin `plugin.json` manifests (name, version, description,
   author, `dependencies` where noted).
5. Register all 7 plugins in `.claude-plugin/marketplace.json`.

## Open items

1. **`sdlc` ↔ `issues` lib boundary.** `orchestrate` (in `sdlc`) reads
   repo-config/issue lib content that lives in `issues`. Cross-plugin
   `Read` is blocked (constraint 1). Options: (a) expose the needed
   libs as invocable lib-skills in `issues` and have `orchestrate`
   invoke them; (b) give `sdlc` its own copy of the needed lib content;
   (c) re-examine whether `orchestrate` truly needs the file content or
   just the agents (which it owns). **Needs a closer read of what
   `issue-address` actually consumes from the libs at runtime.**
2. **`issue-add`** deprecated alias — include in `issues` or drop.
3. **Versioning / author** fields for each `plugin.json`.
4. **Whether `cc-all`/`cc-watchlist` ship at all** (personal/machine-
   specific) or are dropped for v1.
5. **`issue.md` → core+github refactor** (Option 3) — deferred, not
   scheduled.
