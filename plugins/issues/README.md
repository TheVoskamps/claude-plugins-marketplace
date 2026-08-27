# issues

Issue-tracker verbs — create, view, update, link, and set fields on an
issue — over a GitHub or Jira backend, dispatched on the `issues:`
value in the repo's config. The skills under `skills/` are the roster;
`skills/lib/` holds the contracts they share.

## The config paths are literals every consumer spells itself

This plugin owns these paths:

- `.issues/repo-config.md` — team-shared, committed, written by
  `/issues:repo-config`.
- `.issues/user-config.md` — one user, one repo, gitignored, written
  by `/issues:user-config`.
- `$XDG_CONFIG_HOME/issues/user-config.md` — machine-wide per-user,
  written by `/issues:global-user-config`, outside every git clone.

None of them is a naming preference, and each replaced a
`.claude/rules/` path deliberately. Claude Code auto-loads every
un-scoped `.claude/rules/*.md` into every session and subagent on every
turn, so a config living there was carried by sessions that never
invoke an issue verb — and a config is reference data a reader fetches,
not an instruction the model holds. Do not move any of them back.

Nothing factors those literals out, because plugins are file-sandboxed:
a consumer in another plugin cannot follow `skills/lib/repo-config.md`
and writes the path out instead. `.issues/repo-config.md` crosses the
boundary two ways — consumers in `git-tools`, `github-prs` and `sdlc`
inline-parse only the front-matter each one needs, never the whole
contract, while other files merely mention it, and a prose mention goes
stale as loudly as a reader does. So a PR that moves or renames a
config path edits every plugin that **spells** it and bumps each of
their versions, in one PR. Sweep by grepping the literal —
`grep -rn '\.issues/' plugins/` and
`grep -rn 'XDG_CONFIG_HOME/issues' plugins/` — not by opening the
plugins the diff already touched.

These are deliberately *not* duplicated, and adding a copy is the
defect rather than a helpful expansion:

- **Who reads repo-config.** A reader contract states what a file
  provides, never who consumes it, so neither `skills/lib/repo-config.md`
  nor `skills/repo-config/SKILL.md` names a consumer, and a new reader
  in another plugin is no edit here.
- **The `$XDG_CONFIG_HOME` fallback.** `skills/lib/user-config.md` →
  "Where `$XDG_CONFIG_HOME` resolves" is the single definition of what
  an unset or empty variable resolves to; a consumer needing the rule
  points at that heading.

Nothing migrates a repo or a machine off the old paths. The interview
skills look only at the new path, so an already-configured repo re-runs
from built-in defaults and the old file stays put; deleting it is the
operator's job. The one automated cleanup is `/issues:user-config`
removing a stale `.claude/rules/user-config.md` line from `.gitignore`.
A repo whose `.gitignore` is an allow-list — the marketplace repo
included — also needs a `!` line so the committed
`.issues/repo-config.md` is not ignored.
