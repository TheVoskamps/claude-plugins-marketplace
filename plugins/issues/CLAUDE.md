# issues

`docs/rules/plugin-authoring-constraints.md` — read when moving or
  renaming a config path this plugin owns. Kernel: a PR that moves or
  renames one edits every plugin that spells it, in one PR, and bumps
  each of their versions.

- Every `gh api` call, GraphQL document and ID resolution lives in
  `bin/lib/issues-common.sh`, behind its helpers, as does the error
  catalogue; a verb script calls them, and no SKILL.md or `skills/lib/`
  file spells a `gh` command or a GraphQL document.
- The interviews reach GitHub only through `issues-discover`.
- Every script under `bin/` runs under bash 3.2: no associative arrays,
  no `${var,,}`, no `mapfile`.
- `iss_gql` and `iss_rest` take the target host as their first argument,
  and every `gh issue` call carries the host in `--repo`. Never export
  `GH_HOST`.
- The Jira path in `skills/lib/issue.md` restates the resolution rules
  and error wording the scripts own, on purpose: under `issues: Jira`
  the scripts refuse and that prose runs instead. A change to either
  edits both.
- The issue-reference grammar is the one `github-prs` parses for a PR,
  with `issues` where a PR URL has `pull`, and each plugin carries its
  own parser; a change to the grammar edits both. Every verb flag is
  `--long`, so an argument with a single leading `-` is an operand.
- No reader contract names a consumer, except that the
  `issue-branch-naming-prefix` entry names `/issues:issue-branch-prefix`,
  because the mode alone is not a prefix.
- `skills/lib/user-config.md` alone defines what an unset or empty
  `$XDG_CONFIG_HOME` resolves to.
- Never move a config path back under `.claude/rules/`: Claude Code
  auto-loads every un-scoped `.claude/rules/*.md` into every session.
- A verb that writes re-reads what it set and exits non-zero when the
  re-read does not show it. The fake's write-dropping mode,
  `FAKE_GH_DROP_WRITES=1`, is the negative control: every write path has
  a case that exits non-zero under it.
