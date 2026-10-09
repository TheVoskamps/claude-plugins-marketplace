---
name: issue-branch-prefix
description: Resolve the literal prefix that goes in front of an issue-branch name, from the repo-config's issue-branch-naming-prefix mode and the user-config's branch-prefix-initials or branch-prefix-name value. Read-only.
---

Print the prefix mode `.issues/repo-config.md` names in
`issue-branch-naming-prefix`, and the literal prefix that mode resolves
to for this user. A caller that names an issue branch takes the prefix
from here rather than reading `.issues/` files itself or asking the
human.

## Invocation

```text
/issue-branch-prefix
```

No arguments.

## Execution

Run the `issue-branch-prefix` script, which this plugin puts on
`PATH`, with the Bash tool from inside the repo's working tree:

```bash
issue-branch-prefix
```

It reads only config files, makes no `gh` call, and writes nothing.
Print its stdout as it stands. On a non-zero exit, relay its stderr
verbatim and stop.

## Output

Exactly two lines:

```text
mode: <none|initials|name>
prefix: <value>/
```

Read each line's value as everything after the first `:`, trimmed of
leading and trailing whitespace. Under `none` the `prefix:` value is
empty. Under `initials` or `name` it is the user-config key
`branch-prefix-initials` or `branch-prefix-name` followed by `/`, the
repo-level user-config's value taking precedence over the user-global
one's (`skills/lib/user-config.md` → "Owned keys").

It exits non-zero, before printing anything, when:

- `.issues/repo-config.md` is missing, stale, or lacks the
  `issue-branch-naming-prefix` key;
- the mode is not `none`, `initials` or `name`;
- the mode's user-config key is unset or empty in both scopes — the
  message names the key and the two skills that set it,
  `/issues:user-config` and `/issues:global-user-config`;
- the resolved value contains `/` or whitespace.

## Jira backend

The prefix does not depend on the tracker: the script reads a repo
tracked in Jira exactly as one tracked in GitHub.
