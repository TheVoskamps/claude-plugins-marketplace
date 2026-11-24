---
name: cr-account-remove
description: Remove a Claude Code account's symlinks to the same names under ~/.claude, leaving the account directory and everything else in it.
disable-model-invocation: true
allowed-tools: Bash(cr-account-links remove:*)
---

# Remove an account's links

```text
/cc-tools:cr-account-remove <name>
```

Run this with the one name in `$ARGUMENTS`, without asking first, and
print its stdout as it stands:

```bash
cr-account-links remove <name>
```

On a non-zero exit, relay its stderr verbatim and stop.
