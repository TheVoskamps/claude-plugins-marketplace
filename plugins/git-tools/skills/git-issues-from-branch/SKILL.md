---
name: git-issues-from-branch
description: Recover the ordered issue set and slug an issue branch's name encodes (issue-<N1>-<N2>-...-<slug>), or report that the branch does not follow the convention. The inverse of git-branch-create.
---

# Git Issues From Branch

Recover the issues a branch name carries — strip the configured naming
prefix, apply the branch-name grammar, and report the **ordered issue
set** plus the slug — or report that the branch does not follow the
convention at all.

This is the inverse of `git-tools:git-branch-create`, and the round
trip is the contract: given a branch that skill created, this one
returns the issue numbers it was given, in the order it was given
them, and the slug it used. A branch it did not create is the
**not-a-convention-branch** outcome below.

This skill is the only parser of branch names in this marketplace.
Consumers in other plugins — `github-prs:pr-create`,
`github-prs:pr-link-issue`, and `sdlc`'s `pr-reviewer` — invoke it
instead of restating the rule: skill invocation crosses the plugin
sandbox boundary that a `Read` cannot (see
`docs/plugin-authoring-constraints.md` → "Skill invocation
is global and namespaced"). Each of them keeps its own policy about
what to do with the result; none of them re-derives the result itself.

The skill parses a string. It runs no git command, so the branch need
not exist locally or on the remote.

## Invocation

```text
/git-tools:git-issues-from-branch <branch-name>
```

- `<branch-name>` (required): the branch name to parse, with any
  `<initials>/` or `<name>/` prefix still attached — e.g. a PR's
  `headRefName`, or the branch a caller is about to open a PR from.

## Repo-config

This skill reads one value from `.claude/rules/repo-config.md`
**internally** — the caller does not pass it. It reads it with a
lightweight **inline** parse of just that front-matter line, not the
full reader contract in the `issues` plugin's
`skills/lib/repo-config.md`: that lib file lives inside the `issues`
plugin, and plugins are file-sandboxed (a bare `Read` from another
plugin's skill cannot resolve a path outside its own plugin directory
— see `docs/plugin-authoring-constraints.md` → "Plugins are
file-sandboxed"). It is the same inline read
`git-tools:git-branch-create` performs on the same field, which is
what keeps the two halves of the round trip agreeing.

If `.claude/rules/repo-config.md` is missing, abort with: "This repo
has no `.claude/rules/repo-config.md`. Run `/repo-config` to create
one." (the same wording the full reader contract uses for its
"File missing" case, so the namespace's abort messages stay
consistent even though this skill doesn't consume the whole contract).

The value consumed:

- **`issue-branch-naming-prefix`** — the prefix `git-branch-create`
  puts in front of the branch name, one of `none`, `initials`, or
  `name`. This skill strips it. It never needs the `<initials>` or
  `<name>` value itself, so it never asks for one.

Re-read the file every run; do not cache across invocations.

## The grammar

The branch-name grammar is stated **once**, in
`git-tools:git-branch-create` → "Branch name". Read that section
before parsing — it is a sibling skill in this same plugin, so the
path resolves:
`${CLAUDE_PLUGIN_ROOT}/skills/git-branch-create/SKILL.md`.

Do not restate or reimplement the rule here. A copy in this file would
be a second statement of the grammar, which is the thing this skill
exists to prevent.

## Execution

1. **Read `issue-branch-naming-prefix`** per "Repo-config" above.

2. **Strip the naming prefix** from `<branch-name>`:

   - `none` — there is nothing to strip.
   - `initials` or `name` — strip one leading `<segment>/`. The
     segment's content is not checked; this skill is not told the
     human owner's initials or name. A name with no `/` is passed
     through unchanged, so a branch created before the prefix was
     configured still parses.

3. **Apply the grammar** from "The grammar" above to what is left.
   The remainder must start with the `issue-` marker and carry at
   least one issue number after it; the grammar then fixes where the
   numbers stop and the slug starts.

4. **Decide the outcome.**

   - **Convention branch** — the remainder started with `issue-` and
     yielded at least one issue number. Report the numbers in the
     order the name carries them, plus the slug (which the grammar
     may leave empty).
   - **Not a convention branch** — anything else: a human-named
     branch, `dependabot/npm_and_yarn/…`, an `issue-` marker with no
     number after it, or a prefixed name under
     `issue-branch-naming-prefix: none` (stripping nothing is
     deliberate — under `none` the emitter writes no prefix, so a name
     carrying one did not come from it).

5. **Report** in the shape below. Report nothing else: this skill
   makes no decision about what the issues mean, and takes no action
   on them.

## Output

A convention branch, one line:

```text
issue-206-196-201-guardrails-gate-sweep: issues 206, 196, 201; slug guardrails-gate-sweep
```

A name the grammar leaves no slug on (`issue-206`) reports
`slug (none)`; the issue set is what the caller came for either way.

Not a convention branch, one line:

```text
dependabot/npm_and_yarn/undici-5.28.4: not a convention branch — no issue set
```

Callers treat the second outcome as an **empty** issue set: there is
no set to bound anything with, and each caller falls back to whatever
it does when it has no branch set (see that caller's own steps).

## Order is a record, not a comparison key

The reported order is the order the branch name carries, which is the
implementation order `git-branch-create`'s caller chose. Every
consumer compares the result as a **set**, never as a sequence, so the
order is a record for humans and never changes a downstream decision.
It is reported rather than sorted so the round trip with
`git-branch-create` is exact.
