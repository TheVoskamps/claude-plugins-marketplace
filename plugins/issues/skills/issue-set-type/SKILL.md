---
name: issue-set-type
description: Set the issue type (e.g. Task, Bug, Feature) on a single existing issue by human-readable name.
---

Set the issue type on a single existing issue. Issue type is an
issue-level attribute resolved against the `github-project.issue-types`
map in `.issues/repo-config.md`, not a field slot, so this verb is
separate from the set-slot verbs. `/issue-create --type` sets it at
creation time; this verb sets it afterwards.

## Invocation

```text
/issue-set-type <issue> <type-name>
```

- `<issue>` (required): the issue: `N` or `#N` in the current repo, or
  `repo#N`, `owner/repo#N`, `host/owner/repo#N` or
  `https://host/owner/repo/issues/N` in another, as
  `skills/lib/issue.md` → "Repositories and issue references" resolves
  them. In another repo the `issue-types:` map is that repo's own, as
  the same section states.
- `<type-name>` (required): a human-readable issue-type name (e.g.
  `Task`, `Bug`, `Feature`), matched case-insensitively against the
  `issue-types:` keys; a multi-word name is one quoted argument.

## Execution

Run the `issue-set-type` script, which this plugin puts on `PATH`,
with the Bash tool from inside the repo's working tree:

```bash
issue-set-type <issue> "<type-name>"
```

The script resolves the name, skips the write when the issue already
has that type, and otherwise writes it and re-reads the type, exiting
non-zero when the re-read does not show it. Print its stdout as it
stands. On a non-zero exit, relay its stderr verbatim and stop: it
carries the canonical wording for a missing `github-project:` block, a
missing `issue-types:` map, a type name not in the map, an issue not
found, or a write that did not land.

## Output

One line using the map key's canonical capitalization; no URL:

```text
#<N> type set to <CanonicalName>.
#<N> type already set to <CanonicalName>.
```

## Jira backend

The script serves the GitHub backend only. Under `issues: Jira` it
exits non-zero with its fixed Jira message before any call; follow
`skills/lib/issue.md` → "Jira backend" → "Metadata setters" instead.
