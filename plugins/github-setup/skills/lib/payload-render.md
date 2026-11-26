# Payload render contract

How a skill renders the template files under
`${CLAUDE_PLUGIN_ROOT}/payload/<skill-name>/`, where `<skill-name>` is
the skill's own name unless its `SKILL.md` names another payload
subdirectory.

## Placeholder syntax

A placeholder is a double-underscore delimited UPPER_SNAKE_CASE name:
`__PLACEHOLDER_NAME__`. A placeholder name:

1. matches the regex `__[A-Z][A-Z0-9_]*__`;
2. is unique within a template file;
3. means one thing across every skill — two skills that need the same
   concept use the same name.

Every placeholder a template uses is documented in a comment block at
the top of the template or in the skill's `SKILL.md`.

## Verify the payload exists

Before discovering placeholders or rendering anything, check that the
skill's payload directory exists (`test -d`). A missing directory means
the plugin is installed incorrectly or the skill names the wrong
subdirectory, so abort with this message, substituting the concrete
`<skill-name>` and the expanded `${CLAUDE_PLUGIN_ROOT}` when known:

> Payload directory `${CLAUDE_PLUGIN_ROOT}/payload/<skill-name>/` is
> missing. The `github-setup` plugin appears to be installed
> incorrectly; reinstall it and retry.

## Discover a template's placeholders

```bash
grep -oE '__[A-Z][A-Z0-9_]*__' <template-file> | sort -u
```

## Resolve each placeholder, first match wins

1. **Inferred** from `gh` and `git` in the target repo:

   | Placeholder | Inference command |
   | --- | --- |
   | `__GH_ORG__` | `gh repo view --json owner -q .owner.login` |
   | `__GH_REPO__` | `gh repo view --json name -q .name` |
   | `__DEFAULT_BRANCH__` | `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` |

2. **Passed** by the caller, through an input the skill's `SKILL.md`
   maps to the placeholder.
3. **Prompted** from the user with `AskUserQuestion`, naming the
   placeholder and the value expected.

## Never render an unresolved placeholder

When a placeholder remains after all three steps, abort with:

> Unresolved placeholder `__NAME__` in template
> `<skill-name>/<file>`. Pass a value or add inference logic.

## Render

Rendering is plain string substitution — no conditionals, no loops, no
escaping beyond what the target file format requires:

1. Read `${CLAUDE_PLUGIN_ROOT}/payload/<skill-name>/<file>`.
2. Replace every occurrence of each discovered placeholder with its
   resolved value.
3. Write the result to the target path in the user's repo.

A prose-defined render reads the template with `Read`, substitutes
inline, and writes with `Write`. In shell:

```bash
rendered="$(cat "$template_path")"
rendered="${rendered//__GH_ORG__/$gh_org}"
rendered="${rendered//__GH_REPO__/$gh_repo}"
rendered="${rendered//__DEFAULT_BRANCH__/$default_branch}"
# ... one substitution per placeholder
printf '%s\n' "$rendered" > "$target_path"
```
