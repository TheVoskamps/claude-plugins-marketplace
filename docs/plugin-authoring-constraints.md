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
   ships-vs-per-machine split).

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
