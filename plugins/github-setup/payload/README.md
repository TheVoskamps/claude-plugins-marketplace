# Template payload directory

This directory ships template files ("payloads") that the
`github-setup` plugin's skills render to bootstrap configuration in
target repos. Each skill owns a subdirectory named after the skill; the
skill reads its templates from there at runtime.

The payloads ship with the plugin and live at
`${CLAUDE_PLUGIN_ROOT}/payload/<skill-name>/...` once installed. No
separate install step is required — they travel with the plugin.

## Directory layout

```text
payload/
  README.md              # this file
  <skill-name>/          # per-skill payload directory
    <template-file>      # one or more template files with placeholders
    ...
```

Each `<skill-name>/` subdirectory mirrors the skill's name under
`skills/` (e.g. `gh-repo-setup-protection` with its templated
`dependabot.yml`, CodeQL workflow, CodeQL config,
dependency-install-gate (workflow + drift-check script),
dependency-pinned-gate (workflow + exact-version classifier script +
a developer-local self-test that is not rendered into target repos),
and
no-back-merging-guard (workflow + guard script + self-test) payloads,
`gh-repo-setup-pr-automation` with its auto-merge/auto-rebase workflow
payloads plus the npm lockfile-regen script and its self-test,
`gh-create-app` with its App-auth workflow snippet and
App-metadata document payloads).

## Placeholder syntax

Template files use **double-underscore delimited UPPER_SNAKE_CASE**
names as placeholders:

```text
__PLACEHOLDER_NAME__
```

Concrete examples:

| Placeholder | Meaning |
| --- | --- |
| `__GH_ORG__` | GitHub organization or user that owns the repo |
| `__GH_REPO__` | Repository name (without the org prefix) |
| `__DEFAULT_BRANCH__` | Default branch of the target repo |
| `__APP_NAME__` | Name of the GitHub App used for automation |
| `__APP_ID__` | Numeric ID of the GitHub App |

Skills may define additional placeholders as needed. Every placeholder
a template uses must be documented in a comment block at the top of the
template file or in the skill's `SKILL.md`.

### Rules for placeholder names

1. Must match the regex `__[A-Z][A-Z0-9_]*__` (leading double
   underscore, trailing double underscore, uppercase alphanumeric
   plus underscore in between).
2. Must be unique within a template file.
3. Must not collide with a different meaning across skills. If two
   skills need the same concept, use the same placeholder name.

## Verifying the payload exists

Before discovering placeholders or rendering anything, a skill must
verify that its own payload directory ships with the plugin. The
payloads travel with the plugin, so a missing directory means the
plugin is installed incorrectly (or the skill names the wrong
subdirectory) — render must not proceed.

Each skill owns the subdirectory named after it:

```text
${CLAUDE_PLUGIN_ROOT}/payload/<skill-name>/
```

The skill checks that this directory exists (e.g. `test -d "$PAYLOAD"`,
where `$PAYLOAD` is the skill's resolved payload directory) as its
first payload step. If the directory is missing, the skill aborts with
this **standard existence-check message**:

> Payload directory `${CLAUDE_PLUGIN_ROOT}/payload/<skill-name>/` is
> missing. The `github-setup` plugin appears to be installed
> incorrectly; reinstall it and retry.

Substitute the concrete `<skill-name>` (and the expanded
`${CLAUDE_PLUGIN_ROOT}` if known) when emitting the message, the same
way the "Unresolved placeholder" abort below names the concrete
template. This is the canonical wording skills reference as "the
standard `${CLAUDE_PLUGIN_ROOT}/payload/README.md` existence-check
message".

## Discovering placeholders in a template

A skill discovers which placeholders a template needs by scanning for
the pattern:

```bash
grep -oE '__[A-Z][A-Z0-9_]*__' <template-file> | sort -u
```

This returns the deduplicated list of placeholder names the template
expects. The skill resolves each one before rendering.

## Resolving placeholder values

Values are resolved in this order (first match wins):

1. **Inferred from the environment** -- values the skill can determine
   automatically from `gh` and `git` in the target repo:

   | Placeholder | Inference command |
   | --- | --- |
   | `__GH_ORG__` | `gh repo view --json owner -q .owner.login` |
   | `__GH_REPO__` | `gh repo view --json name -q .name` |
   | `__DEFAULT_BRANCH__` | `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` |

2. **Passed by the caller** -- the skill's `SKILL.md` may define
   inputs that map to specific placeholders (e.g. `--app-name` maps
   to `__APP_NAME__`). The skill resolves these from its own input
   processing.

3. **Prompted from the user** -- if a placeholder cannot be inferred
   or passed, the skill asks the user via `AskUserQuestion` before
   proceeding. The prompt names the placeholder and explains what
   value is expected.

A skill must never render a template with unresolved placeholders. If
any placeholder remains after exhausting all three resolution steps,
the skill aborts with:

> Unresolved placeholder `__NAME__` in template
> `<skill-name>/<file>`. Pass a value or add inference logic.

## Rendering a template

The render step is a simple string substitution:

1. Read the template file from
   `${CLAUDE_PLUGIN_ROOT}/payload/<skill-name>/<file>`.
2. For each placeholder found by the discovery scan, replace every
   occurrence of `__PLACEHOLDER_NAME__` with the resolved value.
3. Write the result to the target path in the user's repo.

Skills perform this substitution in whatever language or tool is
natural for the context (shell `sed`, inline string replacement in a
skill's prose instructions, etc.). The mechanism is deliberately
simple -- no conditionals, no loops, no escaping beyond what the
target file format requires.

### Rendering in shell (reference recipe)

```bash
rendered="$(cat "$template_path")"
rendered="${rendered//__GH_ORG__/$gh_org}"
rendered="${rendered//__GH_REPO__/$gh_repo}"
rendered="${rendered//__DEFAULT_BRANCH__/$default_branch}"
# ... one substitution per placeholder
echo "$rendered" > "$target_path"
```

For templates consumed by Claude skills (prose-defined, not
executable), the skill reads the template, performs the substitutions
inline, and writes the output using the `Write` tool.
