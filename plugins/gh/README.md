# gh

Git/GitHub branch operations for issue work. Today this is a single
verb, `branch-create`, that creates the correctly-named issue branch
off the right base — the raw `git switch -c` that the
`/sdlc:orchestrate` flow's `issue-developer` previously did by hand.

The point of the split is the same one that motivates the `github-prs`
plugin: the **operation** reads the config it needs
(`default-issue-source-branch`, `issue-branch-naming-prefix`)
internally; the caller just invokes the skill with an issue number. No
caller parses repo-config to hand-roll a branch create.

## Config: read internally, not by the caller

`branch-create` reads `default-issue-source-branch` and
`issue-branch-naming-prefix` from `.claude/rules/repo-config.md`
itself, via a lightweight inline parse of just those two front-matter
lines — not the `issues` plugin's full `skills/lib/repo-config.md`
reader contract, which lives inside that plugin and isn't reachable
across the plugin sandbox boundary (see
`docs/plugin-authoring-constraints.md` → "Plugins are
file-sandboxed"). The caller supplies only the issue number (and, for
non-`none` naming prefixes, the owner initials/name when the
convention needs them).

## Skills

| Skill | Purpose | Underlying command |
|-------|---------|--------------------|
| `/branch-create <issue>` | Create the issue's branch off the configured source branch | `git switch -c <name> origin/<source-branch>` |

### `/branch-create <issue-number>`

Given an issue number, resolves a short slug from the issue title,
combines it with `issue-branch-naming-prefix` to form the branch name
(`issue-<N>-<slug>`, `<initials>/issue-<N>-<slug>`, or
`<name>/issue-<N>-<slug>`), and creates that branch rooted at
`origin/<default-issue-source-branch>`. Rooting at the explicit source
branch is the wrong-base guard: without it, `git switch -c` would root
the new branch at whatever commit the worktree happened to be on.
